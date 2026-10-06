// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {BotInstanceNFT} from "../src/BotInstanceNFT.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";

contract Token is ERC20 {
    constructor(string memory symbol_) ERC20(symbol_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Pool de mentira com a interface do Uniswap v3 que o executor usa: troca a
/// um preço fixo configurável e informa um preço médio (TWAP) configurável à
/// parte, para os testes poderem afastar um do outro.
contract MockPool {
    address public immutable token0;
    address public immutable token1;

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

contract TradeExecutorTest is Test {
    BotInstanceNFT nft;
    TradeExecutor executor;
    Token usdg;
    Token nvda;
    MockPool pool;
    bool baseIsToken0;

    address multisig = makeAddr("multisig");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address partner = makeAddr("partner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant ALICE = 1;
    uint256 constant BOB = 2;
    uint256 constant CAROL = 3;
    uint256 constant FUNDS = 100_000e18;

    // Tick do preço médio para cada preço do ativo em cotação usado nos testes.
    int24 constant TICK_2 = 6931;
    int24 constant TICK_3 = 10986;
    int24 constant TICK_1 = 0;

    function setUp() public {
        nft = new BotInstanceNFT(multisig, treasury, 1_000, 0);
        executor = new TradeExecutor(multisig, IERC721(address(nft)), operator, treasury, 1_000, 1_000);
        usdg = new Token("USDG");
        nvda = new Token("NVDA");
        pool = new MockPool(address(usdg), address(nvda));
        baseIsToken0 = address(nvda) < address(usdg);

        usdg.mint(address(pool), 1e30);
        nvda.mint(address(pool), 1e30);

        vm.startPrank(multisig);
        nft.setTransferGuard(executor);
        executor.setMarket(address(pool), address(nvda), address(usdg), true, 600, 100);
        vm.stopPrank();

        _onboard(alice);
        _onboard(bob);
        _onboard(carol);
        _price(2, TICK_2);
    }

    /// Minta a instância, libera o mercado, define o limite e dá os dois
    /// allowances — o que um usuário faz no onboarding.
    function _onboard(address user) internal {
        usdg.mint(user, FUNDS);
        vm.startPrank(user);
        uint256 tokenId = nft.mint(address(0));
        executor.setLimits(tokenId, 10_000e18, false);
        executor.setMarketAllowed(tokenId, address(pool), true);
        usdg.approve(address(executor), type(uint256).max);
        nvda.approve(address(executor), type(uint256).max);
        vm.stopPrank();
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

    function _noPartner(uint256 count) internal pure returns (address[] memory list) {
        list = new address[](count);
    }

    function _open(uint256 tokenId, uint256 quoteIn) internal {
        vm.prank(operator);
        executor.openPositions(_one(tokenId), address(pool), _one(quoteIn), 0, block.timestamp);
    }

    function _close(uint256 tokenId, address feeRecipient) internal {
        address[] memory recipients = new address[](1);
        recipients[0] = feeRecipient;
        vm.prank(operator);
        executor.closePositions(_one(tokenId), address(pool), recipients, 0, block.timestamp);
    }

    function _roundTrip(uint256 tokenId, uint256 quoteIn, uint256 exitPrice, int24 exitTick) internal {
        _price(2, TICK_2);
        _open(tokenId, quoteIn);
        _price(exitPrice, exitTick);
        _close(tokenId, address(0));
    }

    // ===== abrir =====

    function test_openPullsQuoteAndLeavesTheAssetInTheOwnersWallet() public {
        _open(ALICE, 1_000e18);

        assertEq(usdg.balanceOf(alice), FUNDS - 1_000e18);
        assertEq(nvda.balanceOf(alice), 500e18);
        // O contrato não fica com nada.
        assertEq(usdg.balanceOf(address(executor)), 0);
        assertEq(nvda.balanceOf(address(executor)), 0);

        (uint256 base, uint256 cost) = executor.positions(ALICE, address(pool));
        assertEq(base, 500e18);
        assertEq(cost, 1_000e18);
        assertEq(executor.openCount(ALICE), 1);
        assertTrue(executor.isLocked(ALICE));
    }

    function test_onlyTheOperatorTrades() public {
        vm.expectRevert(TradeExecutor.NotOperator.selector);
        vm.prank(alice);
        executor.openPositions(_one(ALICE), address(pool), _one(1_000e18), 0, block.timestamp);

        _open(ALICE, 1_000e18);
        vm.expectRevert(TradeExecutor.NotOperator.selector);
        vm.prank(alice);
        executor.closePositions(_one(ALICE), address(pool), _noPartner(1), 0, block.timestamp);
    }

    function test_instanceDoesNotTradeUntilTheOwnerSetsALimit() public {
        usdg.mint(multisig, FUNDS);
        vm.startPrank(multisig);
        uint256 fresh = nft.mint(address(0));
        executor.setMarketAllowed(fresh, address(pool), true);
        usdg.approve(address(executor), type(uint256).max);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.OverTradeLimit.selector, fresh, 1e18, 0));
        _open(fresh, 1e18);
    }

    function test_ownerLimitsAreEnforcedOnEntry() public {
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.OverTradeLimit.selector, ALICE, 10_001e18, 10_000e18));
        _open(ALICE, 10_001e18);

        vm.prank(alice);
        executor.setLimits(ALICE, 10_000e18, true);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InstancePaused.selector, ALICE));
        _open(ALICE, 1_000e18);

        vm.startPrank(alice);
        executor.setLimits(ALICE, 10_000e18, false);
        executor.setMarketAllowed(ALICE, address(pool), false);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.MarketNotAllowed.selector, ALICE, address(pool)));
        _open(ALICE, 1_000e18);
    }

    function test_onlyTheInstanceOwnerSetsItsLimits() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotInstanceOwner.selector, ALICE));
        executor.setLimits(ALICE, type(uint256).max, false);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotInstanceOwner.selector, ALICE));
        executor.setMarketAllowed(ALICE, address(pool), true);
        vm.stopPrank();
    }

    function test_openRejectsDisabledMarketDeadlineZeroAndDuplicate() public {
        vm.expectRevert(TradeExecutor.ZeroAmount.selector);
        _open(ALICE, 0);

        vm.expectRevert(TradeExecutor.Expired.selector);
        vm.prank(operator);
        executor.openPositions(_one(ALICE), address(pool), _one(1e18), 0, block.timestamp - 1);

        _open(ALICE, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.PositionExists.selector, ALICE, address(pool)));
        _open(ALICE, 1_000e18);

        vm.prank(multisig);
        executor.setMarket(address(pool), address(nvda), address(usdg), false, 600, 100);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.MarketDisabled.selector, address(pool)));
        _open(BOB, 1_000e18);
    }

    function test_minOutIsEnforced() public {
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InsufficientOutput.selector, 500e18, 501e18));
        vm.prank(operator);
        executor.openPositions(_one(ALICE), address(pool), _one(1_000e18), 501e18, block.timestamp);
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
        _close(ALICE, address(0));

        // Um preço MELHOR que a média nunca é barrado.
        _execPrice(2_500);
        _close(ALICE, address(0));
    }

    // ===== fechar e taxas =====

    function test_closeWithProfitChargesTheFeeAndReturnsTheRest() public {
        _open(ALICE, 1_000e18);
        _price(3, TICK_3);
        _close(ALICE, address(0));

        // Vendeu 500 a 3 = 1500. Lucro 500, taxa de 10% = 50.
        assertEq(usdg.balanceOf(alice), FUNDS - 1_000e18 + 1_450e18);
        assertEq(nvda.balanceOf(alice), 0);
        assertEq(executor.claimable(treasury, address(usdg)), 50e18);
        // O contrato guarda só a taxa.
        assertEq(usdg.balanceOf(address(executor)), 50e18);
        assertEq(nvda.balanceOf(address(executor)), 0);

        (uint256 base,) = executor.positions(ALICE, address(pool));
        assertEq(base, 0);
        assertFalse(executor.isLocked(ALICE));

        vm.prank(treasury);
        executor.withdraw(address(usdg));
        assertEq(usdg.balanceOf(treasury), 50e18);
        assertEq(usdg.balanceOf(address(executor)), 0);
    }

    function test_closeAtALossChargesNothing() public {
        _open(ALICE, 1_000e18);
        _price(1, TICK_1);
        _close(ALICE, address(0));

        assertEq(usdg.balanceOf(alice), FUNDS - 500e18);
        assertEq(executor.claimable(treasury, address(usdg)), 0);
        (int256 cumulative, int256 highWaterMark) = executor.pnl(ALICE, address(usdg));
        assertEq(cumulative, -500e18);
        assertEq(highWaterMark, 0);
    }

    function test_feeOnlyAppliesAboveTheHighWaterMark() public {
        address q = address(usdg);

        // +500: taxa sobre 500. Pico 500.
        _roundTrip(ALICE, 1_000e18, 3, TICK_3);
        assertEq(executor.claimable(treasury, q), 50e18);

        // -500: sem taxa. Acumulado 0.
        _roundTrip(ALICE, 1_000e18, 1, TICK_1);
        assertEq(executor.claimable(treasury, q), 50e18);

        // +300: acumulado 300, ainda abaixo do pico de 500. Sem taxa.
        _roundTrip(ALICE, 600e18, 3, TICK_3);
        assertEq(executor.claimable(treasury, q), 50e18);

        // +500: acumulado 800. Taxa só sobre os 300 que passaram do pico.
        _roundTrip(ALICE, 1_000e18, 3, TICK_3);
        assertEq(executor.claimable(treasury, q), 80e18);

        (int256 cumulative, int256 highWaterMark) = executor.pnl(ALICE, q);
        assertEq(cumulative, 800e18);
        assertEq(highWaterMark, 800e18);
    }

    function test_partnerGetsItsPointsOutOfTheProtocolFee() public {
        vm.prank(multisig);
        executor.setPartnerProfitShare(partner, 200);

        _open(ALICE, 1_000e18);
        _price(3, TICK_3);
        _close(ALICE, partner);

        // Lucro 500: usuário paga os mesmos 50; 10 vão ao parceiro, 40 a nós.
        assertEq(usdg.balanceOf(alice), FUNDS + 450e18);
        assertEq(executor.claimable(partner, address(usdg)), 10e18);
        assertEq(executor.claimable(treasury, address(usdg)), 40e18);
    }

    function test_unknownFeeRecipientGetsNothing() public {
        _open(ALICE, 1_000e18);
        _price(3, TICK_3);
        // O próprio usuário (ou uma operadora comprometida) como "parceiro".
        _close(ALICE, alice);

        assertEq(executor.claimable(alice, address(usdg)), 0);
        assertEq(executor.claimable(treasury, address(usdg)), 50e18);
    }

    function test_closingWorksWhilePausedAndWithTheMarketDisabled() public {
        _open(ALICE, 1_000e18);

        vm.prank(alice);
        executor.setLimits(ALICE, 0, true);
        vm.prank(multisig);
        executor.setMarket(address(pool), address(nvda), address(usdg), false, 600, 100);

        _close(ALICE, address(0));
        assertFalse(executor.isLocked(ALICE));
    }

    function test_closeWithoutPositionReverts() public {
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NoPosition.selector, ALICE, address(pool)));
        _close(ALICE, address(0));
    }

    // ===== copy trade =====

    function _follow(address user, uint256 tokenId, uint256 leader) internal {
        vm.prank(user);
        executor.follow(tokenId, leader);
    }

    function _batch() internal pure returns (uint256[] memory ids, uint256[] memory amounts) {
        ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (ALICE, BOB, CAROL);
        amounts = new uint256[](3);
        (amounts[0], amounts[1], amounts[2]) = (1_000e18, 3_000e18, 500e18);
    }

    function test_copyTradeEntersEveryoneAtTheSamePriceProRata() public {
        _follow(bob, BOB, ALICE);
        _follow(carol, CAROL, ALICE);
        (uint256[] memory ids, uint256[] memory amounts) = _batch();

        vm.prank(operator);
        executor.openPositions(ids, address(pool), amounts, 0, block.timestamp);

        // Um swap só, de 4500, a 2: cada um recebe a sua metade em ativo.
        assertEq(nvda.balanceOf(alice), 500e18);
        assertEq(nvda.balanceOf(bob), 1_500e18);
        assertEq(nvda.balanceOf(carol), 250e18);
        assertEq(nvda.balanceOf(address(executor)), 0);
        assertTrue(executor.isLocked(ALICE) && executor.isLocked(BOB) && executor.isLocked(CAROL));
    }

    function test_copyTradePaysTenPercentOfFollowerProfitToTheLeader() public {
        _follow(bob, BOB, ALICE);
        _follow(carol, CAROL, ALICE);
        (uint256[] memory ids, uint256[] memory amounts) = _batch();
        vm.prank(operator);
        executor.openPositions(ids, address(pool), amounts, 0, block.timestamp);

        _price(3, TICK_3);
        vm.prank(operator);
        executor.closePositions(ids, address(pool), _noPartner(3), 0, block.timestamp);

        address q = address(usdg);
        // Líder (alice): lucro 500, paga só os 10% do protocolo.
        assertEq(usdg.balanceOf(alice), FUNDS + 450e18);
        // Bob: lucro 1500 → 150 ao protocolo, 150 ao líder.
        assertEq(usdg.balanceOf(bob), FUNDS + 1_200e18);
        // Carol: lucro 250 → 25 e 25.
        assertEq(usdg.balanceOf(carol), FUNDS + 200e18);

        assertEq(executor.claimable(alice, q), 175e18);
        assertEq(executor.claimable(treasury, q), 50e18 + 150e18 + 25e18);
        // O contrato guarda exatamente o que ainda vai ser sacado.
        assertEq(usdg.balanceOf(address(executor)), 400e18);

        vm.prank(alice);
        executor.withdraw(q);
        assertEq(usdg.balanceOf(alice), FUNDS + 450e18 + 175e18);
    }

    function test_leaderFeeGoesToWhoeverOwnsTheLeaderNft() public {
        _follow(bob, BOB, ALICE);
        _open(BOB, 1_000e18);

        // Alice vende a instância líder para Carol enquanto Bob está posicionado.
        vm.prank(alice);
        nft.transferFrom(alice, carol, ALICE);

        _price(3, TICK_3);
        _close(BOB, address(0));

        assertEq(executor.claimable(carol, address(usdg)), 50e18);
        assertEq(executor.claimable(alice, address(usdg)), 0);
    }

    function test_leaderFeeIsLockedInWhenFollowingStarts() public {
        _follow(bob, BOB, ALICE);

        vm.prank(multisig);
        executor.setFees(1_000, 2_000);
        _follow(carol, CAROL, ALICE);

        (, uint16 bobFee) = executor.following(BOB);
        (, uint16 carolFee) = executor.following(CAROL);
        assertEq(bobFee, 1_000);
        assertEq(carolFee, 2_000);

        _open(BOB, 1_000e18);
        _price(3, TICK_3);
        _close(BOB, address(0));
        // Bob continua pagando os 10% de quando começou a seguir.
        assertEq(executor.claimable(alice, address(usdg)), 50e18);
    }

    function test_cannotChangeLeaderWithAnOpenPosition() public {
        _follow(bob, BOB, ALICE);
        _open(BOB, 1_000e18);

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.HasOpenPositions.selector, BOB));
        executor.unfollow(BOB);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.HasOpenPositions.selector, BOB));
        executor.follow(BOB, CAROL);
        vm.stopPrank();

        _close(BOB, address(0));
        vm.prank(bob);
        executor.unfollow(BOB);
        (uint256 leader,) = executor.following(BOB);
        assertEq(leader, 0);
    }

    function test_followRejectsSelfMissingLeaderAndStrangers() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InvalidLeader.selector, BOB));
        executor.follow(BOB, BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        executor.follow(BOB, 99);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotInstanceOwner.selector, CAROL));
        executor.follow(CAROL, ALICE);
        vm.stopPrank();
    }

    function test_batchRejectsMismatchedOrEmptyInput() public {
        (uint256[] memory ids,) = _batch();
        vm.startPrank(operator);

        vm.expectRevert(TradeExecutor.LengthMismatch.selector);
        executor.openPositions(ids, address(pool), _one(1e18), 0, block.timestamp);
        vm.expectRevert(TradeExecutor.EmptyBatch.selector);
        executor.openPositions(new uint256[](0), address(pool), new uint256[](0), 0, block.timestamp);
        vm.expectRevert(TradeExecutor.LengthMismatch.selector);
        executor.closePositions(ids, address(pool), _noPartner(1), 0, block.timestamp);

        vm.stopPrank();
    }

    function test_oneInstanceOverItsLimitRevertsTheWholeBatch() public {
        vm.prank(carol);
        executor.setLimits(CAROL, 100e18, false);
        (uint256[] memory ids, uint256[] memory amounts) = _batch();

        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.OverTradeLimit.selector, CAROL, 500e18, 100e18));
        vm.prank(operator);
        executor.openPositions(ids, address(pool), amounts, 0, block.timestamp);

        assertEq(usdg.balanceOf(alice), FUNDS);
    }

    function testFuzz_batchSplitsExactlyWhatTheSwapProduced(uint64 a, uint64 b, uint64 c, uint16 exitMilli) public {
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (ALICE, BOB, CAROL);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = bound(a, 1e6, 10_000e18);
        amounts[1] = bound(b, 1e6, 10_000e18);
        amounts[2] = bound(c, 1e6, 10_000e18);
        uint256 total = amounts[0] + amounts[1] + amounts[2];
        _follow(bob, BOB, ALICE);
        _follow(carol, CAROL, ALICE);

        vm.prank(operator);
        executor.openPositions(ids, address(pool), amounts, 0, block.timestamp);

        // Todo o ativo comprado foi para as carteiras, nada ficou no contrato.
        uint256 bought = nvda.balanceOf(alice) + nvda.balanceOf(bob) + nvda.balanceOf(carol);
        assertEq(bought, total / 2);
        assertEq(nvda.balanceOf(address(executor)), 0);

        // Fecha a um preço entre 1,99 e 2,01 (dentro da tolerância do TWAP).
        uint256 exit = bound(exitMilli, 1_990, 2_010);
        _execPrice(exit);
        vm.prank(operator);
        executor.closePositions(ids, address(pool), _noPartner(3), 0, block.timestamp);

        address q = address(usdg);
        uint256 fees = executor.claimable(treasury, q) + executor.claimable(alice, q);
        uint256 withUsers = usdg.balanceOf(alice) + usdg.balanceOf(bob) + usdg.balanceOf(carol);

        // O contrato guarda exatamente as taxas, e nada se perdeu no caminho.
        assertEq(usdg.balanceOf(address(executor)), fees);
        assertEq(withUsers + fees, 3 * FUNDS - total + (bought * exit) / 1000);
        assertEq(nvda.balanceOf(address(executor)), 0);
        assertEq(executor.openCount(ALICE) + executor.openCount(BOB) + executor.openCount(CAROL), 0);
    }

    // ===== abandonar posição =====

    function test_ownerCanAlwaysAbandonAndKeepsTheAsset() public {
        _open(ALICE, 1_000e18);

        vm.prank(alice);
        executor.abandonPosition(ALICE, address(pool));

        assertEq(nvda.balanceOf(alice), 500e18);
        assertFalse(executor.isLocked(ALICE));
        (int256 cumulative,) = executor.pnl(ALICE, address(usdg));
        assertEq(cumulative, 0);
    }

    function test_operatorCanOnlyAbandonWhatCannotBeClosed() public {
        _open(ALICE, 1_000e18);

        // Posição ainda fechável: a operadora não pode apagá-la.
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.PositionStillClosable.selector, ALICE, address(pool)));
        vm.prank(operator);
        executor.abandonPosition(ALICE, address(pool));

        // O dono move o ativo: o fechamento normal fica impossível…
        vm.prank(alice);
        nvda.transfer(bob, 500e18);
        vm.expectRevert();
        _close(ALICE, address(0));

        // …e aí a operadora pode limpar o registro.
        vm.prank(operator);
        executor.abandonPosition(ALICE, address(pool));
        assertFalse(executor.isLocked(ALICE));

        // Um terceiro não abandona a posição de ninguém.
        _open(BOB, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotInstanceOwner.selector, BOB));
        vm.prank(carol);
        executor.abandonPosition(BOB, address(pool));
    }

    // ===== integração com o NFT =====

    function test_instanceWithAnOpenPositionCannotBeTransferred() public {
        _open(ALICE, 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(BotInstanceNFT.InstanceLocked.selector, ALICE));
        vm.prank(alice);
        nft.transferFrom(alice, bob, ALICE);

        _close(ALICE, address(0));
        vm.prank(alice);
        nft.transferFrom(alice, bob, ALICE);
        assertEq(nft.ownerOf(ALICE), bob);
    }

    // ===== callback e saque =====

    function test_swapCallbackOnlyAnswersThePoolBeingSwapped() public {
        usdg.mint(address(executor), 1_000e18);

        vm.expectRevert(TradeExecutor.BadCallback.selector);
        vm.prank(alice);
        executor.uniswapV3SwapCallback(int256(1_000e18), 0, abi.encode(address(usdg)));

        // Nem o próprio pool, fora de um swap iniciado pelo executor.
        vm.expectRevert(TradeExecutor.BadCallback.selector);
        vm.prank(address(pool));
        executor.uniswapV3SwapCallback(int256(1_000e18), 0, abi.encode(address(usdg)));
    }

    function test_withdrawRevertsWithNothingToClaim() public {
        vm.expectRevert(TradeExecutor.NothingToWithdraw.selector);
        vm.prank(alice);
        executor.withdraw(address(usdg));
    }

    // ===== administração =====

    function test_onlyTheMultisigAdministers() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator);
        vm.startPrank(operator);

        vm.expectRevert(unauthorized);
        executor.setMarket(address(pool), address(nvda), address(usdg), true, 600, 100);
        vm.expectRevert(unauthorized);
        executor.setOperator(alice);
        vm.expectRevert(unauthorized);
        executor.setTreasury(operator);
        vm.expectRevert(unauthorized);
        executor.setFees(3_000, 0);
        vm.expectRevert(unauthorized);
        executor.setPartnerProfitShare(operator, 1_000);

        vm.stopPrank();
    }

    function test_marketMustMatchThePoolAndHaveSaneParameters() public {
        Token other = new Token("OTHER");
        vm.startPrank(multisig);

        vm.expectRevert(TradeExecutor.InvalidMarket.selector);
        executor.setMarket(address(pool), address(other), address(usdg), true, 600, 100);
        vm.expectRevert(TradeExecutor.InvalidMarket.selector);
        executor.setMarket(address(pool), address(nvda), address(usdg), true, 0, 100);
        vm.expectRevert(TradeExecutor.InvalidMarket.selector);
        executor.setMarket(address(pool), address(nvda), address(usdg), true, 600, 1_001);

        vm.stopPrank();
    }

    function test_feesAreCapped() public {
        vm.startPrank(multisig);

        vm.expectRevert(TradeExecutor.InvalidFees.selector);
        executor.setFees(2_000, 1_001);
        // A fatia do parceiro não pode passar da taxa do protocolo.
        vm.expectRevert(TradeExecutor.InvalidFees.selector);
        executor.setPartnerProfitShare(partner, 1_001);

        executor.setFees(2_000, 1_000);
        vm.stopPrank();
    }

    function test_rotatedOperatorLosesAccess() public {
        address newOperator = makeAddr("newOperator");
        vm.prank(multisig);
        executor.setOperator(newOperator);

        vm.expectRevert(TradeExecutor.NotOperator.selector);
        _open(ALICE, 1_000e18);

        vm.prank(newOperator);
        executor.openPositions(_one(ALICE), address(pool), _one(1_000e18), 0, block.timestamp);
    }
}
