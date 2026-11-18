// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BotInstanceNFT} from "../src/BotInstanceNFT.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {Token, MockWETH, MockPool, MockAggregator} from "./Mocks.sol";

contract TradeExecutorAggregatorTest is Test {
    BotInstanceNFT nft;
    TradeExecutor executor;
    Token usdg;
    Token nvda;
    MockAggregator aggregator;
    MockPool pool;
    bool baseIsToken0;

    address multisig = makeAddr("multisig");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address thief = makeAddr("thief");

    uint256 constant ALICE = 1;
    uint256 constant BOB = 2;
    uint256 constant FUNDS = 100_000e18;
    uint16 constant FEE = 50;
    bytes32 constant DECISION = keccak256("decision");
    /// ln(2)/ln(1.0001): o tick em que o ativo vale 2 de cotação.
    int24 constant TICK_2 = 6931;

    address key;

    function setUp() public {
        nft = new BotInstanceNFT(multisig, treasury, 1_000, 0);
        executor = new TradeExecutor(multisig, IERC721(address(nft)), address(new MockWETH()), operator, treasury, FEE);
        usdg = new Token("USDG");
        nvda = new Token("NVDA");
        aggregator = new MockAggregator();
        pool = new MockPool(address(usdg), address(nvda));
        baseIsToken0 = address(nvda) < address(usdg);
        key = executor.pairKey(address(nvda), address(usdg));

        usdg.mint(address(aggregator), 1e30);
        nvda.mint(address(aggregator), 1e30);

        vm.startPrank(multisig);
        executor.setAggregator(address(aggregator), true);
        executor.setQuoteToken(address(usdg), true);
        vm.stopPrank();

        _onboard(alice);
        _onboard(bob);
    }

    function _onboard(address user) internal {
        vm.startPrank(user);
        uint256 tokenId = nft.mint(address(0));
        executor.setLimits(tokenId, 10_000e18, false, false);
        executor.setMarketAllowed(tokenId, key, true);
        vm.stopPrank();
        usdg.mint(executor.vaultOf(tokenId), FUNDS);
    }

    function _vault(uint256 tokenId) internal view returns (address) {
        return executor.vaultOf(tokenId);
    }

    function _pair() internal view returns (TradeExecutor.Pair memory) {
        return TradeExecutor.Pair(address(nvda), address(usdg));
    }

    function _one(uint256 value) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = value;
    }

    /// Rota que entrega `amountOut` a `receiver` em troca de `amountIn`.
    function _route(Token tokenIn, Token tokenOut, uint256 amountIn, uint256 amountOut, address receiver)
        internal
        view
        returns (TradeExecutor.Route memory)
    {
        return TradeExecutor.Route(
            address(aggregator),
            abi.encodeCall(MockAggregator.swap, (address(tokenIn), address(tokenOut), amountIn, amountOut, receiver))
        );
    }

    function _openVia(uint256 tokenId, uint256 quoteIn, uint256 minOut, TradeExecutor.Route memory route) internal {
        vm.prank(operator);
        executor.openViaAggregator(_one(tokenId), _pair(), _one(quoteIn), minOut, FEE, block.timestamp, DECISION, route);
    }

    /// Compra a 2 de cotação por ativo (sobre o que sobra depois da taxa).
    function _open(uint256 tokenId, uint256 quoteIn) internal {
        uint256 net = quoteIn - (quoteIn * FEE) / 10_000;
        _openVia(tokenId, quoteIn, 0, _route(usdg, nvda, net, net / 2, address(executor)));
    }

    /// Vende a posição inteira por `quoteOut`.
    function _close(uint256 tokenId, uint256 quoteOut) internal {
        (uint256 base,) = executor.positions(tokenId, key);
        vm.prank(operator);
        executor.closeViaAggregator(
            _one(tokenId),
            _pair(),
            0,
            FEE,
            block.timestamp,
            DECISION,
            _route(nvda, usdg, base, quoteOut, address(executor))
        );
    }

    // ===== abrir e fechar =====

    function test_openAndCloseThroughTheAggregatorKeepEverythingInTheVault() public {
        _open(ALICE, 1_000e18);
        assertEq(usdg.balanceOf(_vault(ALICE)), FUNDS - 1_000e18);
        assertEq(nvda.balanceOf(_vault(ALICE)), 497.5e18);
        assertEq(executor.claimable(treasury, address(usdg)), 5e18);

        _close(ALICE, 1_500e18);
        // 1500 de volta, 7,5 de taxa.
        assertEq(usdg.balanceOf(_vault(ALICE)), FUNDS - 1_000e18 + 1_492.5e18);
        assertEq(nvda.balanceOf(_vault(ALICE)), 0);
        assertEq(executor.claimable(treasury, address(usdg)), 12.5e18);
        assertEq(usdg.balanceOf(address(executor)), 12.5e18);
    }

    function test_onlyTheOperatorTrades() public {
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotSigner.selector, ALICE));
        vm.prank(alice);
        executor.openViaAggregator(
            _one(ALICE),
            _pair(),
            _one(1_000e18),
            0,
            FEE,
            block.timestamp,
            DECISION,
            _route(usdg, nvda, 995e18, 1, address(executor))
        );
    }

    function test_anyMarketLetsTheInstanceBuyAPairItNeverListed() public {
        vm.prank(alice);
        executor.setMarketAllowed(ALICE, key, false);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.MarketNotAllowed.selector, ALICE, key));
        _open(ALICE, 1_000e18);

        vm.prank(alice);
        executor.setLimits(ALICE, 10_000e18, false, true);
        _open(ALICE, 1_000e18);
    }

    function test_onlyApprovedAggregatorsAndQuoteTokens() public {
        MockAggregator rogue = new MockAggregator();
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.AggregatorNotAllowed.selector, address(rogue)));
        _openVia(
            ALICE,
            1_000e18,
            0,
            TradeExecutor.Route(
                address(rogue),
                abi.encodeCall(MockAggregator.swap, (address(usdg), address(nvda), 995e18, 1, address(executor)))
            )
        );

        vm.prank(multisig);
        executor.setQuoteToken(address(usdg), false);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.QuoteTokenNotAllowed.selector, address(usdg)));
        _open(ALICE, 1_000e18);
    }

    function test_closingWorksWithTheQuoteTokenDelisted() public {
        _open(ALICE, 1_000e18);
        vm.prank(multisig);
        executor.setQuoteToken(address(usdg), false);
        _close(ALICE, 1_000e18);
        (uint256 base,) = executor.positions(ALICE, key);
        assertEq(base, 0);
    }

    // ===== o que o contrato mede =====

    function test_outputSentElsewhereDoesNotCount() public {
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InsufficientOutput.selector, 0, 490e18));
        _openVia(ALICE, 1_000e18, 490e18, _route(usdg, nvda, 995e18, 497.5e18, thief));
        assertEq(usdg.balanceOf(_vault(ALICE)), FUNDS);
    }

    function test_openThatDeliversNothingReverts() public {
        vm.expectRevert(TradeExecutor.ZeroAmount.selector);
        _openVia(ALICE, 1_000e18, 0, _route(usdg, nvda, 995e18, 497.5e18, thief));
    }

    function test_partialFillAndFailedRouteRevert() public {
        vm.expectRevert(TradeExecutor.SwapNotFilled.selector);
        _openVia(ALICE, 1_000e18, 0, _route(usdg, nvda, 600e18, 300e18, address(executor)));

        vm.expectRevert(TradeExecutor.AggregatorCallFailed.selector);
        _openVia(
            ALICE, 1_000e18, 0, TradeExecutor.Route(address(aggregator), abi.encodeCall(MockAggregator.noRoute, ()))
        );
    }

    function test_aggregatorCannotReachTheFeesHeldByTheExecutor() public {
        _open(ALICE, 1_000e18);
        assertEq(usdg.balanceOf(address(executor)), 5e18);

        // Rota que tenta puxar a entrada de Bob mais a taxa guardada: a
        // aprovação é só da entrada, então a chamada falha.
        vm.expectRevert(TradeExecutor.AggregatorCallFailed.selector);
        _openVia(BOB, 1_000e18, 0, _route(usdg, nvda, 1_000e18, 500e18, address(executor)));
        assertEq(usdg.balanceOf(address(executor)), 5e18);
    }

    /// Sem referência de preço, uma operadora comprometida consegue desviar
    /// um trade; a pausa por perda impede o segundo.
    function test_compromisedOperatorIsStoppedAfterOneTradePerPair() public {
        vm.prank(multisig);
        executor.setLossPause(5_000);

        _openVia(ALICE, 1_000e18, 0, _route(usdg, nvda, 995e18, 1, address(executor)));
        _close(ALICE, 1);
        (, bool paused,) = executor.limits(ALICE);
        assertTrue(paused);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InstancePaused.selector, ALICE));
        _open(ALICE, 1_000e18);

        // Com referência de preço o mesmo desvio nem começa.
        _setReference();
        vm.expectPartialRevert(TradeExecutor.PriceDeviation.selector);
        _openVia(BOB, 1_000e18, 0, _route(usdg, nvda, 995e18, 1, address(executor)));
    }

    // ===== referência de preço =====

    function _setReference() internal {
        vm.startPrank(multisig);
        executor.setMarket(address(pool), address(nvda), address(usdg), true, 600, 100);
        executor.setPairReference(address(nvda), address(usdg), address(pool));
        vm.stopPrank();
        pool.setTwapTick(baseIsToken0 ? TICK_2 : -TICK_2);
    }

    function test_pairWithAReferencePoolIsHeldToItsAveragePrice() public {
        _setReference();

        // 995 a preço médio 2 valem ~497,5; a rota entrega 400.
        vm.expectPartialRevert(TradeExecutor.PriceDeviation.selector);
        _openVia(ALICE, 1_000e18, 0, _route(usdg, nvda, 995e18, 400e18, address(executor)));

        // Dentro da tolerância de 1% passa.
        _openVia(ALICE, 1_000e18, 0, _route(usdg, nvda, 995e18, 494e18, address(executor)));

        // Na saída também: 494 a 2 dá ~988; 800 é recusado.
        TradeExecutor.Route memory route = _route(nvda, usdg, 494e18, 800e18, address(executor));
        vm.expectPartialRevert(TradeExecutor.PriceDeviation.selector);
        vm.prank(operator);
        executor.closeViaAggregator(_one(ALICE), _pair(), 0, FEE, block.timestamp, DECISION, route);
    }

    function test_referenceMustBeARegisteredPoolOfTheSamePair() public {
        vm.startPrank(multisig);
        vm.expectRevert(TradeExecutor.InvalidMarket.selector);
        executor.setPairReference(address(nvda), address(usdg), address(pool));

        executor.setMarket(address(pool), address(nvda), address(usdg), true, 600, 100);
        vm.expectRevert(TradeExecutor.InvalidMarket.selector);
        executor.setPairReference(address(usdg), address(nvda), address(pool));

        executor.setPairReference(address(nvda), address(usdg), address(pool));
        assertEq(executor.referencePool(key), address(pool));
        vm.stopPrank();
    }

    function test_openRejectsNonsensePairs() public {
        vm.expectRevert(TradeExecutor.InvalidPair.selector);
        vm.prank(operator);
        executor.openViaAggregator(
            _one(ALICE),
            TradeExecutor.Pair(address(usdg), address(usdg)),
            _one(1_000e18),
            0,
            FEE,
            block.timestamp,
            DECISION,
            _route(usdg, nvda, 995e18, 1, address(executor))
        );

        // Fechar um par que nunca foi aberto.
        vm.expectRevert(TradeExecutor.InvalidPair.selector);
        vm.prank(operator);
        executor.closeViaAggregator(
            _one(ALICE),
            TradeExecutor.Pair(address(usdg), address(nvda)),
            0,
            FEE,
            block.timestamp,
            DECISION,
            _route(nvda, usdg, 1, 1, address(executor))
        );
    }

    function test_onlyTheMultisigAdministersTheAggregatorPath() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        executor.setAggregator(operator, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        executor.setQuoteToken(address(nvda), true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        executor.setPairReference(address(nvda), address(usdg), address(0));
        vm.stopPrank();
    }

    function test_pairKeyDependsOnTheOrderOfTheTokens() public view {
        assertTrue(executor.pairKey(address(nvda), address(usdg)) != executor.pairKey(address(usdg), address(nvda)));
    }
}
