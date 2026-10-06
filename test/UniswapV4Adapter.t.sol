// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BotInstanceNFT} from "../src/BotInstanceNFT.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {UniswapV4Adapter, PoolKey, IPoolManagerLike} from "../src/UniswapV4Adapter.sol";
import {Token} from "./TradeExecutor.t.sol";

contract MockWETH is ERC20 {
    constructor() ERC20("WETH", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth transfer failed");
    }
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// PoolManager de mentira com a contabilidade do verdadeiro: a troca só gera
/// saldos a acertar, e `unlock` falha se sobrar qualquer coisa em aberto — é
/// o que obriga quem chama a pagar a entrada e retirar a saída do jeito certo.
/// Preço fixo e configurável por pool; ETH nativo é `address(0)`.
contract MockPoolManager {
    /// currency1 recebido por currency0, como fração.
    mapping(bytes32 poolId => uint256) public priceNum;
    mapping(bytes32 poolId => uint256) public priceDen;
    /// Máximo de entrada que o pool absorve.
    uint256 public maxFill = type(uint256).max;

    address private locker;
    mapping(address currency => int256) private delta;
    address private synced;
    uint256 private syncedBalance;

    function setPrice(PoolKey calldata key, uint256 num, uint256 den) external {
        bytes32 id = keccak256(abi.encode(key));
        priceNum[id] = num;
        priceDen[id] = den;
    }

    function setMaxFill(uint256 value) external {
        maxFill = value;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(locker == address(0), "already unlocked");
        locker = msg.sender;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        locker = address(0);
        require(_settled(), "currency not settled");
    }

    address[] private touched;

    function _settled() private returns (bool ok) {
        ok = true;
        for (uint256 i = 0; i < touched.length; i++) {
            if (delta[touched[i]] != 0) ok = false;
            delta[touched[i]] = 0;
        }
        delete touched;
    }

    function _account(address currency, int256 change) private {
        touched.push(currency);
        delta[currency] += change;
    }

    function swap(PoolKey calldata key, IPoolManagerLike.SwapParams calldata params, bytes calldata)
        external
        returns (int256)
    {
        require(msg.sender == locker, "manager locked");
        require(params.amountSpecified < 0, "exact input only");
        bytes32 id = keccak256(abi.encode(key));
        require(priceDen[id] != 0, "pool not initialized");

        uint256 amountIn = uint256(-params.amountSpecified);
        if (amountIn > maxFill) amountIn = maxFill;
        uint256 amountOut =
            params.zeroForOne ? (amountIn * priceNum[id]) / priceDen[id] : (amountIn * priceDen[id]) / priceNum[id];

        (address currencyIn, address currencyOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        // Quem troca passa a dever a entrada e a ter a saída a receber.
        _account(currencyIn, -int256(amountIn));
        _account(currencyOut, int256(amountOut));

        (int256 amount0, int256 amount1) =
            params.zeroForOne ? (-int256(amountIn), int256(amountOut)) : (int256(amountOut), -int256(amountIn));
        return (amount0 << 128) | (amount1 & int256(uint256(type(uint128).max)));
    }

    function sync(address currency) external {
        synced = currency;
        syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        require(msg.sender == locker, "manager locked");
        if (msg.value > 0) {
            paid = msg.value;
            _account(address(0), int256(paid));
        } else {
            // Como no verdadeiro: conta o que chegou desde o `sync`.
            require(synced != address(0), "sync first");
            paid = IERC20(synced).balanceOf(address(this)) - syncedBalance;
            _account(synced, int256(paid));
            synced = address(0);
        }
    }

    function take(address currency, address to, uint256 amount) external {
        require(msg.sender == locker, "manager locked");
        _account(currency, -int256(amount));
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "eth transfer failed");
        } else {
            IERC20(currency).transfer(to, amount);
        }
    }

    receive() external payable {}
}

