// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BotInstanceNFT, ITransferGuard} from "../src/BotInstanceNFT.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Dollar", "MUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Token que queima 1% em cada transferência.
contract FeeToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract MockGuard is ITransferGuard {
    mapping(uint256 => bool) public locked;

    function setLocked(uint256 tokenId, bool value) external {
        locked[tokenId] = value;
    }

    function isLocked(uint256 tokenId) external view returns (bool) {
        return locked[tokenId];
    }
}

/// Recusa receber ETH.
contract Rejector {}

/// Ao receber o troco do mint, tenta mintar de novo dentro da mesma chamada.
contract ReentrantMinter {
    BotInstanceNFT public immutable nft;
    bool private attacking;

    constructor(BotInstanceNFT nft_) {
        nft = nft_;
    }

    function attack() external payable {
        attacking = true;
        nft.mint{value: msg.value}(address(0));
    }

    receive() external payable {
        if (attacking) {
            attacking = false;
            nft.mint{value: 1 ether}(address(0));
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract BotInstanceNFTTest is Test {
    BotInstanceNFT nft;
    MockToken usd;

    address owner = makeAddr("multisig");
    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address partner = makeAddr("partner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    address constant ETH = address(0);
    uint256 constant PRICE = 0.08 ether;
    uint256 constant CAP = 200;

    event Minted(
        uint256 indexed tokenId, address indexed owner, address indexed feeRecipient, address token, uint256 price
    );
    event ToppedUp(
        uint256 indexed tokenId, address indexed payer, address indexed feeRecipient, address token, uint256 amount
    );

    function setUp() public {
        nft = new BotInstanceNFT(owner, treasury, CAP, PRICE);
        usd = new MockToken();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ===== mint =====

    function test_mintAssignsSequentialIdsAndEmitsAttribution() public {
        vm.expectEmit();
        emit Minted(1, alice, partner, ETH, PRICE);
        vm.prank(alice);
        uint256 first = nft.mint{value: PRICE}(partner);

        vm.prank(bob);
        uint256 second = nft.mint{value: PRICE}(address(0));

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), bob);
        assertEq(nft.totalMinted(), 2);
    }

    function test_mintRevenueAccruesToTreasuryUntilWithdrawn() public {
        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));

        assertEq(nft.claimable(treasury, ETH), PRICE);
        assertEq(treasury.balance, 0);
        assertEq(address(nft).balance, PRICE);

        vm.prank(treasury);
        nft.withdraw(ETH);

        assertEq(treasury.balance, PRICE);
        assertEq(nft.claimable(treasury, ETH), 0);
        assertEq(address(nft).balance, 0);
    }

    function test_mintRefundsWhatExceedsThePrice() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        nft.mint{value: PRICE + 1 ether}(address(0));

        assertEq(alice.balance, before - PRICE);
        assertEq(address(nft).balance, PRICE);
    }

    function test_mintRevertsWhenUnderpaid() public {
        vm.expectRevert(abi.encodeWithSelector(BotInstanceNFT.WrongPayment.selector, PRICE, PRICE - 1));
        vm.prank(alice);
        nft.mint{value: PRICE - 1}(address(0));
    }

    function test_mintStopsAtTheCapAndResumesWhenTheCapIsRaised() public {
        vm.prank(owner);
        nft.setPaymentToken(ETH, true, 0);
        for (uint256 i = 0; i < CAP; i++) {
            vm.prank(alice);
            nft.mint(address(0));
        }
        assertEq(nft.totalMinted(), CAP);

        vm.expectRevert(BotInstanceNFT.SoldOut.selector);
        vm.prank(alice);
        nft.mint(address(0));

        // Nova rodada: teto maior e preço novo.
        vm.startPrank(owner);
        nft.setMaxSupply(CAP + 100);
        nft.setPaymentToken(ETH, true, 0.2 ether);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(BotInstanceNFT.WrongPayment.selector, 0.2 ether, PRICE));
        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));

        vm.prank(alice);
        assertEq(nft.mint{value: 0.2 ether}(address(0)), CAP + 1);
    }

    function test_maxSupplyOnlyGoesUp() public {
        vm.expectRevert(abi.encodeWithSelector(BotInstanceNFT.MaxSupplyCannotDecrease.selector, CAP, CAP - 1));
        vm.prank(owner);
        nft.setMaxSupply(CAP - 1);
    }

    function test_mintCanBePausedByUnacceptingEth() public {
        vm.prank(owner);
        nft.setPaymentToken(ETH, false, PRICE);

        vm.expectRevert(abi.encodeWithSelector(BotInstanceNFT.TokenNotAccepted.selector, ETH));
        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));
    }

    function test_reentrantMintThroughTheRefundIsBlocked() public {
        ReentrantMinter attacker = new ReentrantMinter(nft);
        vm.deal(address(attacker), 10 ether);

        // O troco dispara a reentrada; a trava derruba a chamada interna, o
        // envio do troco falha e a transação inteira reverte.
        vm.expectRevert(BotInstanceNFT.EthTransferFailed.selector);
        attacker.attack{value: PRICE + 2 ether}();
        assertEq(nft.totalMinted(), 0);
    }

    // ===== tokens de pagamento =====

    function test_mintWithAnAcceptedToken() public {
        vm.prank(owner);
        nft.setPaymentToken(address(usd), true, 200e18);
        usd.mint(alice, 200e18);

        vm.startPrank(alice);
        usd.approve(address(nft), 200e18);
        uint256 tokenId = nft.mintWithToken(address(usd), address(0));
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), alice);
        assertEq(nft.claimable(treasury, address(usd)), 200e18);

        vm.prank(treasury);
        nft.withdraw(address(usd));
        assertEq(usd.balanceOf(treasury), 200e18);
    }

    function test_unacceptedTokenIsRefusedForMintAndTopUp() public {
        usd.mint(alice, 1000e18);
        vm.startPrank(alice);
        usd.approve(address(nft), type(uint256).max);
        nft.mint{value: PRICE}(address(0));

        vm.expectRevert(abi.encodeWithSelector(BotInstanceNFT.TokenNotAccepted.selector, address(usd)));
        nft.mintWithToken(address(usd), address(0));

        vm.expectRevert(abi.encodeWithSelector(BotInstanceNFT.TokenNotAccepted.selector, address(usd)));
        nft.topUpWithToken(1, address(usd), 10e18, address(0));

        // ETH não entra pelo caminho de token.
        vm.expectRevert(abi.encodeWithSelector(BotInstanceNFT.TokenNotAccepted.selector, ETH));
        nft.mintWithToken(ETH, address(0));
        vm.stopPrank();
    }

    function test_feeOnTransferTokenCreditsWhatActuallyArrived() public {
        FeeToken fee = new FeeToken();
        vm.prank(owner);
        nft.setPaymentToken(address(fee), true, 0);
        fee.mint(alice, 100e18);

        vm.startPrank(alice);
        nft.mint{value: PRICE}(address(0));
        fee.approve(address(nft), 100e18);

        // Pede 100, chegam 99: é o que o evento e o saldo registram.
        vm.expectEmit();
        emit ToppedUp(1, alice, address(0), address(fee), 99e18);
        nft.topUpWithToken(1, address(fee), 100e18, address(0));
        vm.stopPrank();

        assertEq(nft.claimable(treasury, address(fee)), 99e18);
        assertEq(fee.balanceOf(address(nft)), 99e18);
    }

    // ===== recarga =====

    function test_topUpEmitsWhatTheBackendCreditsAndAnyoneCanPay() public {
        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));

        vm.expectEmit();
        emit ToppedUp(1, bob, partner, ETH, 0.01 ether);
        vm.prank(bob);
        nft.topUp{value: 0.01 ether}(1, partner);

        assertEq(nft.claimable(treasury, ETH), PRICE + 0.01 ether);
    }

    function test_topUpRejectsZeroAndUnknownInstance() public {
        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));

        vm.expectRevert(BotInstanceNFT.ZeroAmount.selector);
        vm.prank(alice);
        nft.topUp(1, address(0));

        vm.expectRevert(abi.encodeWithSelector(BotInstanceNFT.UnknownInstance.selector, 2));
        vm.prank(alice);
        nft.topUp{value: 1 ether}(2, address(0));
    }

    // ===== parceiro =====

    function test_partnerShareIsPaidOnlyToAllowlistedAddresses() public {
        // Sem fatia configurada, o endereço passado não recebe nada.
        vm.prank(alice);
        nft.mint{value: PRICE}(alice);
        assertEq(nft.claimable(alice, ETH), 0);
        assertEq(nft.claimable(treasury, ETH), PRICE);

        // Parceiro com 10% do mint e 20% das recargas.
        vm.prank(owner);
        nft.setPartnerShares(partner, 1_000, 2_000);

        vm.prank(bob);
        nft.mint{value: PRICE}(partner);
        assertEq(nft.claimable(partner, ETH), PRICE / 10);

        vm.prank(bob);
        nft.topUp{value: 1 ether}(2, partner);
        assertEq(nft.claimable(partner, ETH), PRICE / 10 + 0.2 ether);

        uint256 before = partner.balance;
        vm.prank(partner);
        nft.withdraw(ETH);
        assertEq(partner.balance, before + PRICE / 10 + 0.2 ether);
    }

    function test_partnerShareIsCapped() public {
        vm.expectRevert(abi.encodeWithSelector(BotInstanceNFT.ShareTooHigh.selector, 5_001));
        vm.prank(owner);
        nft.setPartnerShares(partner, 5_001, 0);
    }

    function testFuzz_paymentIsSplitWithoutLosingOrCreatingWei(uint96 amount, uint16 shareBps, uint96 floatTarget)
        public
    {
        amount = uint96(bound(amount, 1, 50 ether));
        shareBps = uint16(bound(shareBps, 0, 5_000));

        vm.startPrank(owner);
        nft.setPaymentToken(ETH, true, 0);
        nft.setPartnerShares(partner, 0, shareBps);
        nft.setOperator(operator, floatTarget);
        vm.stopPrank();

        vm.startPrank(alice);
        nft.mint(address(0));
        nft.topUp{value: amount}(1, partner);
        vm.stopPrank();

        uint256 toPartner = nft.claimable(partner, ETH);
        uint256 toTreasury = nft.claimable(treasury, ETH);

        assertEq(toPartner + toTreasury + operator.balance, amount);
        assertEq(toPartner, (uint256(amount) * shareBps) / 10_000);
        assertLe(operator.balance, floatTarget);
        // O contrato guarda exatamente o que ainda pode ser sacado.
        assertEq(address(nft).balance, toPartner + toTreasury);
    }

    // ===== caixa de gas =====

    function test_gasFloatIsToppedUpToTheTargetAndNoFurther() public {
        vm.prank(owner);
        nft.setOperator(operator, 0.1 ether);

        // Primeiro mint (0,08): vai todo para a operadora.
        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));
        assertEq(operator.balance, PRICE);
        assertEq(nft.claimable(treasury, ETH), 0);

        // Segundo: completa os 0,02 que faltam; o resto é da tesouraria.
        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));
        assertEq(operator.balance, 0.1 ether);
        assertEq(nft.claimable(treasury, ETH), PRICE - 0.02 ether);

        // Caixa cheio: nada mais vai para a operadora.
        vm.prank(alice);
        nft.topUp{value: 1 ether}(1, address(0));
        assertEq(operator.balance, 0.1 ether);
    }

    function test_refillComesOutOfTheProtocolPartNotThePartners() public {
        vm.startPrank(owner);
        nft.setOperator(operator, 10 ether);
        nft.setPartnerShares(partner, 0, 2_000);
        vm.stopPrank();
        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));

        vm.prank(alice);
        nft.topUp{value: 1 ether}(1, partner);

        assertEq(nft.claimable(partner, ETH), 0.2 ether);
        assertEq(operator.balance, PRICE + 0.8 ether);
    }

    function test_operatorThatRejectsEthDoesNotBlockMint() public {
        Rejector rejector = new Rejector();
        vm.prank(owner);
        nft.setOperator(address(rejector), 1 ether);

        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));

        assertEq(nft.ownerOf(1), alice);
        assertEq(address(rejector).balance, 0);
        assertEq(nft.claimable(treasury, ETH), PRICE);
    }

    // ===== saque =====

    function test_withdrawRevertsWithNothingToClaim() public {
        vm.expectRevert(BotInstanceNFT.NothingToWithdraw.selector);
        vm.prank(alice);
        nft.withdraw(ETH);
    }

    function test_oldTreasuryKeepsWhatItAlreadyEarned() public {
        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));

        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        nft.setTreasury(newTreasury);

        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));

        assertEq(nft.claimable(treasury, ETH), PRICE);
        assertEq(nft.claimable(newTreasury, ETH), PRICE);
    }

    // ===== administração =====

    function test_onlyTheOwnerAdministers() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);

        vm.expectRevert(unauthorized);
        nft.setPaymentToken(ETH, true, 0);
        vm.expectRevert(unauthorized);
        nft.setMaxSupply(1_000);
        vm.expectRevert(unauthorized);
        nft.setTreasury(alice);
        vm.expectRevert(unauthorized);
        nft.setOperator(alice, 100 ether);
        vm.expectRevert(unauthorized);
        nft.setPartnerShares(alice, 5_000, 5_000);
        vm.expectRevert(unauthorized);
        nft.setTransferGuard(ITransferGuard(alice));

        vm.stopPrank();
    }

    function test_ownershipTransferNeedsAcceptance() public {
        vm.prank(owner);
        nft.transferOwnership(alice);
        assertEq(nft.owner(), owner);

        vm.prank(alice);
        nft.acceptOwnership();
        assertEq(nft.owner(), alice);
    }

    // ===== trava de transferência =====

    function test_lockedInstanceCannotBeTransferredButCanStillBeToppedUp() public {
        MockGuard guard = new MockGuard();
        vm.prank(owner);
        nft.setTransferGuard(guard);

        // O mint não consulta a trava.
        guard.setLocked(1, true);
        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));

        vm.expectRevert(abi.encodeWithSelector(BotInstanceNFT.InstanceLocked.selector, 1));
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        vm.prank(bob);
        nft.topUp{value: 0.01 ether}(1, address(0));

        guard.setLocked(1, false);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
    }
}
