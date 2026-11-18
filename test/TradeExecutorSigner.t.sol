// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BotInstanceNFT} from "../src/BotInstanceNFT.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {Token, MockWETH, MockAggregator} from "./Mocks.sol";

/// O assinante que o dono escolhe, além da operadora.
contract TradeExecutorSignerTest is Test {
    BotInstanceNFT nft;
    TradeExecutor executor;
    MockWETH weth;
    Token usdg;
    Token nvda;
    MockAggregator aggregator;

    address multisig = makeAddr("multisig");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address signer = makeAddr("signer");

    uint256 constant ALICE = 1;
    uint256 constant BOB = 2;
    uint256 constant FUNDS = 100_000e18;
    uint16 constant FEE = 50;
    bytes32 constant DECISION = keccak256("decision");

    address key;

    function setUp() public {
        nft = new BotInstanceNFT(multisig, treasury, 1_000, 0);
        weth = new MockWETH();
        executor = new TradeExecutor(multisig, IERC721(address(nft)), address(weth), operator, treasury, FEE);
        usdg = new Token("USDG");
        nvda = new Token("NVDA");
        aggregator = new MockAggregator();
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

    function _ids(uint256 a) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        list[0] = a;
        list[1] = b;
    }

    function _pair() internal view returns (TradeExecutor.Pair memory) {
        return TradeExecutor.Pair(address(nvda), address(usdg));
    }

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

    /// Compra a 2 de cotação por ativo, assinando como `caller` e pedindo a
    /// taxa `feeBps`; a rota é montada para a taxa `charged`.
    function _open(address caller, uint256[] memory ids, uint256 quoteIn, uint16 feeBps, uint16 charged) internal {
        uint256[] memory quoteIns = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            quoteIns[i] = quoteIn;
        }
        uint256 net = ids.length * (quoteIn - (quoteIn * charged) / 10_000);
        vm.prank(caller);
        executor.openViaAggregator(
            ids, _pair(), quoteIns, 0, feeBps, block.timestamp, DECISION, _route(usdg, nvda, net, net / 2)
        );
    }

    function _close(address caller, uint256 tokenId, uint256 quoteOut, uint16 feeBps) internal {
        (uint256 base,) = executor.positions(tokenId, key);
        vm.prank(caller);
        executor.closeViaAggregator(
            _ids(tokenId), _pair(), 0, feeBps, block.timestamp, DECISION, _route(nvda, usdg, base, quoteOut)
        );
    }

    function _delegate() internal {
        vm.prank(alice);
        executor.setSigner(ALICE, signer);
    }

    // ===== delegar =====

    function test_ownerChoosesASignerAndCanRevokeIt() public {
        assertEq(executor.signerOf(ALICE), address(0));

        vm.expectEmit(address(executor));
        emit TradeExecutor.SignerSet(ALICE, alice, signer);
        _delegate();
        assertEq(executor.signerOf(ALICE), signer);

        vm.prank(alice);
        executor.setSigner(ALICE, address(0));
        assertEq(executor.signerOf(ALICE), address(0));
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotSigner.selector, ALICE));
        _open(signer, _ids(ALICE), 1_000e18, FEE, FEE);
    }

    function test_onlyTheOwnerChoosesTheSigner() public {
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotInstanceOwner.selector, ALICE));
        vm.prank(signer);
        executor.setSigner(ALICE, signer);

        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotInstanceOwner.selector, ALICE));
        vm.prank(operator);
        executor.setSigner(ALICE, operator);
    }

    function test_aBuyerOfTheNftDoesNotInheritTheSigner() public {
        _delegate();
        vm.prank(alice);
        nft.transferFrom(alice, bob, ALICE);

        assertEq(executor.signerOf(ALICE), address(0));
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotSigner.selector, ALICE));
        _open(signer, _ids(ALICE), 1_000e18, FEE, FEE);

        // Nem se a NFT voltar para quem delegou: a delegação é de quem era dono.
        vm.prank(bob);
        nft.transferFrom(bob, alice, ALICE);
        assertEq(executor.signerOf(ALICE), signer);
    }

    // ===== operar =====

    function test_theSignerOpensAndClosesWithEverythingStayingInTheVault() public {
        _delegate();
        _open(signer, _ids(ALICE), 1_000e18, FEE, FEE);
        address vault = executor.vaultOf(ALICE);
        assertEq(nvda.balanceOf(vault), 497.5e18);

        _close(signer, ALICE, 1_500e18, FEE);
        assertEq(nvda.balanceOf(vault), 0);
        assertEq(usdg.balanceOf(vault), FUNDS - 1_000e18 + 1_492.5e18);
        assertEq(usdg.balanceOf(signer), 0);
        assertEq(nvda.balanceOf(signer), 0);
    }

    function test_theSignerAlwaysPaysTheFullFee() public {
        _delegate();
        // Pede taxa zero; o contrato cobra a cheia.
        _open(signer, _ids(ALICE), 1_000e18, 0, FEE);
        assertEq(executor.claimable(treasury, address(usdg)), 5e18);

        _close(signer, ALICE, 1_500e18, 0);
        assertEq(executor.claimable(treasury, address(usdg)), 12.5e18);
    }

    function test_theOperatorStillChoosesTheFeeAndKeepsAccess() public {
        _delegate();
        _open(operator, _ids(ALICE), 1_000e18, 0, 0);
        assertEq(executor.claimable(treasury, address(usdg)), 0);
        _close(operator, ALICE, 1_500e18, 0);
        assertEq(executor.claimable(treasury, address(usdg)), 0);
    }

    function test_anExemptInstanceStaysExemptWithASigner() public {
        vm.prank(operator);
        executor.setFeeExempt(ALICE, true);
        _delegate();
        _open(signer, _ids(ALICE), 1_000e18, FEE, 0);
        assertEq(executor.claimable(treasury, address(usdg)), 0);
    }

    function test_theSignerReachesOnlyTheInstancesThatChoseIt() public {
        _delegate();
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotSigner.selector, BOB));
        _open(signer, _ids(BOB), 1_000e18, FEE, FEE);

        // Num lote, basta uma instância que não o escolheu.
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotSigner.selector, BOB));
        _open(signer, _ids(ALICE, BOB), 1_000e18, FEE, FEE);
    }

    function test_theSignerIsHeldToTheOwnerLimits() public {
        _delegate();
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.OverTradeLimit.selector, ALICE, 20_000e18, 10_000e18));
        _open(signer, _ids(ALICE), 20_000e18, FEE, FEE);

        vm.prank(alice);
        executor.setLimits(ALICE, 10_000e18, true, false);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.InstancePaused.selector, ALICE));
        _open(signer, _ids(ALICE), 1_000e18, FEE, FEE);
    }

    function test_theSignerCannotDropPositions() public {
        _delegate();
        _open(signer, _ids(ALICE), 1_000e18, FEE, FEE);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotInstanceOwner.selector, ALICE));
        vm.prank(signer);
        executor.dropPosition(ALICE, key);
    }

    function test_theSignerWrapsTheEthInTheVault() public {
        _delegate();
        address vault = executor.vaultOf(ALICE);
        vm.deal(vault, 1 ether);

        vm.prank(signer);
        executor.wrapNative(ALICE);
        assertEq(IERC20(address(weth)).balanceOf(vault), 1 ether);

        vm.deal(executor.vaultOf(BOB), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(TradeExecutor.NotSigner.selector, BOB));
        vm.prank(signer);
        executor.wrapNative(BOB);
    }
}