contract UniswapV4AdapterTest is Test {
    UniswapV4Adapter adapter;
    MockPoolManager manager;
    MockWETH weth;
    Token usdg;
    Token nvda;

    address multisig = makeAddr("multisig");
    address trader = makeAddr("trader");
    address receiver = makeAddr("receiver");
    address hook = makeAddr("hook");

    function setUp() public {
        manager = new MockPoolManager();
        weth = new MockWETH();
        usdg = new Token("USDG");
        nvda = new Token("NVDA");
        adapter = new UniswapV4Adapter(multisig, address(manager), address(weth));

        // Liquidez do "pool".
        usdg.mint(address(manager), 1e30);
        nvda.mint(address(manager), 1e30);
        vm.deal(address(manager), 1e30);

        usdg.mint(trader, 1_000_000e18);
        nvda.mint(trader, 1_000_000e18);
        vm.deal(trader, 1_000e18);
        vm.startPrank(trader);
        weth.deposit{value: 100e18}();
        usdg.approve(address(adapter), type(uint256).max);
        nvda.approve(address(adapter), type(uint256).max);
        weth.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    /// Pool dos dois tokens, na ordem que a v4 exige, a `quotePerBase`.
    function _pool(address base, address quote, uint256 quotePerBase, address hooks)
        internal
        returns (PoolKey memory key)
    {
        bool baseIs0 = base < quote;
        key = PoolKey(baseIs0 ? base : quote, baseIs0 ? quote : base, 3000, 60, hooks);
        // priceNum/priceDen = currency1 por currency0.
        if (baseIs0) manager.setPrice(key, quotePerBase, 1);
        else manager.setPrice(key, 1, quotePerBase);
    }

    // ===== ERC-20 dos dois lados =====

    function test_swapsAnErc20PairBothWaysAndKeepsNothing() public {
        PoolKey memory pool = _pool(address(nvda), address(usdg), 2, address(0));

        vm.prank(trader);
        uint256 out = adapter.swap(pool, address(usdg), address(nvda), 1_000e18, 0, receiver);
        assertEq(out, 500e18);
        assertEq(nvda.balanceOf(receiver), 500e18);
        assertEq(usdg.balanceOf(trader), 1_000_000e18 - 1_000e18);

        vm.prank(trader);
        out = adapter.swap(pool, address(nvda), address(usdg), 500e18, 0, receiver);
        assertEq(out, 1_000e18);
        assertEq(usdg.balanceOf(receiver), 1_000e18);

        // Nada fica no adaptador entre uma chamada e outra.
        assertEq(usdg.balanceOf(address(adapter)), 0);
        assertEq(nvda.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
    }

    // ===== pool em ETH nativo =====

    function test_poolInNativeEthIsTradedWithWeth() public {
        // Pool NVDA/ETH: currency0 é o ETH (address(0)). 1 ETH = 100 NVDA.
        PoolKey memory pool = PoolKey(address(0), address(nvda), 3000, 60, address(0));
        manager.setPrice(pool, 100, 1);

        // Entra WETH, o adaptador desembrulha e paga o pool em ETH.
        vm.prank(trader);
        uint256 out = adapter.swap(pool, address(weth), address(nvda), 2e18, 0, receiver);
        assertEq(out, 200e18);
        assertEq(nvda.balanceOf(receiver), 200e18);
        assertEq(weth.balanceOf(trader), 98e18);

        // Sai ETH do pool, o adaptador embrulha e entrega WETH.
        vm.prank(trader);
        out = adapter.swap(pool, address(nvda), address(weth), 300e18, 0, receiver);
        assertEq(out, 3e18);
        assertEq(weth.balanceOf(receiver), 3e18);
        assertEq(receiver.balance, 0);

        assertEq(address(adapter).balance, 0);
        assertEq(weth.balanceOf(address(adapter)), 0);
    }

    function test_poolWithWethAsAnErc20IsNotUnwrapped() public {
        PoolKey memory pool = _pool(address(nvda), address(weth), 1, address(0));

        vm.prank(trader);
        adapter.swap(pool, address(weth), address(nvda), 1e18, 0, receiver);

        assertEq(nvda.balanceOf(receiver), 1e18);
        // O pool recebeu WETH, não ETH.
        assertEq(weth.balanceOf(address(manager)), 1e18);
    }

    // ===== o que é recusado =====

    function test_hookedPoolsNeedTheHookApproved() public {
        PoolKey memory pool = _pool(address(nvda), address(usdg), 2, hook);

        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.HookNotAllowed.selector, hook));
        vm.prank(trader);
        adapter.swap(pool, address(usdg), address(nvda), 1_000e18, 0, receiver);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        vm.prank(trader);
        adapter.setHook(hook, true);

        vm.prank(multisig);
        adapter.setHook(hook, true);
        vm.prank(trader);
        adapter.swap(pool, address(usdg), address(nvda), 1_000e18, 0, receiver);
        assertEq(nvda.balanceOf(receiver), 500e18);
    }

    function test_poolMustBeOfTheTwoTokensAndSorted() public {
        PoolKey memory pool = _pool(address(nvda), address(usdg), 2, address(0));

        // Token que não é do pool.
        vm.expectRevert(UniswapV4Adapter.PoolDoesNotMatchTokens.selector);
        vm.prank(trader);
        adapter.swap(pool, address(weth), address(nvda), 1e18, 0, receiver);

        // Moedas fora de ordem: não é uma chave de pool válida.
        PoolKey memory unsorted = PoolKey(pool.currency1, pool.currency0, 3000, 60, address(0));
        vm.expectRevert(UniswapV4Adapter.PoolDoesNotMatchTokens.selector);
        vm.prank(trader);
        adapter.swap(unsorted, address(usdg), address(nvda), 1e18, 0, receiver);

        // O mesmo token dos dois lados.
        vm.expectRevert(UniswapV4Adapter.PoolDoesNotMatchTokens.selector);
        vm.prank(trader);
        adapter.swap(pool, address(usdg), address(usdg), 1e18, 0, receiver);
    }

    function test_minOutPartialFillAndZeroAreRefused() public {
        PoolKey memory pool = _pool(address(nvda), address(usdg), 2, address(0));

        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.InsufficientOutput.selector, 500e18, 501e18));
        vm.prank(trader);
        adapter.swap(pool, address(usdg), address(nvda), 1_000e18, 501e18, receiver);

        manager.setMaxFill(600e18);
        vm.expectRevert(UniswapV4Adapter.SwapNotFilled.selector);
        vm.prank(trader);
        adapter.swap(pool, address(usdg), address(nvda), 1_000e18, 0, receiver);

        vm.expectRevert(UniswapV4Adapter.ZeroAmount.selector);
        vm.prank(trader);
        adapter.swap(pool, address(usdg), address(nvda), 0, 0, receiver);

        vm.expectRevert(UniswapV4Adapter.ZeroAddress.selector);
        vm.prank(trader);
        adapter.swap(pool, address(usdg), address(nvda), 1e18, 0, address(0));

        // Nenhuma das recusas levou dinheiro.
        assertEq(usdg.balanceOf(trader), 1_000_000e18);
    }

    function test_callbackOnlyAnswersThePoolManagerDuringASwap() public {
        bytes memory data = abi.encode(
            PoolKey(address(nvda), address(usdg), 3000, 60, address(0)), address(usdg), address(nvda), 1e18, trader
        );

        vm.expectRevert(UniswapV4Adapter.BadCallback.selector);
        vm.prank(trader);
        adapter.unlockCallback(data);

        // Nem o próprio PoolManager, fora de um swap começado pelo adaptador.
        vm.expectRevert(UniswapV4Adapter.BadCallback.selector);
        vm.prank(address(manager));
        adapter.unlockCallback(data);
    }

    function test_ethFromStrangersIsRefused() public {
        vm.expectRevert(UniswapV4Adapter.BadCallback.selector);
        vm.prank(trader);
        (bool ok,) = address(adapter).call{value: 1 ether}("");
        ok;
    }

    function test_constructorRejectsMissingAddresses() public {
        vm.expectRevert(UniswapV4Adapter.ZeroAddress.selector);
        new UniswapV4Adapter(multisig, address(0), address(weth));
        vm.expectRevert(UniswapV4Adapter.ZeroAddress.selector);
        new UniswapV4Adapter(multisig, address(manager), address(0));
    }

    // ===== pelo executor =====

    TradeExecutor executor;
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    uint256 aliceId;

    /// Executor com o adaptador aprovado como destino, e uma instância pronta.
    function _setUpExecutor() internal {
        BotInstanceNFT nft = new BotInstanceNFT(multisig, treasury, 1_000, 0);
        executor = new TradeExecutor(multisig, IERC721(address(nft)), operator, treasury, 1_000, 1_000);
        vm.startPrank(multisig);
        nft.setTransferGuard(executor);
        executor.setAggregator(address(adapter), true);
        executor.setQuoteToken(address(usdg), true);
        vm.stopPrank();

        usdg.mint(alice, 10_000e18);
        vm.startPrank(alice);
        aliceId = nft.mint(address(0));
        executor.setLimits(aliceId, 10_000e18, false);
        executor.setMarketAllowed(aliceId, executor.pairKey(address(nvda), address(usdg)), true);
        usdg.approve(address(executor), type(uint256).max);
        nvda.approve(address(executor), type(uint256).max);
        vm.stopPrank();
    }

    /// Rota pelo adaptador, com a saída voltando ao executor.
    function _v4Route(PoolKey memory pool, Token tokenIn, Token tokenOut, uint256 amountIn)
        internal
        view
        returns (TradeExecutor.Route memory)
    {
        return TradeExecutor.Route(
            address(adapter),
            abi.encodeCall(
                UniswapV4Adapter.swap, (pool, address(tokenIn), address(tokenOut), amountIn, 0, address(executor))
            )
        );
    }

    function _one(uint256 value) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = value;
    }

    /// O caminho inteiro: o executor puxa a cotação do dono, usa o adaptador
    /// como destino do caminho do agregador e devolve o ativo ao dono.
    function test_executorTradesAV4PoolThroughTheAdapter() public {
        _setUpExecutor();
        PoolKey memory pool = _pool(address(nvda), address(usdg), 2, address(0));
        TradeExecutor.Pair memory pair = TradeExecutor.Pair(address(nvda), address(usdg));

        // Entra a 2.
        vm.prank(operator);
        executor.openViaAggregator(
            _one(aliceId), pair, _one(1_000e18), 500e18, block.timestamp, _v4Route(pool, usdg, nvda, 1_000e18)
        );
        assertEq(nvda.balanceOf(alice), 500e18);

        // Sai a 3: lucro 500, taxa de 10%.
        _pool(address(nvda), address(usdg), 3, address(0));
        vm.prank(operator);
        executor.closeViaAggregator(
            _one(aliceId), pair, new address[](1), 1_500e18, block.timestamp, _v4Route(pool, nvda, usdg, 500e18)
        );
        assertEq(usdg.balanceOf(alice), 10_000e18 + 450e18);
        assertEq(executor.claimable(treasury, address(usdg)), 50e18);
        assertEq(usdg.balanceOf(address(adapter)), 0);
        assertEq(usdg.allowance(address(executor), address(adapter)), 0);
    }
}
