// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BotInstanceNFT} from "../src/BotInstanceNFT.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {Token, MockPool} from "./TradeExecutor.t.sol";

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
    /// ln(2)/ln(1.0001): o tick em que o ativo vale 2 de cotação.
    int24 constant TICK_2 = 6931;

    address key;

    function setUp() public {
        nft = new BotInstanceNFT(multisig, treasury, 1_000, 0);
        executor = new TradeExecutor(multisig, IERC721(address(nft)), operator, treasury, 1_000, 1_000);
        usdg = new Token("USDG");
        nvda = new Token("NVDA");
        aggregator = new MockAggregator();
        pool = new MockPool(address(usdg), address(nvda));
        baseIsToken0 = address(nvda) < address(usdg);
        key = executor.pairKey(address(nvda), address(usdg));

        usdg.mint(address(aggregator), 1e30);
        nvda.mint(address(aggregator), 1e30);

        vm.startPrank(multisig);
        nft.setTransferGuard(executor);
        executor.setAggregator(address(aggregator), true);
        executor.setQuoteToken(address(usdg), true);
        vm.stopPrank();

        _onboard(alice);
        _onboard(bob);
    }

    /// Minta a instância, libera o par, define o limite e dá os allowances.
    function _onboard(address user) internal {
        usdg.mint(user, FUNDS);
        vm.startPrank(user);
        uint256 tokenId = nft.mint(address(0));
        executor.setLimits(tokenId, 10_000e18, false);
        executor.setMarketAllowed(tokenId, key, true);
        usdg.approve(address(executor), type(uint256).max);
        nvda.approve(address(executor), type(uint256).max);
        vm.stopPrank();
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

    /// Compra a 2 de cotação por ativo.
    function _open(uint256 tokenId, uint256 quoteIn) internal {
        vm.prank(operator);
        executor.openViaAggregator(
            _one(tokenId),
            _pair(),
            _one(quoteIn),
            0,
            block.timestamp,
            _route(usdg, nvda, quoteIn, quoteIn / 2, address(executor))
        );
    }

    /// Vende a posição inteira por `quoteOut`.
    function _close(uint256 tokenId, uint256 quoteOut) internal {
        (uint256 base,) = executor.positions(tokenId, key);
        vm.prank(operator);
        executor.closeViaAggregator(
            _one(tokenId),
            _pair(),
            new address[](1),
            0,
            block.timestamp,
            _route(nvda, usdg, base, quoteOut, address(executor))
        );
    }

    // ===== abrir e fechar =====

    function test_openPullsQuoteAndLeavesTheAssetInTheOwnersWallet() public {
        _open(ALICE, 1_000e18);

        assertEq(usdg.balanceOf(alice), FUNDS - 1_000e18);
        assertEq(nvda.balanceOf(alice), 500e18);
        (uint256 base, uint256 cost) = executor.positions(ALICE, key);
        assertEq(base, 500e18);
        assertEq(cost, 1_000e18);
        assertTrue(executor.isLocked(ALICE));

        // Nada fica no executor, e o agregador não guarda aprovação nenhuma.
        assertEq(usdg.balanceOf(address(executor)), 0);
        assertEq(nvda.balanceOf(address(executor)), 0);
        assertEq(usdg.allowance(address(executor), address(aggregator)), 0);

        (address base_, address quote_) = executor.pairs(key);
        assertEq(base_, address(nvda));
        assertEq(quote_, address(usdg));
    }

    function test_closeWithProfitChargesTheFeeAndReturnsTheRest() public {
        _open(ALICE, 1_000e18);
        _close(ALICE, 1_500e18);

        // Lucro 500, taxa de 10% = 50.
        assertEq(usdg.balanceOf(alice), FUNDS + 450e18);
        assertEq(nvda.balanceOf(alice), 0);
        assertEq(executor.claimable(treasury, address(usdg)), 50e18);
        assertEq(usdg.balanceOf(address(executor)), 50e18);
        assertEq(nvda.allowance(address(executor), address(aggregator)), 0);
        assertFalse(executor.isLocked(ALICE));
    }

    function test_batchSplitsOneSwapProRataAndPaysTheLeader() public {
        vm.prank(bob);
        executor.follow(BOB, ALICE);

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (ALICE, BOB);
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (1_000e18, 3_000e18);

        vm.prank(operator);
        executor.openViaAggregator(
            ids, _pair(), amounts, 0, block.timestamp, _route(usdg, nvda, 4_000e18, 2_000e18, address(executor))
        );
        assertEq(nvda.balanceOf(alice), 500e18);
        assertEq(nvda.balanceOf(bob), 1_500e18);

        vm.prank(operator);
        executor.closeViaAggregator(
            ids,
            _pair(),
            new address[](2),
            0,
            block.timestamp,
            _route(nvda, usdg, 2_000e18, 6_000e18, address(executor))
        );

        // Alice: lucro 500, paga 50. Bob: lucro 1500, paga 150 + 150 ao líder.
        assertEq(usdg.balanceOf(alice), FUNDS + 450e18);
        assertEq(usdg.balanceOf(bob), FUNDS + 1_200e18);
        assertEq(executor.claimable(alice, address(usdg)), 150e18);
        assertEq(executor.claimable(treasury, address(usdg)), 200e18);
    }

    // ===== travas de entrada =====

    function test_onlyTheOperatorTrades() public {
        TradeExecutor.Route memory route = _route(usdg, nvda, 1_000e18, 500e18, address(executor));
        vm.expectRevert(TradeExecutor.NotOperator.selector);
        vm.prank(alice);
        executor.openViaAggregator(_one(ALICE), _pair(), _one(1_000e18), 0, block.timestamp, route);

        _open(ALICE, 1_000e18);
        vm.expectRevert(TradeExecutor.NotOperator.selector);
        vm.prank(alice);
        executor.closeViaAggregator(_one(ALICE), _pair(), new address[](1), 0, block.timestamp, route);
    }

    function test_ownerLimitsApplyToTheAggregatorPathToo() public {
        // Par não liberado pelo dono.
        vm.prank(alice);
        executor.setMarketAllowed(ALICE, key, false);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.MarketNotAllowed.selector, ALICE, key));
        _open(ALICE, 1_000e18);

        vm.prank(alice);
        executor.setMarketAllowed(ALICE, key, true);

        // Acima do limite por trade.
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.OverTradeLimit.selector, ALICE, 10_001e18, 10_000e18));
        _open(ALICE, 10_001e18);

        // Pausada.
        vm.prank(alice);
        executor.setLimits(ALICE, 10_000e18, true);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InstancePaused.selector, ALICE));
        _open(ALICE, 1_000e18);
    }

    function test_onlyApprovedAggregatorsAndQuoteTokens() public {
        MockAggregator rogue = new MockAggregator();
        TradeExecutor.Route memory route = TradeExecutor.Route(
            address(rogue),
            abi.encodeCall(MockAggregator.swap, (address(usdg), address(nvda), 1_000e18, 500e18, address(executor)))
        );
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.AggregatorNotAllowed.selector, address(rogue)));
        vm.prank(operator);
        executor.openViaAggregator(_one(ALICE), _pair(), _one(1_000e18), 0, block.timestamp, route);

        // O ativo não serve de cotação: as taxas seriam contadas nele.
        TradeExecutor.Pair memory inverted = TradeExecutor.Pair(address(usdg), address(nvda));
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.QuoteTokenNotAllowed.selector, address(nvda)));
        vm.prank(operator);
        executor.openViaAggregator(
            _one(ALICE),
            inverted,
            _one(1_000e18),
            0,
            block.timestamp,
            _route(usdg, nvda, 1_000e18, 500e18, address(executor))
        );
    }

    function test_openRejectsNonsensePairsDeadlineAndDuplicate() public {
        vm.prank(multisig);
        executor.setQuoteToken(address(nvda), true);
        TradeExecutor.Route memory route = _route(usdg, nvda, 1_000e18, 500e18, address(executor));

        vm.expectRevert(TradeExecutor.InvalidPair.selector);
        vm.prank(operator);
        executor.openViaAggregator(
            _one(ALICE), TradeExecutor.Pair(address(nvda), address(nvda)), _one(1_000e18), 0, block.timestamp, route
        );

        vm.expectRevert(TradeExecutor.Expired.selector);
        vm.prank(operator);
        executor.openViaAggregator(_one(ALICE), _pair(), _one(1_000e18), 0, block.timestamp - 1, route);

        _open(ALICE, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.PositionExists.selector, ALICE, key));
        _open(ALICE, 1_000e18);

        // Fechar um par nunca usado.
        vm.expectRevert(TradeExecutor.InvalidPair.selector);
        vm.prank(operator);
        executor.closeViaAggregator(
            _one(ALICE), TradeExecutor.Pair(address(usdg), address(nvda)), new address[](1), 0, block.timestamp, route
        );
    }

    // ===== o que o contrato mede =====

    function test_outputSentElsewhereDoesNotCount() public {
        // A rota manda o ativo para outro endereço: aqui não chegou nada.
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InsufficientOutput.selector, 0, 490e18));
        vm.prank(operator);
        executor.openViaAggregator(
            _one(ALICE), _pair(), _one(1_000e18), 490e18, block.timestamp, _route(usdg, nvda, 1_000e18, 500e18, thief)
        );
        assertEq(usdg.balanceOf(alice), FUNDS);
    }

    function test_openThatDeliversNothingReverts() public {
        // Sem mínimo pedido e com a saída desviada: abrir uma "posição" de
        // zero deixaria a instância travada, então a chamada falha.
        vm.expectRevert(TradeExecutor.ZeroAmount.selector);
        vm.prank(operator);
        executor.openViaAggregator(
            _one(ALICE), _pair(), _one(1_000e18), 0, block.timestamp, _route(usdg, nvda, 1_000e18, 500e18, thief)
        );
    }

    /// O limite do caminho pelo agregador sem referência de preço: uma
    /// operadora comprometida consegue desviar um trade. A pausa por perda
    /// impede o segundo.
    function test_compromisedOperatorIsStoppedAfterOneTradePerPair() public {
        vm.prank(multisig);
        executor.setLossPause(5_000);

        // A operadora não consegue mandar a saída direto ao ladrão (o
        // contrato exige ativo de volta), mas consegue trocar a um preço
        // absurdo num agregador que aceite a rota: 1000 de cotação por 1 wei.
        vm.prank(operator);
        executor.openViaAggregator(
            _one(ALICE), _pair(), _one(1_000e18), 0, block.timestamp, _route(usdg, nvda, 1_000e18, 1, address(executor))
        );
        assertEq(usdg.balanceOf(alice), FUNDS - 1_000e18);

        // Ao fechar, a perda é total e a instância para.
        _close(ALICE, 1);
        (, bool paused) = executor.limits(ALICE);
        assertTrue(paused);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InstancePaused.selector, ALICE));
        _open(ALICE, 1_000e18);

        // Com referência de preço o mesmo desvio nem começa.
        _setReference();
        vm.expectPartialRevert(TradeExecutor.PriceDeviation.selector);
        vm.prank(operator);
        executor.openViaAggregator(
            _one(BOB), _pair(), _one(1_000e18), 0, block.timestamp, _route(usdg, nvda, 1_000e18, 1, address(executor))
        );
    }

    function test_minOutIsEnforced() public {
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InsufficientOutput.selector, 500e18, 501e18));
        vm.prank(operator);
        executor.openViaAggregator(
            _one(ALICE),
            _pair(),
            _one(1_000e18),
            501e18,
            block.timestamp,
            _route(usdg, nvda, 1_000e18, 500e18, address(executor))
        );
    }

    function test_partialFillAndFailedRouteRevert() public {
        // Rota que consome só parte da entrada.
        vm.expectRevert(TradeExecutor.SwapNotFilled.selector);
        vm.prank(operator);
        executor.openViaAggregator(
            _one(ALICE),
            _pair(),
            _one(1_000e18),
            0,
            block.timestamp,
            _route(usdg, nvda, 600e18, 300e18, address(executor))
        );

        vm.expectRevert(TradeExecutor.AggregatorCallFailed.selector);
        vm.prank(operator);
        executor.openViaAggregator(
            _one(ALICE),
            _pair(),
            _one(1_000e18),
            0,
            block.timestamp,
            TradeExecutor.Route(address(aggregator), abi.encodeCall(MockAggregator.noRoute, ()))
        );
    }

    function test_aggregatorCannotReachTheFeesHeldByTheExecutor() public {
        // Um trade com lucro deixa 50 de taxa no executor.
        _open(ALICE, 1_000e18);
        _close(ALICE, 1_500e18);
        assertEq(usdg.balanceOf(address(executor)), 50e18);

        // Rota que tenta puxar a entrada de Bob mais a taxa guardada: a
        // aprovação é só da entrada, então a chamada falha.
        vm.expectRevert(TradeExecutor.AggregatorCallFailed.selector);
        vm.prank(operator);
        executor.openViaAggregator(
            _one(BOB),
            _pair(),
            _one(1_000e18),
            0,
            block.timestamp,
            _route(usdg, nvda, 1_050e18, 525e18, address(executor))
        );
        assertEq(usdg.balanceOf(address(executor)), 50e18);
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

        // Preço médio 2: 1000 de cotação valem ~500 de ativo. A rota entrega 400.
        vm.expectPartialRevert(TradeExecutor.PriceDeviation.selector);
        vm.prank(operator);
        executor.openViaAggregator(
            _one(ALICE),
            _pair(),
            _one(1_000e18),
            0,
            block.timestamp,
            _route(usdg, nvda, 1_000e18, 400e18, address(executor))
        );

        // Dentro da tolerância de 1% passa — inclusive com a taxa do agregador.
        vm.prank(operator);
        executor.openViaAggregator(
            _one(ALICE),
            _pair(),
            _one(1_000e18),
            0,
            block.timestamp,
            _route(usdg, nvda, 1_000e18, 497e18, address(executor))
        );

        // Na saída também: vender 497 a preço médio 2 dá ~994; 800 é recusado.
        (uint256 base,) = executor.positions(ALICE, key);
        vm.expectPartialRevert(TradeExecutor.PriceDeviation.selector);
        vm.prank(operator);
        executor.closeViaAggregator(
            _one(ALICE),
            _pair(),
            new address[](1),
            0,
            block.timestamp,
            _route(nvda, usdg, base, 800e18, address(executor))
        );
    }

    function test_referenceMustBeARegisteredPoolOfTheSamePair() public {
        vm.startPrank(multisig);
        // Pool não cadastrado.
        vm.expectRevert(TradeExecutor.InvalidMarket.selector);
        executor.setPairReference(address(nvda), address(usdg), address(pool));

        executor.setMarket(address(pool), address(nvda), address(usdg), true, 600, 100);
        // Par invertido.
        vm.expectRevert(TradeExecutor.InvalidMarket.selector);
        executor.setPairReference(address(usdg), address(nvda), address(pool));

        executor.setPairReference(address(nvda), address(usdg), address(pool));
        assertEq(executor.referencePool(key), address(pool));
        executor.setPairReference(address(nvda), address(usdg), address(0));
        assertEq(executor.referencePool(key), address(0));
        vm.stopPrank();
    }

    // ===== pausa automática por perda =====

    function test_aTradeThatLosesAlmostEverythingPausesTheInstance() public {
        vm.prank(multisig);
        executor.setLossPause(5_000);

        // Perda de 40%: abaixo do gatilho, a instância segue.
        _open(ALICE, 1_000e18);
        _close(ALICE, 600e18);
        (, bool paused) = executor.limits(ALICE);
        assertFalse(paused);

        // Perda de 60%: pausa.
        _open(ALICE, 1_000e18);
        vm.expectEmit(true, true, false, true);
        emit TradeExecutor.InstanceAutoPaused(ALICE, key, 1_000e18, 400e18);
        _close(ALICE, 400e18);
        (uint256 maxPerTrade, bool pausedNow) = executor.limits(ALICE);
        assertTrue(pausedNow);
        assertEq(maxPerTrade, 10_000e18);

        // Pausada, não abre mais — é o que limita o dano de uma operadora
        // comprometida a um trade por par.
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InstancePaused.selector, ALICE));
        _open(ALICE, 1_000e18);

        // O dono olha e reativa.
        vm.prank(alice);
        executor.setLimits(ALICE, 10_000e18, false);
        _open(ALICE, 1_000e18);
    }

    function test_lossPauseIsOffByDefaultAndCapped() public {
        _open(ALICE, 1_000e18);
        _close(ALICE, 1e18);
        (, bool paused) = executor.limits(ALICE);
        assertFalse(paused);

        vm.expectRevert(TradeExecutor.InvalidFees.selector);
        vm.prank(multisig);
        executor.setLossPause(10_001);
    }

    // ===== sair sempre =====

    function test_closingWorksWhilePausedAndWithTheQuoteTokenDelisted() public {
        _open(ALICE, 1_000e18);

        vm.prank(alice);
        executor.setLimits(ALICE, 0, true);
        vm.prank(multisig);
        executor.setQuoteToken(address(usdg), false);

        _close(ALICE, 1_000e18);
        assertEq(usdg.balanceOf(alice), FUNDS);
        assertFalse(executor.isLocked(ALICE));
    }

    function test_ownerCanAbandonAndTheOperatorOnlyWhatCannotBeClosed() public {
        _open(ALICE, 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.PositionStillClosable.selector, ALICE, key));
        vm.prank(operator);
        executor.abandonPosition(ALICE, key);

        // Agregador removido da lista (comprometido, por exemplo): o dono sai
        // sozinho, com o ativo que já está na carteira dele.
        vm.prank(multisig);
        executor.setAggregator(address(aggregator), false);
        vm.prank(alice);
        executor.abandonPosition(ALICE, key);
        assertEq(nvda.balanceOf(alice), 500e18);
        assertFalse(executor.isLocked(ALICE));
    }

    // ===== administração =====

    function test_onlyTheMultisigAdministersTheAggregatorPath() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator);
        vm.startPrank(operator);

        vm.expectRevert(unauthorized);
        executor.setAggregator(address(aggregator), true);
        vm.expectRevert(unauthorized);
        executor.setQuoteToken(address(nvda), true);
        vm.expectRevert(unauthorized);
        executor.setPairReference(address(nvda), address(usdg), address(0));
        vm.expectRevert(unauthorized);
        executor.setLossPause(5_000);

        vm.stopPrank();
    }

    function test_pairKeyDependsOnTheOrderOfTheTokens() public view {
        assertTrue(executor.pairKey(address(nvda), address(usdg)) != executor.pairKey(address(usdg), address(nvda)));
    }
}
