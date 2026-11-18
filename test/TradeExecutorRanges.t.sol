// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BotInstanceNFT} from "../src/BotInstanceNFT.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {InstanceVault} from "../src/InstanceVault.sol";
import {
    IV3PositionAdapter,
    FeeTierAdapter,
    TickSpacingAdapter,
    V3PositionAdapterBase
} from "../src/V3PositionAdapters.sol";
import {Token, MockWETH, MockPool, MockFactory, MockPositionManager} from "./Mocks.sol";

/// Faixas de liquidez (ordem limite, LP) em forks do Uniswap V3: um
/// gerenciador que identifica o pool pelo tick spacing (como a Ramses) e um
/// pela taxa (como o Uniswap), cada um com o seu adaptador.
contract TradeExecutorRangesTest is Test {
    BotInstanceNFT nft;
    TradeExecutor executor;
    Token usdg;
    Token nvda;
    MockPool pool;
    MockFactory factory;
    MockPositionManager ramses;
    MockPositionManager uniswap;
    TickSpacingAdapter tickAdapter;
    FeeTierAdapter feeAdapter;
    bool quoteIs0;

    address multisig = makeAddr("multisig");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant ALICE = 1;
    uint256 constant FUNDS = 100_000e18;
    uint16 constant FEE = 50;
    bytes32 constant DECISION = keccak256("decision");

    function setUp() public {
        nft = new BotInstanceNFT(multisig, treasury, 1_000, 0);
        executor = new TradeExecutor(multisig, IERC721(address(nft)), address(new MockWETH()), operator, treasury, FEE);
        usdg = new Token("USDG");
        nvda = new Token("NVDA");
        pool = new MockPool(address(usdg), address(nvda));
        quoteIs0 = address(usdg) < address(nvda);
        factory = new MockFactory();
        factory.register(pool);
        ramses = new MockPositionManager();
        uniswap = new MockPositionManager();
        tickAdapter = new TickSpacingAdapter();
        feeAdapter = new FeeTierAdapter();

        vm.startPrank(multisig);
        executor.setQuoteToken(address(usdg), true);
        executor.setPositionVenue(address(ramses), _venue(address(factory), tickAdapter, true, false));
        executor.setPositionVenue(address(uniswap), _venue(address(factory), feeAdapter, true, false));
        vm.stopPrank();

        vm.startPrank(alice);
        nft.mint(address(0));
        executor.setLimits(ALICE, 10_000e18, false, false);
        executor.setMarketAllowed(ALICE, address(pool), true);
        vm.stopPrank();
        usdg.mint(_vault(), FUNDS);
        nvda.mint(_vault(), FUNDS);
    }

    /// Janela de 10 minutos, 100 ticks (~1%) de tolerância.
    function _venue(address venueFactory, IV3PositionAdapter adapter, bool enabled, bool exempt)
        internal
        pure
        returns (TradeExecutor.PositionVenue memory)
    {
        return TradeExecutor.PositionVenue(venueFactory, adapter, enabled, exempt, 600, 100);
    }

    function _vault() internal view returns (address) {
        return executor.vaultOf(ALICE);
    }

    /// Valores de uma faixa em (token0, token1), a partir de cotação e ativo.
    function _amounts(uint256 quoteAmount, uint256 baseAmount) internal view returns (uint256, uint256) {
        return quoteIs0 ? (quoteAmount, baseAmount) : (baseAmount, quoteAmount);
    }

    function _params(MockPositionManager manager, uint256 quoteAmount, uint256 baseAmount)
        internal
        view
        returns (TradeExecutor.RangeOpen memory p)
    {
        (uint256 a0, uint256 a1) = _amounts(quoteAmount, baseAmount);
        p = TradeExecutor.RangeOpen({
            tokenId: ALICE,
            manager: address(manager),
            pool: address(pool),
            quote: address(usdg),
            tickLower: -600,
            tickUpper: 600,
            amount0: a0,
            amount1: a1,
            amount0Min: 0,
            amount1Min: 0,
            feeBps: FEE,
            deadline: block.timestamp,
            decision: DECISION
        });
    }

    function _openRange(MockPositionManager manager, uint256 quoteAmount, uint256 baseAmount)
        internal
        returns (uint256 nftId)
    {
        TradeExecutor.RangeOpen memory p = _params(manager, quoteAmount, baseAmount);
        vm.prank(operator);
        nftId = executor.openRange(p);
    }

    function _closeParams(uint256 nftId) internal view returns (TradeExecutor.RangeClose memory) {
        return TradeExecutor.RangeClose({
            tokenId: ALICE,
            nftId: nftId,
            amount0Min: 0,
            amount1Min: 0,
            feeBps: FEE,
            deadline: block.timestamp,
            decision: DECISION
        });
    }

    function _closeRange(uint256 nftId) internal {
        TradeExecutor.RangeClose memory p = _closeParams(nftId);
        vm.prank(operator);
        executor.closeRange(p);
    }

    // ===== abrir =====

    function test_buyOrderPutsTheRangeNftInTheVaultAndChargesOnWhatEntered() public {
        // O gerenciador usa 80% do oferecido: 800 entram, 200 voltam.
        ramses.setFillBps(8_000);
        uint256 nftId = _openRange(ramses, 1_000e18, 0);

        assertEq(ramses.ownerOf(nftId), _vault());
        // 0,5% sobre os 800 que entraram = 4.
        assertEq(usdg.balanceOf(_vault()), FUNDS - 800e18 - 4e18);
        assertEq(executor.claimable(treasury, address(usdg)), 4e18);
        assertEq(usdg.balanceOf(address(executor)), 4e18);
        assertEq(usdg.allowance(address(executor), address(ramses)), 0);

        (address manager, address rangePool, address base, address quote, uint128 liquidity) =
            executor.ranges(ALICE, nftId);
        assertEq(manager, address(ramses));
        assertEq(rangePool, address(pool));
        assertEq(base, address(nvda));
        assertEq(quote, address(usdg));
        assertEq(liquidity, 800e18);
    }

    function test_theSameFlowWorksOnAFeeTierFork() public {
        uint256 nftId = _openRange(uniswap, 1_000e18, 0);
        assertEq(uniswap.ownerOf(nftId), _vault());
        assertEq(executor.claimable(treasury, address(usdg)), 5e18);

        _closeRange(nftId);
        // 5 de taxa na entrada e 5 na saída.
        assertEq(usdg.balanceOf(_vault()), FUNDS - 10e18);
    }

    function test_openEmitsTheDecision() public {
        (uint256 a0, uint256 a1) = _amounts(1_000e18, 0);
        vm.expectEmit(address(executor));
        emit TradeExecutor.RangeOpened(ALICE, address(ramses), 1, address(pool), 1_000e18, a0, a1, 5e18, DECISION);
        _openRange(ramses, 1_000e18, 0);
    }

    function test_poolMustComeFromTheVenueFactory() public {
        MockPool fake = new MockPool(address(usdg), address(nvda));
        TradeExecutor.RangeOpen memory p = _params(ramses, 1_000e18, 0);
        p.pool = address(fake);
        vm.prank(alice);
        executor.setMarketAllowed(ALICE, address(fake), true);

        vm.expectRevert(abi.encodeWithSelector(V3PositionAdapterBase.NotFactoryPool.selector, address(fake)));
        vm.prank(operator);
        executor.openRange(p);
    }

    function test_quoteMustBeAnAllowedTokenOfThePool() public {
        TradeExecutor.RangeOpen memory p = _params(ramses, 1_000e18, 0);
        p.quote = makeAddr("other");
        vm.expectRevert(TradeExecutor.InvalidRange.selector);
        vm.prank(operator);
        executor.openRange(p);

        p.quote = address(nvda);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.QuoteTokenNotAllowed.selector, address(nvda)));
        vm.prank(operator);
        executor.openRange(p);
    }

    function test_unknownOrDisabledVenueOpensNothingButStillCloses() public {
        uint256 nftId = _openRange(ramses, 1_000e18, 0);

        vm.prank(multisig);
        executor.setPositionVenue(address(ramses), _venue(address(factory), tickAdapter, false, false));
        TradeExecutor.RangeOpen memory p = _params(ramses, 1_000e18, 0);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.VenueDisabled.selector, address(ramses)));
        vm.prank(operator);
        executor.openRange(p);

        p.manager = makeAddr("unknown");
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.VenueDisabled.selector, p.manager));
        vm.prank(operator);
        executor.openRange(p);

        _closeRange(nftId);
        assertEq(nvda.balanceOf(_vault()), FUNDS);
    }

    function test_ownerLimitsApplyToRanges() public {
        TradeExecutor.RangeOpen memory p = _params(ramses, 10_001e18, 0);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.OverTradeLimit.selector, ALICE, 10_001e18, 10_000e18));
        vm.prank(operator);
        executor.openRange(p);

        // Uma faixa só de ativo (vender o que já está no cofre) não conta
        // no limite de cotação...
        _openRange(ramses, 0, 50_000e18);

        // ...mas respeita a pausa e o mercado liberado.
        vm.prank(alice);
        executor.setLimits(ALICE, 10_000e18, true, false);
        p = _params(ramses, 0, 1e18);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InstancePaused.selector, ALICE));
        vm.prank(operator);
        executor.openRange(p);

        vm.startPrank(alice);
        executor.setLimits(ALICE, 10_000e18, false, false);
        executor.setMarketAllowed(ALICE, address(pool), false);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.MarketNotAllowed.selector, ALICE, address(pool)));
        vm.prank(operator);
        executor.openRange(p);
    }

    function test_onlyTheOperatorOpensAndCloses() public {
        TradeExecutor.RangeOpen memory p = _params(ramses, 1_000e18, 0);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotSigner.selector, ALICE));
        vm.prank(alice);
        executor.openRange(p);

        uint256 nftId = _openRange(ramses, 1_000e18, 0);
        TradeExecutor.RangeClose memory c = _closeParams(nftId);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotSigner.selector, ALICE));
        vm.prank(alice);
        executor.closeRange(c);
    }

    function test_feeAboveTheCapIsRefused() public {
        TradeExecutor.RangeOpen memory p = _params(ramses, 1_000e18, 0);
        p.feeBps = FEE + 1;
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.FeeTooHigh.selector, FEE + 1, FEE));
        vm.prank(operator);
        executor.openRange(p);
    }

    // ===== fechar =====

    function test_crossedSellOrderReturnsTheQuoteMinusTheFee() public {
        // Ordem limite de venda: 500 de ativo numa faixa acima do preço.
        uint256 nftId = _openRange(ramses, 0, 500e18);
        assertEq(nvda.balanceOf(_vault()), FUNDS - 500e18);
        assertEq(executor.claimable(treasury, address(usdg)), 0);

        // O preço cruzou: a faixa virou 1000 de cotação, mais 3 de taxa do pool.
        usdg.mint(address(ramses), 1_003e18);
        (uint256 e0, uint256 e1) = _amounts(1_003e18, 0);
        ramses.setExitAmounts(nftId, e0, e1);

        vm.expectEmit(address(executor));
        emit TradeExecutor.RangeClosed(ALICE, address(ramses), nftId, 0, 1_003e18, 5.015e18, DECISION);
        _closeRange(nftId);

        assertEq(usdg.balanceOf(_vault()), FUNDS + 1_003e18 - 5.015e18);
        assertEq(executor.claimable(treasury, address(usdg)), 5.015e18);
        vm.expectRevert();
        ramses.ownerOf(nftId);
        (address manager,,,,) = executor.ranges(ALICE, nftId);
        assertEq(manager, address(0));
    }

    function test_partnerVenuePaysNoFee() public {
        vm.prank(multisig);
        executor.setPositionVenue(address(ramses), _venue(address(factory), tickAdapter, true, true));

        uint256 nftId = _openRange(ramses, 1_000e18, 0);
        _closeRange(nftId);
        assertEq(executor.claimable(treasury, address(usdg)), 0);
        assertEq(usdg.balanceOf(_vault()), FUNDS);
    }

    function test_exemptInstancePaysNoFeeOnRanges() public {
        vm.prank(operator);
        executor.setFeeExempt(ALICE, true);
        uint256 nftId = _openRange(ramses, 1_000e18, 0);
        _closeRange(nftId);
        assertEq(executor.claimable(treasury, address(usdg)), 0);
    }

    function test_closeHonoursTheMinimums() public {
        uint256 nftId = _openRange(ramses, 1_000e18, 0);
        TradeExecutor.RangeClose memory c = _closeParams(nftId);
        if (quoteIs0) c.amount0Min = 1_000e18 + 1;
        else c.amount1Min = 1_000e18 + 1;
        vm.expectRevert("slippage");
        vm.prank(operator);
        executor.closeRange(c);
    }

    // ===== o dono tirou o NFT =====

    function test_ownerTakesTheRangeNftAndTheOperatorCanOnlyDropItAfter() public {
        uint256 nftId = _openRange(ramses, 1_000e18, 0);

        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.RangeStillHeld.selector, ALICE, nftId));
        vm.prank(operator);
        executor.dropRange(ALICE, nftId);

        InstanceVault vault = InstanceVault(payable(_vault()));
        vm.prank(alice);
        vault.withdrawNft(address(ramses), nftId);
        assertEq(ramses.ownerOf(nftId), alice);

        TradeExecutor.RangeClose memory c = _closeParams(nftId);
        vm.expectRevert();
        vm.prank(operator);
        executor.closeRange(c);

        vm.prank(operator);
        executor.dropRange(ALICE, nftId);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NoRange.selector, ALICE, nftId));
        vm.prank(operator);
        executor.closeRange(c);
    }

    function test_strangersCannotDropRanges() public {
        uint256 nftId = _openRange(ramses, 1_000e18, 0);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotInstanceOwner.selector, ALICE));
        vm.prank(bob);
        executor.dropRange(ALICE, nftId);

        vm.prank(alice);
        executor.dropRange(ALICE, nftId);
    }

    // ===== trava de preço =====

    function test_rangeIsRefusedWhenThePoolWasMovedAwayFromItsAverage() public {
        // Preço médio no tick 0; alguém empurrou o pool para o tick 500.
        pool.setSpotTick(500);
        TradeExecutor.RangeOpen memory p = _params(ramses, 1_000e18, 0);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.RangePriceDeviation.selector, int24(500), int24(0)));
        vm.prank(operator);
        executor.openRange(p);

        // Dentro de 100 ticks passa.
        pool.setSpotTick(-100);
        uint256 nftId = _openRange(ramses, 1_000e18, 0);

        // Fechar também espera o preço voltar.
        pool.setTwapTick(-300);
        TradeExecutor.RangeClose memory c = _closeParams(nftId);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.RangePriceDeviation.selector, int24(-100), int24(-300)));
        vm.prank(operator);
        executor.closeRange(c);

        pool.setTwapTick(-150);
        _closeRange(nftId);
    }

    function test_venueWithoutHistoryCanSkipThePriceCheck() public {
        vm.prank(multisig);
        executor.setPositionVenue(
            address(ramses), TradeExecutor.PositionVenue(address(factory), tickAdapter, true, false, 0, 0)
        );
        pool.setSpotTick(5_000);
        _openRange(ramses, 1_000e18, 0);
    }

    // ===== administração =====

    function test_onlyTheMultisigRegistersVenues() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        executor.setPositionVenue(address(ramses), _venue(address(factory), tickAdapter, true, true));

        vm.startPrank(multisig);
        vm.expectRevert(TradeExecutor.ZeroAddress.selector);
        executor.setPositionVenue(address(ramses), _venue(address(0), tickAdapter, true, false));
        vm.expectRevert(TradeExecutor.ZeroAddress.selector);
        executor.setPositionVenue(
            address(ramses), _venue(address(factory), IV3PositionAdapter(address(0)), true, false)
        );
        vm.stopPrank();
    }
}
