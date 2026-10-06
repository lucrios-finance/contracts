// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Identidade de um pool do Uniswap v4, como o PoolManager a define. Na v4
/// todos os pools moram num contrato só; a chave é que diz qual é qual.
struct PoolKey {
    /// O menor dos dois endereços. `address(0)` é ETH nativo.
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// O que este contrato usa do PoolManager do Uniswap v4.
interface IPoolManagerLike {
    struct SwapParams {
        bool zeroForOne;
        /// Negativo = valor exato de entrada.
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    /// Abre o PoolManager para quem chama e o chama de volta em
    /// `unlockCallback`. Tudo o que se deve e se tem a receber precisa estar
    /// zerado quando o callback termina.
    function unlock(bytes calldata data) external returns (bytes memory);

    /// Devolve o saldo da troca para quem chama: `amount0` nos 128 bits de
    /// cima, `amount1` nos de baixo. Negativo = deve ao PoolManager.
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (int256 delta);

    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// Troca direto num pool do Uniswap v4.
///
/// Existe para os tokens que o agregador não lista. Para o `TradeExecutor`
/// ele é só mais um destino do caminho do agregador (`openViaAggregator` /
/// `closeViaAggregator`): recebe a entrada por allowance, troca e devolve a
/// saída a quem chamou. Assim o código da v4 fica fora do contrato que guarda
/// o allowance dos usuários, e pode ser trocado por outro sem novo approve —
/// basta o multisig aprovar o endereço novo no executor.
///
/// Não guarda saldo nem allowance entre uma chamada e outra, e não tem
/// privilégio nenhum: qualquer um pode usá-lo para trocar os próprios tokens.
/// As travas de preço são de quem chama (no executor: mínimo pedido,
/// referência de preço do par e pausa por perda).
///
/// Como se troca na v4: `unlock` no PoolManager, que chama de volta
/// `unlockCallback`; lá dentro, `swap` devolve quanto se deve e quanto se tem
/// a receber; paga-se a entrada (`sync` + transferência + `settle`, ou
/// `settle` com valor para ETH) e retira-se a saída (`take`).
///
/// Hooks são código de terceiros que roda no meio do swap. Pool sem hook
/// sempre pode; pool com hook só se o multisig aprovou aquele hook.
contract UniswapV4Adapter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Limites de preço do Uniswap: os mesmos na v3 e na v4.
    uint160 private constant MIN_SQRT_PRICE = 4295128739;
    uint160 private constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    IPoolManagerLike public immutable poolManager;
    address public immutable weth;

    mapping(address hooks => bool) public allowedHooks;

    /// Verdadeiro só durante um swap começado por este contrato.
    bool private _swapping;

    event Swapped(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event HookSet(address indexed hooks, bool allowed);

    error ZeroAddress();
    error ZeroAmount();
    error HookNotAllowed(address hooks);
    error PoolDoesNotMatchTokens();
    error SwapNotFilled();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error BadCallback();

    constructor(address initialOwner, address poolManager_, address weth_) Ownable(initialOwner) {
        if (poolManager_ == address(0) || weth_ == address(0)) revert ZeroAddress();
        poolManager = IPoolManagerLike(poolManager_);
        weth = weth_;
    }

    /// Troca `amountIn` de `tokenIn` por `tokenOut` no pool e entrega a saída
    /// a `receiver`. A entrada é puxada de quem chama, por allowance.
    ///
    /// `tokenIn` e `tokenOut` são sempre ERC-20. Quando o pool usa ETH nativo
    /// e o token é o WETH, o contrato embrulha e desembrulha por dentro.
    function swap(
        PoolKey calldata pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address receiver
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (pool.hooks != address(0) && !allowedHooks[pool.hooks]) revert HookNotAllowed(pool.hooks);

        // As duas moedas do pool têm de ser os dois tokens pedidos; a única
        // diferença aceita é ETH nativo no lugar do WETH.
        address currencyIn = _poolCurrency(pool, tokenIn);
        address currencyOut = _poolCurrency(pool, tokenOut);
        bool matches = (pool.currency0 == currencyIn && pool.currency1 == currencyOut)
            || (pool.currency0 == currencyOut && pool.currency1 == currencyIn);
        if (!matches || pool.currency0 >= pool.currency1) revert PoolDoesNotMatchTokens();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        _swapping = true;
        bytes memory result = poolManager.unlock(abi.encode(pool, currencyIn, currencyOut, amountIn, receiver));
        _swapping = false;

        amountOut = abi.decode(result, (uint256));
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// Chamado pelo PoolManager com ele aberto. Só responde a ele, e só
    /// durante um swap que este contrato começou.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_swapping) revert BadCallback();
        (PoolKey memory pool, address currencyIn, address currencyOut, uint256 amountIn, address receiver) =
            abi.decode(data, (PoolKey, address, address, uint256, address));

        bool zeroForOne = currencyIn == pool.currency0;
        int256 delta = poolManager.swap(
            pool,
            IPoolManagerLike.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                // Sem limite de preço próprio: quem limita é o mínimo de saída.
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int256 owed, int256 gained) = zeroForOne
            ? (int256(int128(delta >> 128)), int256(int128(delta)))
            : (int256(int128(delta)), int256(int128(delta >> 128)));

        // Pool sem liquidez para a ordem inteira consome só parte da entrada.
        // Quem chama dimensionou tudo pelo valor cheio, então isso é erro.
        if (owed != -int256(amountIn) || gained <= 0) revert SwapNotFilled();
        uint256 amountOut = uint256(gained);

        if (currencyIn == address(0)) {
            IWETH(weth).withdraw(amountIn);
            poolManager.settle{value: amountIn}();
        } else {
            poolManager.sync(currencyIn);
            IERC20(currencyIn).safeTransfer(address(poolManager), amountIn);
            poolManager.settle();
        }

        if (currencyOut == address(0)) {
            poolManager.take(address(0), address(this), amountOut);
            IWETH(weth).deposit{value: amountOut}();
            IERC20(weth).safeTransfer(receiver, amountOut);
        } else {
            poolManager.take(currencyOut, receiver, amountOut);
        }

        return abi.encode(amountOut);
    }

    /// Como um token aparece no pool: ele mesmo, ou ETH nativo quando o token
    /// é o WETH e o pool usa ETH.
    function _poolCurrency(PoolKey calldata pool, address token) private view returns (address) {
        return token == weth && pool.currency0 == address(0) ? address(0) : token;
    }

    function setHook(address hooks, bool allowed) external onlyOwner {
        if (hooks == address(0)) revert ZeroAddress();
        allowedHooks[hooks] = allowed;
        emit HookSet(hooks, allowed);
    }

    /// ETH só passa por aqui: vem do WETH ao desembrulhar e do PoolManager ao
    /// retirar a saída de um pool em ETH nativo.
    receive() external payable {
        if (msg.sender != weth && msg.sender != address(poolManager)) revert BadCallback();
    }
}
