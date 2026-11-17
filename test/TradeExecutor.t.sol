// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BotInstanceNFT} from "../src/BotInstanceNFT.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {InstanceVault} from "../src/InstanceVault.sol";
import {Token, MockWETH, MockPool} from "./Mocks.sol";

/// O caminho do pool direto, os cofres e a taxa de volume.
contract TradeExecutorTest is Test {
    BotInstanceNFT nft;
    TradeExecutor executor;
    MockWETH weth;
    Token usdg;
    Token nvda;
    MockPool pool;
    bool baseIsToken0;

    address multisig = makeAddr("multisig");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant ALICE = 1;
    uint256 constant BOB = 2;
    uint256 constant CAROL = 3;
    uint256 constant FUNDS = 100_000e18;
    /// 0,5%.
    uint16 constant FEE = 50;
    bytes32 constant DECISION = keccak256("decision");

    // Tick do preço médio para cada preço do ativo em cotação usado nos testes.
    int24 constant TICK_2 = 6931;
    int24 constant TICK_3 = 10986;
    int24 constant TICK_1 = 0;

    function setUp() public {
        nft = new BotInstanceNFT(multisig, treasury, 1_000, 0);
        weth = new MockWETH();
        executor = new TradeExecutor(multisig, IERC721(address(nft)), address(weth), operator, treasury, FEE);
        usdg = new Token("USDG");
        nvda = new Token("NVDA");
        pool = new MockPool(address(usdg), address(nvda));
        baseIsToken0 = address(nvda) < address(usdg);

        usdg.mint(address(pool), 1e30);
        nvda.mint(address(pool), 1e30);

        vm.prank(multisig);
        executor.setMarket(address(pool), address(nvda), address(usdg), true, 600, 100);

        _onboard(alice);
        _onboard(bob);
        _onboard(carol);
        _price(2, TICK_2);
    }

    /// Minta a instância, libera o mercado, define o limite e deposita no
    /// cofre — o que um usuário faz no onboarding. O cofre ainda não existe:
    /// o depósito vai para o endereço previsto.
    function _onboard(address user) internal {
        vm.startPrank(user);
        uint256 tokenId = nft.mint(address(0));
        executor.setLimits(tokenId, 10_000e18, false, false);
        executor.setMarketAllowed(tokenId, address(pool), true);
        vm.stopPrank();
        usdg.mint(executor.vaultOf(tokenId), FUNDS);
    }

    function _vault(uint256 tokenId) internal view returns (address) {
        return executor.vaultOf(tokenId);
    }

    /// Preço do ativo em cotação: o de execução e o médio.
    function _price(uint256 quotePerBase, int24 twapTick) internal {
        _execPrice(quotePerBase * 1000);
        pool.setTwapTick(baseIsToken0 ? twapTick : -twapTick);
    }

    function _execPrice(uint256 quotePerBaseMilli) internal {
        if (baseIsToken0) pool.setExecPrice(quotePerBaseMilli, 1000);
        else pool.setExecPrice(1000, quotePerBaseMilli);
    }

    function _one(uint256 value) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = value;
    }

    function _open(uint256 tokenId, uint256 quoteIn) internal {
        vm.prank(operator);
        executor.openPositions(_one(tokenId), address(pool), _one(quoteIn), 0, FEE, block.timestamp, DECISION);
    }

    function _close(uint256 tokenId) internal {
        vm.prank(operator);
        executor.closePositions(_one(tokenId), address(pool), 0, FEE, block.timestamp, DECISION);
    }

    // ===== cofres =====

    function test_vaultIsCreatedOnTheFirstTradeAtThePredictedAddress() public {
        address vault = _vault(ALICE);
        assertEq(vault.code.length, 0);
        assertEq(usdg.balanceOf(vault), FUNDS);

        _open(ALICE, 1_000e18);

        assertGt(vault.code.length, 0);
        assertEq(InstanceVault(payable(vault)).tokenId(), ALICE);
        assertEq(InstanceVault(payable(vault)).executor(), address(executor));
        assertTrue(_vault(ALICE) != _vault(BOB));
    }

    function test_anyoneCanCreateAVaultAndOnlyOnce() public {
        address vault = executor.createVault(ALICE);
        assertEq(vault, _vault(ALICE));
        // Chamar de novo devolve o mesmo cofre.
        assertEq(executor.createVault(ALICE), vault);

        vm.expectRevert(InstanceVault.AlreadyInitialized.selector);
        InstanceVault(payable(vault)).initialize(IERC721(address(nft)), BOB);
    }

    function test_onlyTheExecutorMovesVaultFunds() public {
        InstanceVault vault = InstanceVault(payable(executor.createVault(ALICE)));

        vm.startPrank(operator);
        vm.expectRevert(InstanceVault.NotExecutor.selector);
        vault.transferOut(address(usdg), operator, 1);
        vm.expectRevert(InstanceVault.NotExecutor.selector);
        vault.execute(address(usdg), 0, abi.encodeCall(usdg.transfer, (operator, 1)));
        vm.stopPrank();
    }

    function test_ownerWithdrawsAnythingAnytimeEvenWithAnOpenPosition() public {
        _open(ALICE, 1_000e18);
        InstanceVault vault = InstanceVault(payable(_vault(ALICE)));

        vm.startPrank(alice);
        vault.withdraw(address(nvda), type(uint256).max);
        vault.withdraw(address(usdg), 1_000e18);
        vm.stopPrank();

        assertEq(nvda.balanceOf(alice), 497.5e18);
        assertEq(usdg.balanceOf(alice), 1_000e18);

        vm.expectRevert(InstanceVault.NotInstanceOwner.selector);
        vm.prank(bob);
        vault.withdraw(address(usdg), 1);
    }

    function test_ownerWithdrawsNativeEth() public {
        InstanceVault vault = InstanceVault(payable(executor.createVault(ALICE)));
        vm.deal(address(vault), 1 ether);

        vm.prank(alice);
        vault.withdrawNative(type(uint256).max);
        assertEq(alice.balance, 1 ether);
    }

    function test_transferringTheNftTransfersTheVault() public {
        _open(ALICE, 1_000e18);
        InstanceVault vault = InstanceVault(payable(_vault(ALICE)));

        // Com posição aberta: não há trava.
        vm.prank(alice);
        nft.transferFrom(alice, bob, ALICE);

        vm.expectRevert(InstanceVault.NotInstanceOwner.selector);
        vm.prank(alice);
        vault.withdraw(address(usdg), 1);

        // A posição continua e fecha para o mesmo cofre.
        _close(ALICE);
        vm.prank(bob);
        vault.withdraw(address(usdg), type(uint256).max);
        assertGt(usdg.balanceOf(bob), FUNDS - 1_000e18);
    }

    function test_operatorWrapsEthDepositedInTheVault() public {
        address vault = _vault(ALICE);
        vm.deal(vault, 2 ether);

        vm.prank(operator);
        executor.wrapNative(ALICE);

        assertEq(weth.balanceOf(vault), 2 ether);
        assertEq(vault.balance, 0);

        vm.expectRevert(TradeExecutor.NotOperator.selector);
        vm.prank(alice);
        executor.wrapNative(ALICE);
    }

    // ===== abrir =====

    function test_openTakesTheFeeAndPutsTheAssetInTheVault() public {
        vm.expectEmit(address(executor));
        emit TradeExecutor.PositionOpened(ALICE, address(pool), 1_000e18, 5e18, 497.5e18, DECISION);
        _open(ALICE, 1_000e18);

        address vault = _vault(ALICE);
        // 0,5% de 1000 = 5 de taxa; 995 trocados a 2 = 497,5.
        assertEq(usdg.balanceOf(vault), FUNDS - 1_000e18);
        assertEq(nvda.balanceOf(vault), 497.5e18);
        assertEq(executor.claimable(treasury, address(usdg)), 5e18);
        // O executor guarda só a taxa.
        assertEq(usdg.balanceOf(address(executor)), 5e18);
        assertEq(nvda.balanceOf(address(executor)), 0);

        (uint256 base, uint256 cost) = executor.positions(ALICE, address(pool));
        assertEq(base, 497.5e18);
        assertEq(cost, 1_000e18);
    }

    function test_onlyTheOperatorTrades() public {
        vm.expectRevert(TradeExecutor.NotOperator.selector);
        vm.prank(alice);
        executor.openPositions(_one(ALICE), address(pool), _one(1_000e18), 0, FEE, block.timestamp, DECISION);

        _open(ALICE, 1_000e18);
        vm.expectRevert(TradeExecutor.NotOperator.selector);
        vm.prank(alice);
        executor.closePositions(_one(ALICE), address(pool), 0, FEE, block.timestamp, DECISION);
    }

    function test_instanceDoesNotTradeUntilTheOwnerSetsALimit() public {
        vm.startPrank(multisig);
        uint256 fresh = nft.mint(address(0));
        executor.setMarketAllowed(fresh, address(pool), true);
        vm.stopPrank();
        usdg.mint(_vault(fresh), FUNDS);

        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.OverTradeLimit.selector, fresh, 1e18, 0));
        _open(fresh, 1e18);
    }

    function test_ownerLimitsAreEnforcedOnEntry() public {
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.OverTradeLimit.selector, ALICE, 10_001e18, 10_000e18));
        _open(ALICE, 10_001e18);

        vm.prank(alice);
        executor.setLimits(ALICE, 10_000e18, true, false);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InstancePaused.selector, ALICE));
        _open(ALICE, 1_000e18);

        vm.startPrank(alice);
        executor.setLimits(ALICE, 10_000e18, false, false);
        executor.setMarketAllowed(ALICE, address(pool), false);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.MarketNotAllowed.selector, ALICE, address(pool)));
        _open(ALICE, 1_000e18);

        // `anyMarket` libera sem precisar do mercado um a um.
        vm.prank(alice);
        executor.setLimits(ALICE, 10_000e18, false, true);
        _open(ALICE, 1_000e18);
    }

    function test_onlyTheInstanceOwnerSetsItsLimits() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotInstanceOwner.selector, ALICE));
        executor.setLimits(ALICE, type(uint256).max, false, true);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotInstanceOwner.selector, ALICE));
        executor.setMarketAllowed(ALICE, address(pool), true);
        vm.stopPrank();
    }

    function test_openRejectsDisabledMarketDeadlineZeroAndDuplicate() public {
        vm.expectRevert(TradeExecutor.ZeroAmount.selector);
        _open(ALICE, 0);

        vm.expectRevert(TradeExecutor.Expired.selector);
        vm.prank(operator);
        executor.openPositions(_one(ALICE), address(pool), _one(1e18), 0, FEE, block.timestamp - 1, DECISION);

        _open(ALICE, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.PositionExists.selector, ALICE, address(pool)));
        _open(ALICE, 1_000e18);

        vm.prank(multisig);
        executor.setMarket(address(pool), address(nvda), address(usdg), false, 600, 100);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.MarketDisabled.selector, address(pool)));
        _open(BOB, 1_000e18);
    }

    function test_minOutIsEnforced() public {
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InsufficientOutput.selector, 497.5e18, 498e18));
        vm.prank(operator);
        executor.openPositions(_one(ALICE), address(pool), _one(1_000e18), 498e18, FEE, block.timestamp, DECISION);
    }

    function test_partialFillReverts() public {
        pool.setMaxFill(400e18);
        vm.expectRevert(TradeExecutor.SwapNotFilled.selector);
        _open(ALICE, 1_000e18);
    }

    // ===== guarda de preço =====

    function test_entryAtAPriceFarFromTheAverageIsRefused() public {
        // Preço médio 2, mas o swap executa a 2,3: o usuário receberia 13%
        // menos ativo. É o cenário da operadora que moveu o pool antes.
        _execPrice(2_300);
        vm.expectPartialRevert(TradeExecutor.PriceDeviation.selector);
        _open(ALICE, 1_000e18);

        // Dentro da tolerância de 1% passa.
        _execPrice(2_015);
        _open(ALICE, 1_000e18);
    }

    function test_exitAtAPriceFarFromTheAverageIsRefused() public {
        _open(ALICE, 1_000e18);

        _execPrice(1_700);
        vm.expectPartialRevert(TradeExecutor.PriceDeviation.selector);
        _close(ALICE);

        // Um preço MELHOR que a média nunca é barrado.
        _execPrice(2_500);
        _close(ALICE);
    }

    // ===== fechar e taxa =====

    function test_closeTakesTheFeeOnProceedsAndReturnsTheRestToTheVault() public {
        _open(ALICE, 1_000e18);
        _price(3, TICK_3);

        // 497,5 vendidos a 3 = 1492,5. Taxa de 0,5% = 7,4625.
        vm.expectEmit(address(executor));
        emit TradeExecutor.PositionClosed(ALICE, address(pool), 497.5e18, 1_492.5e18, 7.4625e18, 485.0375e18, DECISION);
        _close(ALICE);

        address vault = _vault(ALICE);
        assertEq(usdg.balanceOf(vault), FUNDS - 1_000e18 + 1_485.0375e18);
        assertEq(nvda.balanceOf(vault), 0);
        assertEq(executor.claimable(treasury, address(usdg)), 12.4625e18);
        assertEq(usdg.balanceOf(address(executor)), 12.4625e18);

        (uint256 base,) = executor.positions(ALICE, address(pool));
        assertEq(base, 0);

        vm.prank(treasury);
        executor.withdraw(address(usdg));
        assertEq(usdg.balanceOf(treasury), 12.4625e18);
        assertEq(usdg.balanceOf(address(executor)), 0);
    }

    function test_theFeeIsChargedAtALossToo() public {
        // A taxa é de volume, não de lucro.
        _open(ALICE, 1_000e18);
        _price(1, TICK_1);
        _close(ALICE);
        // 497,5 a 1 = 497,5; taxa 2,4875.
        assertEq(executor.claimable(treasury, address(usdg)), 5e18 + 2.4875e18);
    }

    function test_operatorChargesLessOrNothingButNeverMoreThanTheCap() public {
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.FeeTooHigh.selector, FEE + 1, FEE));
        vm.prank(operator);
        executor.openPositions(_one(ALICE), address(pool), _one(1_000e18), 0, FEE + 1, block.timestamp, DECISION);

        // Num AMM parceiro a operadora passa zero.
        vm.prank(operator);
        executor.openPositions(_one(ALICE), address(pool), _one(1_000e18), 0, 0, block.timestamp, DECISION);
        assertEq(executor.claimable(treasury, address(usdg)), 0);
        assertEq(nvda.balanceOf(_vault(ALICE)), 500e18);
    }

    function test_exemptInstancePaysNothing() public {
        vm.prank(operator);
        executor.setFeeExempt(ALICE, true);

        _open(ALICE, 1_000e18);
        _close(ALICE);
        assertEq(executor.claimable(treasury, address(usdg)), 0);

        vm.expectRevert(TradeExecutor.NotOperator.selector);
        vm.prank(alice);
        executor.setFeeExempt(ALICE, false);
    }

    function test_volumeFeeIsCappedAtOnePercent() public {
        vm.startPrank(multisig);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.FeeTooHigh.selector, 101, 100));
        executor.setVolumeFee(101);
        executor.setVolumeFee(100);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.FeeTooHigh.selector, 101, 100));
        new TradeExecutor(multisig, IERC721(address(nft)), address(weth), operator, treasury, 101);
    }

    function test_closingWorksWhilePausedAndWithTheMarketDisabled() public {
        _open(ALICE, 1_000e18);

        vm.prank(alice);
        executor.setLimits(ALICE, 0, true, false);
        vm.prank(multisig);
        executor.setMarket(address(pool), address(nvda), address(usdg), false, 600, 100);

        _close(ALICE);
        (uint256 base,) = executor.positions(ALICE, address(pool));
        assertEq(base, 0);
    }

    function test_closeWithoutPositionReverts() public {
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NoPosition.selector, ALICE, address(pool)));
        _close(ALICE);
    }

    // ===== o dono mexeu no cofre =====

    function test_closeSellsWhatIsLeftWhenTheOwnerWithdrewPart() public {
        _open(ALICE, 1_000e18);
        InstanceVault vault = InstanceVault(payable(_vault(ALICE)));
        vm.prank(alice);
        vault.withdraw(address(nvda), 97.5e18);

        vm.recordLogs();
        _close(ALICE);
        // Vendeu 400 a 2 = 800. Custo proporcional: 1000 × 400/497,5.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 baseIn, uint256 quoteOut, uint256 fee, int256 pnl,) =
            abi.decode(logs[logs.length - 1].data, (uint256, uint256, uint256, int256, bytes32));
        assertEq(baseIn, 400e18);
        assertEq(quoteOut, 800e18);
        assertEq(fee, 4e18);
        assertEq(pnl, int256(796e18) - int256(uint256(1_000e18 * 400e18) / 497.5e18));
    }

    function test_operatorDropsAPositionOnlyWhenTheAssetIsGone() public {
        _open(ALICE, 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.PositionStillHeld.selector, ALICE, address(pool)));
        vm.prank(operator);
        executor.dropPosition(ALICE, address(pool));

        InstanceVault vault = InstanceVault(payable(_vault(ALICE)));
        vm.prank(alice);
        vault.withdraw(address(nvda), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NoPosition.selector, ALICE, address(pool)));
        _close(ALICE);

        vm.prank(operator);
        executor.dropPosition(ALICE, address(pool));
        (uint256 base,) = executor.positions(ALICE, address(pool));
        assertEq(base, 0);
    }

    function test_ownerCanAlwaysDropAndKeepsTheAsset() public {
        _open(ALICE, 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotInstanceOwner.selector, ALICE));
        vm.prank(bob);
        executor.dropPosition(ALICE, address(pool));

        vm.prank(alice);
        executor.dropPosition(ALICE, address(pool));
        assertEq(nvda.balanceOf(_vault(ALICE)), 497.5e18);
        // Sem posição, nada a fechar.
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NoPosition.selector, ALICE, address(pool)));
        _close(ALICE);
    }

    // ===== lote (copy trade) =====

    function _batch() internal pure returns (uint256[] memory ids, uint256[] memory amounts) {
        ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (ALICE, BOB, CAROL);
        amounts = new uint256[](3);
        (amounts[0], amounts[1], amounts[2]) = (1_000e18, 3_000e18, 500e18);
    }

    function test_batchEntersEveryoneAtTheSamePriceProRata() public {
        (uint256[] memory ids, uint256[] memory amounts) = _batch();
        vm.prank(operator);
        executor.openPositions(ids, address(pool), amounts, 0, FEE, block.timestamp, DECISION);

        assertEq(nvda.balanceOf(_vault(ALICE)), 497.5e18);
        assertEq(nvda.balanceOf(_vault(BOB)), 1_492.5e18);
        assertEq(nvda.balanceOf(_vault(CAROL)), 248.75e18);
        assertEq(executor.claimable(treasury, address(usdg)), 22.5e18);
    }

    function test_oneExemptInstanceInABatchStillGetsItsFairShare() public {
        vm.prank(multisig);
        executor.setFeeExempt(BOB, true);
        (uint256[] memory ids, uint256[] memory amounts) = _batch();
        vm.prank(operator);
        executor.openPositions(ids, address(pool), amounts, 0, FEE, block.timestamp, DECISION);

        assertEq(nvda.balanceOf(_vault(ALICE)), 497.5e18);
        assertEq(nvda.balanceOf(_vault(BOB)), 1_500e18);
        assertEq(executor.claimable(treasury, address(usdg)), 7.5e18);
    }

    function test_batchRejectsMismatchedOrEmptyInput() public {
        vm.startPrank(operator);
        vm.expectRevert(TradeExecutor.EmptyBatch.selector);
        executor.openPositions(new uint256[](0), address(pool), new uint256[](0), 0, FEE, block.timestamp, DECISION);
        vm.expectRevert(TradeExecutor.LengthMismatch.selector);
        executor.openPositions(_one(ALICE), address(pool), new uint256[](2), 0, FEE, block.timestamp, DECISION);
        vm.stopPrank();
    }

    function test_oneInstanceOverItsLimitRevertsTheWholeBatch() public {
        vm.prank(carol);
        executor.setLimits(CAROL, 100e18, false, false);
        (uint256[] memory ids, uint256[] memory amounts) = _batch();

        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.OverTradeLimit.selector, CAROL, 500e18, 100e18));
        vm.prank(operator);
        executor.openPositions(ids, address(pool), amounts, 0, FEE, block.timestamp, DECISION);

        assertEq(usdg.balanceOf(_vault(ALICE)), FUNDS);
    }

    function testFuzz_batchSplitsExactlyWhatTheSwapProduced(uint64 a, uint64 b, uint64 c, uint16 exitMilli) public {
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (ALICE, BOB, CAROL);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = bound(a, 1e6, 10_000e18);
        amounts[1] = bound(b, 1e6, 10_000e18);
        amounts[2] = bound(c, 1e6, 10_000e18);

        vm.prank(operator);
        executor.openPositions(ids, address(pool), amounts, 0, FEE, block.timestamp, DECISION);

        // Todo o ativo comprado foi para os cofres, nada ficou no executor.
        uint256 bought = nvda.balanceOf(_vault(ALICE)) + nvda.balanceOf(_vault(BOB)) + nvda.balanceOf(_vault(CAROL));
        uint256 entryFees = executor.claimable(treasury, address(usdg));
        assertEq(bought, (amounts[0] + amounts[1] + amounts[2] - entryFees) / 2);
        assertEq(nvda.balanceOf(address(executor)), 0);

        // Fecha a um preço entre 1,99 e 2,01 (dentro da tolerância do TWAP).
        uint256 exit = bound(exitMilli, 1_990, 2_010);
        _execPrice(exit);
        vm.prank(operator);
        executor.closePositions(ids, address(pool), 0, FEE, block.timestamp, DECISION);

        uint256 fees = executor.claimable(treasury, address(usdg));
        uint256 inVaults = usdg.balanceOf(_vault(ALICE)) + usdg.balanceOf(_vault(BOB)) + usdg.balanceOf(_vault(CAROL));

        // O executor guarda exatamente as taxas, e nada se perdeu no caminho.
        assertEq(usdg.balanceOf(address(executor)), fees);
        assertEq(
            inVaults + fees, 3 * FUNDS - (amounts[0] + amounts[1] + amounts[2]) + entryFees + (bought * exit) / 1000
        );
        assertEq(nvda.balanceOf(address(executor)), 0);
    }

    // ===== pausa automática por perda =====

    function test_aTradeThatLosesAlmostEverythingPausesTheInstance() public {
        vm.prank(multisig);
        executor.setLossPause(5_000);

        _open(ALICE, 1_000e18);
        // Preço médio e de execução despencam juntos: 0,2.
        pool.setTwapTick(baseIsToken0 ? int24(-16095) : int24(16095));
        _execPrice(200);
        _close(ALICE);

        (, bool paused,) = executor.limits(ALICE);
        assertTrue(paused);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InstancePaused.selector, ALICE));
        _open(ALICE, 1_000e18);
    }

    // ===== swap e administração =====

    function test_swapCallbackOnlyAnswersThePoolBeingSwapped() public {
        vm.expectRevert(TradeExecutor.BadCallback.selector);
        vm.prank(address(pool));
        executor.uniswapV3SwapCallback(1, 0, abi.encode(address(usdg)));
    }

    function test_withdrawRevertsWithNothingToClaim() public {
        vm.expectRevert(TradeExecutor.NothingToWithdraw.selector);
        vm.prank(treasury);
        executor.withdraw(address(usdg));
    }

    function test_onlyTheMultisigAdministers() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        executor.setMarket(address(pool), address(nvda), address(usdg), true, 600, 100);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        executor.setOperator(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        executor.setTreasury(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        executor.setVolumeFee(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        executor.setLossPause(0);
        vm.stopPrank();
    }

    function test_marketMustMatchThePoolAndHaveSaneParameters() public {
        vm.startPrank(multisig);
        vm.expectRevert(TradeExecutor.InvalidMarket.selector);
        executor.setMarket(address(pool), address(nvda), address(weth), true, 600, 100);
        vm.expectRevert(TradeExecutor.InvalidMarket.selector);
        executor.setMarket(address(pool), address(nvda), address(usdg), true, 0, 100);
        vm.expectRevert(TradeExecutor.InvalidMarket.selector);
        executor.setMarket(address(pool), address(nvda), address(usdg), true, 600, 1_001);
        vm.stopPrank();
    }

    function test_rotatedOperatorLosesAccess() public {
        address next = makeAddr("next");
        vm.prank(multisig);
        executor.setOperator(next);

        vm.expectRevert(TradeExecutor.NotOperator.selector);
        _open(ALICE, 1_000e18);

        vm.prank(next);
        executor.openPositions(_one(ALICE), address(pool), _one(1_000e18), 0, FEE, block.timestamp, DECISION);
    }
}
