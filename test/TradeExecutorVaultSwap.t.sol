// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BotInstanceNFT} from "../src/BotInstanceNFT.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {TickSpacingAdapter, V3PositionAdapterBase} from "../src/V3PositionAdapters.sol";
import {Token, MockWETH, MockPool, MockFactory, MockPositionManager, MockAggregator} from "./Mocks.sol";

/// A troca dentro do cofre (`swapInVault`), que serve às faixas: equilibrar
/// uma posição de liquidez, converter WETH em USDG e vender, no stop ou no
/// cancelamento, o que uma faixa trouxe.
contract TradeExecutorVaultSwapTest is Test {
    BotInstanceNFT nft;
    TradeExecutor executor;
    MockWETH weth;
    Token usdg;
    Token nvda;
    Token other;
    MockPool pool;
    MockPool quotes;
    MockFactory factory;
    MockPositionManager ramses;
    TickSpacingAdapter adapter;
    MockAggregator aggregator;

    address multisig = makeAddr("multisig");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address signer = makeAddr("signer");
    address stranger = makeAddr("stranger");

    uint256 constant ALICE = 1;
    uint256 constant FUNDS = 100_000e18;
    uint16 constant FEE = 50;
    bytes32 constant DECISION = keccak256("decision");

    function setUp() public {
        nft = new BotInstanceNFT(multisig, treasury, 1_000, 0);
        weth = new MockWETH();
        executor = new TradeExecutor(multisig, IERC721(address(nft)), address(weth), operator, treasury, FEE);
        usdg = new Token("USDG");
        nvda = new Token("NVDA");
        other = new Token("OTHER");
        // Preço médio no tick 0: um ativo vale uma cotação.
        pool = new MockPool(address(usdg), address(nvda));
        quotes = new MockPool(address(weth), address(usdg));
        factory = new MockFactory();
        factory.register(pool);
        factory.register(quotes);
        ramses = new MockPositionManager();
        adapter = new TickSpacingAdapter();
        aggregator = new MockAggregator();
        usdg.mint(address(aggregator), 1e30);
        nvda.mint(address(aggregator), 1e30);
        weth.mint(address(aggregator), 1e30);

        vm.startPrank(multisig);
        executor.setAggregator(address(aggregator), true);
        executor.setQuoteToken(address(usdg), true);
        executor.setQuoteToken(address(weth), true);
        executor.setPositionVenue(address(ramses), _venue(true, false));
        vm.stopPrank();

        vm.startPrank(alice);
        nft.mint(address(0));
        executor.setLimits(ALICE, 10_000e18, false, false);
        executor.setMarketAllowed(ALICE, address(pool), true);
        vm.stopPrank();
        usdg.mint(_vault(), FUNDS);
        nvda.mint(_vault(), FUNDS);
        weth.mint(_vault(), FUNDS);
    }

    /// Janela de 10 minutos, 100 ticks de tolerância para as faixas.
    function _venue(bool enabled, bool exempt) internal view returns (TradeExecutor.PositionVenue memory) {
        return TradeExecutor.PositionVenue(address(factory), adapter, enabled, exempt, 600, 100);
    }

    function _vault() internal view returns (address) {
        return executor.vaultOf(ALICE);
    }

    function _params(MockPool on, Token tokenIn, uint256 amountIn)
        internal
        view
        returns (TradeExecutor.VaultSwap memory)
    {
        return TradeExecutor.VaultSwap({
            tokenId: ALICE,
            manager: address(ramses),
            pool: address(on),
            tokenIn: address(tokenIn),
            amountIn: amountIn,
            minOut: 0,
            feeBps: FEE,
            deadline: block.timestamp,
            decision: DECISION
        });
    }

    /// Rota que troca `amountIn` por `amountOut`, entregando ao executor.
    function _route(Token tokenIn, Token tokenOut, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (TradeExecutor.Route memory)
    {
        return TradeExecutor.Route(
            address(aggregator),
            abi.encodeCall(
                MockAggregator.swap, (address(tokenIn), address(tokenOut), amountIn, amountOut, address(executor))
            )
        );
    }

    function _swap(address caller, TradeExecutor.VaultSwap memory p, TradeExecutor.Route memory route)
        internal
        returns (uint256)
    {
        vm.prank(caller);
        return executor.swapInVault(p, route);
    }

    // ===== vender o ativo =====

    function test_sellingTheAssetChargesOnTheQuoteThatCameOut() public {
        uint256 out = _swap(operator, _params(pool, nvda, 1_000e18), _route(nvda, usdg, 1_000e18, 990e18));

        // 0,5% sobre os 990 que saíram.
        uint256 fee = (990e18 * uint256(FEE)) / 10_000;
        assertEq(out, 990e18 - fee);
        assertEq(nvda.balanceOf(_vault()), FUNDS - 1_000e18);
        assertEq(usdg.balanceOf(_vault()), FUNDS + 990e18 - fee);
        assertEq(executor.claimable(treasury, address(usdg)), fee);
        assertEq(usdg.balanceOf(address(executor)), fee);
        // Não vira posição.
        (uint256 base,) = executor.positions(ALICE, address(pool));
        assertEq(base, 0);
    }

    function test_sellingWorksPausedAndOnADisabledVenue() public {
        vm.prank(alice);
        executor.setLimits(ALICE, 0, true, false);
        vm.prank(multisig);
        executor.setPositionVenue(address(ramses), _venue(false, false));
        vm.prank(alice);
        executor.setMarketAllowed(ALICE, address(pool), false);

        _swap(operator, _params(pool, nvda, 1_000e18), _route(nvda, usdg, 1_000e18, 990e18));
        assertEq(nvda.balanceOf(_vault()), FUNDS - 1_000e18);
    }

    function test_swapEmitsTheDecision() public {
        uint256 fee = (990e18 * uint256(FEE)) / 10_000;
        vm.expectEmit(address(executor));
        emit TradeExecutor.VaultSwapped(
            ALICE, address(pool), address(nvda), address(usdg), 1_000e18, 990e18 - fee, fee, DECISION
        );
        _swap(operator, _params(pool, nvda, 1_000e18), _route(nvda, usdg, 1_000e18, 990e18));
    }

    // ===== comprar o ativo =====

    function test_buyingTheAssetChargesOnTheQuoteThatWentIn() public {
        uint256 fee = (1_000e18 * uint256(FEE)) / 10_000;
        uint256 out = _swap(operator, _params(pool, usdg, 1_000e18), _route(usdg, nvda, 1_000e18 - fee, 990e18));

        assertEq(out, 990e18);
        assertEq(usdg.balanceOf(_vault()), FUNDS - 1_000e18);
        assertEq(nvda.balanceOf(_vault()), FUNDS + 990e18);
        assertEq(executor.claimable(treasury, address(usdg)), fee);
    }

    function test_buyingFollowsTheOwnersLimits() public {
        uint256 fee = (1_000e18 * uint256(FEE)) / 10_000;
        TradeExecutor.Route memory route = _route(usdg, nvda, 1_000e18 - fee, 990e18);

        vm.prank(alice);
        executor.setMarketAllowed(ALICE, address(pool), false);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.MarketNotAllowed.selector, ALICE, address(pool)));
        _swap(operator, _params(pool, usdg, 1_000e18), route);

        vm.startPrank(alice);
        executor.setMarketAllowed(ALICE, address(pool), true);
        executor.setLimits(ALICE, 500e18, false, false);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.OverTradeLimit.selector, ALICE, 1_000e18, 500e18));
        _swap(operator, _params(pool, usdg, 1_000e18), route);

        vm.prank(alice);
        executor.setLimits(ALICE, 10_000e18, true, false);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InstancePaused.selector, ALICE));
        _swap(operator, _params(pool, usdg, 1_000e18), route);
    }

    function test_buyingNeedsAnEnabledVenue() public {
        vm.prank(multisig);
        executor.setPositionVenue(address(ramses), _venue(false, false));
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.VenueDisabled.selector, address(ramses)));
        _swap(operator, _params(pool, usdg, 1_000e18), _route(usdg, nvda, 995e18, 990e18));
    }

    // ===== uma cotação pela outra =====

    function test_convertingOneQuoteIntoTheOtherOnlyChecksPauseAndCap() public {
        // O pool WETH/USDG não foi liberado pelo dono, e não precisa.
        uint256 fee = (1_000e18 * uint256(FEE)) / 10_000;
        _swap(operator, _params(quotes, weth, 1_000e18), _route(weth, usdg, 1_000e18 - fee, 990e18));
        assertEq(usdg.balanceOf(_vault()), FUNDS + 990e18);
        assertEq(executor.claimable(treasury, address(weth)), fee);

        vm.prank(alice);
        executor.setLimits(ALICE, 500e18, false, false);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.OverTradeLimit.selector, ALICE, 1_000e18, 500e18));
        _swap(operator, _params(quotes, weth, 1_000e18), _route(weth, usdg, 1_000e18 - fee, 990e18));

        vm.prank(alice);
        executor.setLimits(ALICE, 10_000e18, true, false);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InstancePaused.selector, ALICE));
        _swap(operator, _params(quotes, weth, 1_000e18), _route(weth, usdg, 1_000e18 - fee, 990e18));
    }

    // ===== o par =====

    function test_thePairMustHaveAQuoteToken() public {
        MockPool exotic = new MockPool(address(nvda), address(other));
        factory.register(exotic);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.QuoteTokenNotAllowed.selector, address(other)));
        _swap(operator, _params(exotic, nvda, 1_000e18), _route(nvda, other, 1_000e18, 990e18));
    }

    function test_theTokenMustBeOneOfThePool() public {
        vm.expectRevert(TradeExecutor.InvalidPair.selector);
        _swap(operator, _params(pool, other, 1_000e18), _route(other, usdg, 1_000e18, 990e18));
    }

    function test_thePoolMustComeFromTheVenueFactory() public {
        MockPool fake = new MockPool(address(usdg), address(nvda));
        vm.expectRevert(abi.encodeWithSelector(V3PositionAdapterBase.NotFactoryPool.selector, address(fake)));
        _swap(operator, _params(fake, nvda, 1_000e18), _route(nvda, usdg, 1_000e18, 990e18));
    }

    function test_unknownVenueIsRefused() public {
        TradeExecutor.VaultSwap memory p = _params(pool, nvda, 1_000e18);
        p.manager = makeAddr("unknown");
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.VenueDisabled.selector, p.manager));
        _swap(operator, p, _route(nvda, usdg, 1_000e18, 990e18));
    }

    function test_aggregatorMustBeRegistered() public {
        MockAggregator rogue = new MockAggregator();
        usdg.mint(address(rogue), 1e30);
        TradeExecutor.Route memory route = TradeExecutor.Route(
            address(rogue),
            abi.encodeCall(MockAggregator.swap, (address(nvda), address(usdg), 1_000e18, 990e18, address(executor)))
        );
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.AggregatorNotAllowed.selector, address(rogue)));
        _swap(operator, _params(pool, nvda, 1_000e18), route);
    }

    // ===== preço =====

    function test_outputBelowTheAverageBeyondTheToleranceIsRefused() public {
        // Média em 1:1 e tolerância de 3%: 960 por 1.000 não passa.
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.PriceDeviation.selector, 960e18, 1_000e18));
        _swap(operator, _params(pool, nvda, 1_000e18), _route(nvda, usdg, 1_000e18, 960e18));

        _swap(operator, _params(pool, nvda, 1_000e18), _route(nvda, usdg, 1_000e18, 971e18));
    }

    function test_theMinimumAskedIsHonoured() public {
        TradeExecutor.VaultSwap memory p = _params(pool, nvda, 1_000e18);
        p.minOut = 995e18;
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InsufficientOutput.selector, 990e18, 995e18));
        _swap(operator, p, _route(nvda, usdg, 1_000e18, 990e18));
    }

    function test_venueWithoutHistoryOnlyHasTheMinimum() public {
        vm.prank(multisig);
        executor.setPositionVenue(
            address(ramses), TradeExecutor.PositionVenue(address(factory), adapter, true, false, 0, 0)
        );
        _swap(operator, _params(pool, nvda, 1_000e18), _route(nvda, usdg, 1_000e18, 500e18));
    }

    function test_theMultisigTunesTheTolerance() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        executor.setVaultSwapDeviation(500);

        vm.startPrank(multisig);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.DeviationTooHigh.selector, uint16(1_001)));
        executor.setVaultSwapDeviation(1_001);
        executor.setVaultSwapDeviation(500);
        vm.stopPrank();
        assertEq(executor.vaultSwapDeviationBps(), 500);

        _swap(operator, _params(pool, nvda, 1_000e18), _route(nvda, usdg, 1_000e18, 960e18));
    }

    // ===== quem chama e a taxa =====

    function test_onlyTheOperatorOrTheOwnersSignerSwaps() public {
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotSigner.selector, ALICE));
        _swap(stranger, _params(pool, nvda, 1_000e18), _route(nvda, usdg, 1_000e18, 990e18));

        vm.prank(alice);
        executor.setSigner(ALICE, signer);
        _swap(signer, _params(pool, nvda, 1_000e18), _route(nvda, usdg, 1_000e18, 990e18));
    }

    function test_theSignerAlwaysPaysTheFullFee() public {
        vm.prank(alice);
        executor.setSigner(ALICE, signer);
        TradeExecutor.VaultSwap memory p = _params(pool, nvda, 1_000e18);
        p.feeBps = 0;
        _swap(signer, p, _route(nvda, usdg, 1_000e18, 990e18));
        assertEq(executor.claimable(treasury, address(usdg)), (990e18 * uint256(FEE)) / 10_000);
    }

    function test_partnerVenueAndExemptInstancePayNoFee() public {
        vm.prank(multisig);
        executor.setPositionVenue(address(ramses), _venue(true, true));
        _swap(operator, _params(pool, nvda, 1_000e18), _route(nvda, usdg, 1_000e18, 990e18));
        assertEq(executor.claimable(treasury, address(usdg)), 0);

        vm.prank(multisig);
        executor.setPositionVenue(address(ramses), _venue(true, false));
        vm.prank(operator);
        executor.setFeeExempt(ALICE, true);
        _swap(operator, _params(pool, usdg, 1_000e18), _route(usdg, nvda, 1_000e18, 990e18));
        assertEq(executor.claimable(treasury, address(usdg)), 0);
    }

    function test_expiredSwapIsRefused() public {
        TradeExecutor.VaultSwap memory p = _params(pool, nvda, 1_000e18);
        p.deadline = block.timestamp - 1;
        vm.expectRevert(TradeExecutor.Expired.selector);
        _swap(operator, p, _route(nvda, usdg, 1_000e18, 990e18));
    }
}
