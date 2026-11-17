// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {FeeTierMintParams, TickSpacingMintParams, IV3PositionManager} from "../src/V3PositionAdapters.sol";

contract Token is ERC20 {
    constructor(string memory symbol_) ERC20(symbol_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWETH is Token {
    constructor() Token("WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// Pool de mentira com a interface do Uniswap v3 que o executor usa: troca a
/// um preço fixo configurável e informa um preço médio (TWAP) configurável à
/// parte, para os testes poderem afastar um do outro. Também responde `fee`
/// e `tickSpacing`, para servir às faixas.
contract MockPool {
    address public immutable token0;
    address public immutable token1;
    uint24 public fee = 3000;
    int24 public tickSpacing = 60;

    /// Preço de execução: token1 recebido por token0, como fração.
    uint256 public priceNum = 1;
    uint256 public priceDen = 1;
    int24 public twapTick;
    /// Máximo de entrada que o pool consegue absorver.
    uint256 public maxFill = type(uint256).max;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setExecPrice(uint256 num, uint256 den) external {
        priceNum = num;
        priceDen = den;
    }

    function setTwapTick(int24 tick) external {
        twapTick = tick;
    }

    function setMaxFill(uint256 value) external {
        maxFill = value;
    }

    /// Tick atual (o de `slot0`). Nos testes de swap só o médio importa.
    int24 public spotTick;

    function setSpotTick(int24 tick) external {
        spotTick = tick;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, spotTick, 0, 0, 0, 0, true);
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory ticks, uint160[] memory) {
        ticks = new int56[](2);
        ticks[0] = 0;
        ticks[1] = int56(twapTick) * int56(uint56(secondsAgos[0]));
        return (ticks, new uint160[](2));
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 amountIn = uint256(amountSpecified);
        if (amountIn > maxFill) amountIn = maxFill;
        uint256 amountOut = zeroForOne ? (amountIn * priceNum) / priceDen : (amountIn * priceDen) / priceNum;

        address tokenIn = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;
        IERC20(tokenOut).transfer(recipient, amountOut);

        (amount0, amount1) =
            zeroForOne ? (int256(amountIn), -int256(amountOut)) : (-int256(amountOut), int256(amountIn));

        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) >= before + amountIn, "pool not paid");
    }
}

/// Agregador de mentira: faz exatamente o que o calldata manda, inclusive as
/// coisas que um agregador honesto não faria — entregar a saída a outro
/// endereço, consumir só parte da entrada ou tentar puxar mais do que devia.
contract MockAggregator {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address receiver) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(receiver, amountOut);
    }

    function noRoute() external pure {
        revert("no route");
    }
}

/// Factory com os dois `getPool` (pela taxa e pelo tick spacing).
contract MockFactory {
    mapping(bytes32 => address) private _pools;

    function register(MockPool pool) external {
        _pools[keccak256(abi.encode(pool.token0(), pool.token1(), uint256(pool.fee())))] = address(pool);
        _pools[keccak256(abi.encode(pool.token0(), pool.token1(), int256(pool.tickSpacing())))] = address(pool);
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        (a, b) = a < b ? (a, b) : (b, a);
        return _pools[keccak256(abi.encode(a, b, uint256(fee)))];
    }

    function getPool(address a, address b, int24 tickSpacing) external view returns (address) {
        (a, b) = a < b ? (a, b) : (b, a);
        return _pools[keccak256(abi.encode(a, b, int256(tickSpacing)))];
    }
}

/// Gerenciador de posições de mentira, com os dois sabores de `mint`. Um
/// depósito usa no máximo `fillBps` do que foi oferecido (para testar a
/// devolução do que sobra). Ao retirar, devolve o que estiver em `exitAmounts`
/// — o teste define o resultado da faixa (cruzada ou não, com taxa ganha).
contract MockPositionManager is ERC721 {
    struct Position {
        address token0;
        address token1;
        uint128 liquidity;
        uint256 owed0;
        uint256 owed1;
    }

    uint256 public nextId = 1;
    uint256 public fillBps = 10_000;
    mapping(uint256 => Position) public positions;
    mapping(uint256 => uint256[2]) private _exit;

    constructor() ERC721("Positions", "POS") {}

    function setFillBps(uint256 bps) external {
        fillBps = bps;
    }

    function setExitAmounts(uint256 id, uint256 amount0, uint256 amount1) external {
        _exit[id] = [amount0, amount1];
    }

    function mint(FeeTierMintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        return _mintPosition(p.token0, p.token1, p.amount0Desired, p.amount1Desired, p.recipient);
    }

    function mint(TickSpacingMintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        return _mintPosition(p.token0, p.token1, p.amount0Desired, p.amount1Desired, p.recipient);
    }

    function _mintPosition(address token0, address token1, uint256 desired0, uint256 desired1, address recipient)
        private
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        amount0 = (desired0 * fillBps) / 10_000;
        amount1 = (desired1 * fillBps) / 10_000;
        if (amount0 > 0) IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(token1).transferFrom(msg.sender, address(this), amount1);
        tokenId = nextId++;
        liquidity = uint128(amount0 + amount1);
        positions[tokenId] = Position(token0, token1, liquidity, 0, 0);
        _exit[tokenId] = [amount0, amount1];
        _safeMint(recipient, tokenId);
    }

    function decreaseLiquidity(IV3PositionManager.DecreaseLiquidityParams calldata p)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        _checkAuthorized(_ownerOf(p.tokenId), msg.sender, p.tokenId);
        Position storage position = positions[p.tokenId];
        require(p.liquidity == position.liquidity, "liquidity");
        (amount0, amount1) = (_exit[p.tokenId][0], _exit[p.tokenId][1]);
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "slippage");
        position.liquidity = 0;
        position.owed0 += amount0;
        position.owed1 += amount1;
    }

    function collect(IV3PositionManager.CollectParams calldata p)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        _checkAuthorized(_ownerOf(p.tokenId), msg.sender, p.tokenId);
        Position storage position = positions[p.tokenId];
        (amount0, amount1) = (position.owed0, position.owed1);
        position.owed0 = 0;
        position.owed1 = 0;
        if (amount0 > 0) IERC20(position.token0).transfer(p.recipient, amount0);
        if (amount1 > 0) IERC20(position.token1).transfer(p.recipient, amount1);
    }

    function burn(uint256 tokenId) external payable {
        _checkAuthorized(_ownerOf(tokenId), msg.sender, tokenId);
        require(positions[tokenId].liquidity == 0, "not cleared");
        _burn(tokenId);
    }

    /// Como o do Uniswap: cada passo com o remetente original.
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
            results[i] = result;
        }
    }
}
