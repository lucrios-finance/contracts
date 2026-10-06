// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Consultado antes de cada transferência de NFT. Implementado pelo contrato
/// de execução: uma instância com posição aberta não muda de dono, porque os
/// allowances que sustentam a posição são da carteira antiga.
interface ITransferGuard {
    function isLocked(uint256 tokenId) external view returns (bool);
}

/// Cada NFT é uma instância do bot. Este contrato vende as instâncias (mint,
/// em rodadas) e recebe as recargas de crédito. Não guarda saldo de crédito:
/// só encaminha o pagamento e emite o evento que o backend contabiliza.
///
/// Toda receita fica acumulada aqui até ser sacada por quem tem direito
/// (tesouraria ou parceiro) — nenhum pagamento depende de um terceiro aceitar
/// uma transferência.
contract BotInstanceNFT is ERC721, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// `address(0)` representa ETH nos mapas e eventos de pagamento.
    address public constant ETH = address(0);
    uint256 public constant BPS = 10_000;
    /// Teto da fatia de um parceiro em mint ou recarga.
    uint256 public constant MAX_PARTNER_SHARE_BPS = 5_000;

    struct PaymentToken {
        bool accepted;
        /// Preço de um mint neste token.
        uint256 mintPrice;
    }

    uint256 public totalMinted;
    /// Teto de instâncias da rodada vigente. Só sobe.
    uint256 public maxSupply;
    mapping(address token => PaymentToken) public paymentTokens;

    /// Quem recebe a parte do protocolo.
    address public treasury;
    /// Carteira que executa os trades. Recebe ETH de mint e recarga até o
    /// saldo dela chegar em `gasFloatTarget`.
    address public operator;
    uint256 public gasFloatTarget;

    /// Fatia de cada parceiro, definida por nós. Endereço fora dos mapas não
    /// recebe nada: é o que impede um usuário de passar a própria carteira
    /// como parceiro e ficar com parte da receita.
    mapping(address partner => uint256) public partnerMintShareBps;
    mapping(address partner => uint256) public partnerTopUpShareBps;

    /// Receita acumulada e ainda não sacada, por beneficiário e por token.
    mapping(address account => mapping(address token => uint256)) public claimable;

    ITransferGuard public transferGuard;

    event Minted(
        uint256 indexed tokenId, address indexed owner, address indexed feeRecipient, address token, uint256 price
    );
    event ToppedUp(
        uint256 indexed tokenId, address indexed payer, address indexed feeRecipient, address token, uint256 amount
    );
    event Withdrawn(address indexed account, address indexed token, uint256 amount);
    event GasFloatRefilled(address indexed operator, uint256 amount);
    event PaymentTokenSet(address indexed token, bool accepted, uint256 mintPrice);
    event MaxSupplySet(uint256 maxSupply);
    event TreasurySet(address treasury);
    event OperatorSet(address operator, uint256 gasFloatTarget);
    event PartnerSharesSet(address indexed partner, uint256 mintShareBps, uint256 topUpShareBps);
    event TransferGuardSet(address guard);

    error SoldOut();
    error TokenNotAccepted(address token);
    error WrongPayment(uint256 expected, uint256 sent);
    error ZeroAmount();
    error ZeroAddress();
    error UnknownInstance(uint256 tokenId);
    error MaxSupplyCannotDecrease(uint256 current, uint256 requested);
    error ShareTooHigh(uint256 bps);
    error NothingToWithdraw();
    error EthTransferFailed();
    error InstanceLocked(uint256 tokenId);

    constructor(address initialOwner, address treasury_, uint256 maxSupply_, uint256 ethMintPrice)
        ERC721("Lucrios Bot", "LUCRIOS")
        Ownable(initialOwner)
    {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        maxSupply = maxSupply_;
        paymentTokens[ETH] = PaymentToken({accepted: true, mintPrice: ethMintPrice});

        emit TreasurySet(treasury_);
        emit MaxSupplySet(maxSupply_);
        emit PaymentTokenSet(ETH, true, ethMintPrice);
    }

    // ===== mint =====

    /// Minta uma instância pagando em ETH. O que passar do preço volta para
    /// quem pagou: se o preço cair entre montar e incluir a transação, o
    /// usuário não perde a diferença.
    ///
    /// `feeRecipient` é opcional (`address(0)` = sem parceiro). Vai no evento
    /// para o backend saber por qual parceiro a instância entrou, e recebe a
    /// fatia de mint que estiver configurada para ele.
    function mint(address feeRecipient) external payable nonReentrant returns (uint256 tokenId) {
        PaymentToken memory payment = paymentTokens[ETH];
        if (!payment.accepted) revert TokenNotAccepted(ETH);
        if (msg.value < payment.mintPrice) revert WrongPayment(payment.mintPrice, msg.value);

        tokenId = _mintInstance(msg.sender, feeRecipient, ETH, payment.mintPrice);
        _distribute(ETH, payment.mintPrice, feeRecipient, partnerMintShareBps[feeRecipient]);

        uint256 excess = msg.value - payment.mintPrice;
        if (excess > 0) _sendEth(msg.sender, excess);
    }

    /// Minta pagando num token aceito. Exige `approve` do preço para este
    /// contrato.
    function mintWithToken(address token, address feeRecipient) external nonReentrant returns (uint256 tokenId) {
        if (token == ETH) revert TokenNotAccepted(ETH);
        PaymentToken memory payment = paymentTokens[token];
        if (!payment.accepted) revert TokenNotAccepted(token);

        tokenId = _mintInstance(msg.sender, feeRecipient, token, payment.mintPrice);
        uint256 received = _pull(token, payment.mintPrice);
        _distribute(token, received, feeRecipient, partnerMintShareBps[feeRecipient]);
    }

    function _mintInstance(address to, address feeRecipient, address token, uint256 price)
        private
        returns (uint256 tokenId)
    {
        if (totalMinted >= maxSupply) revert SoldOut();
        tokenId = ++totalMinted;
        _mint(to, tokenId);
        emit Minted(tokenId, to, feeRecipient, token, price);
    }

    // ===== recarga de créditos =====

    /// Recarrega os créditos de uma instância em ETH. Qualquer carteira pode
    /// recarregar qualquer instância.
    function topUp(uint256 tokenId, address feeRecipient) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        if (_ownerOf(tokenId) == address(0)) revert UnknownInstance(tokenId);

        emit ToppedUp(tokenId, msg.sender, feeRecipient, ETH, msg.value);
        _distribute(ETH, msg.value, feeRecipient, partnerTopUpShareBps[feeRecipient]);
    }

    /// Recarrega num token aceito. O evento registra o valor efetivamente
    /// recebido, que é o que o backend credita.
    function topUpWithToken(uint256 tokenId, address token, uint256 amount, address feeRecipient)
        external
        nonReentrant
    {
        if (token == ETH || !paymentTokens[token].accepted) revert TokenNotAccepted(token);
        if (amount == 0) revert ZeroAmount();
        if (_ownerOf(tokenId) == address(0)) revert UnknownInstance(tokenId);

        uint256 received = _pull(token, amount);
        emit ToppedUp(tokenId, msg.sender, feeRecipient, token, received);
        _distribute(token, received, feeRecipient, partnerTopUpShareBps[feeRecipient]);
    }

    // ===== distribuição e saque =====

    /// Divide um pagamento: fatia do parceiro, reabastecimento do caixa de gas
    /// (só em ETH) e o resto para a tesouraria. Tudo vira saldo sacável, menos
    /// o reabastecimento, que vai direto para a operadora.
    function _distribute(address token, uint256 amount, address feeRecipient, uint256 shareBps) private {
        uint256 partnerPart = feeRecipient == address(0) ? 0 : (amount * shareBps) / BPS;
        if (partnerPart > 0) claimable[feeRecipient][token] += partnerPart;

        uint256 protocolPart = amount - partnerPart;
        if (token == ETH) protocolPart -= _refillGasFloat(protocolPart);
        if (protocolPart > 0) claimable[treasury][token] += protocolPart;
    }

    /// Completa o saldo da operadora até o alvo, usando no máximo `available`.
    /// Se o envio falhar, nada é reabastecido e o valor segue para a
    /// tesouraria: um problema na operadora não pode impedir um mint.
    function _refillGasFloat(uint256 available) private returns (uint256 sent) {
        address operator_ = operator;
        if (operator_ == address(0)) return 0;

        uint256 balance = operator_.balance;
        if (balance >= gasFloatTarget) return 0;

        sent = gasFloatTarget - balance;
        if (sent > available) sent = available;
        if (sent == 0) return 0;

        (bool ok,) = operator_.call{value: sent}("");
        if (!ok) return 0;
        emit GasFloatRefilled(operator_, sent);
    }

    /// Saca o saldo acumulado de quem chama, no token indicado
    /// (`address(0)` = ETH). Quem saca paga o gas.
    function withdraw(address token) external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();
        claimable[msg.sender][token] = 0;

        if (token == ETH) _sendEth(msg.sender, amount);
        else IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, token, amount);
    }

    /// Puxa `amount` de quem chama e devolve o que de fato chegou (tokens com
    /// taxa na transferência entregam menos do que o pedido).
    function _pull(address token, uint256 amount) private returns (uint256 received) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    // ===== administração (multisig) =====

    /// Define se um token é aceito e o preço de mint nele. Uma rodada nova de
    /// mint é uma chamada desta função mais `setMaxSupply`.
    function setPaymentToken(address token, bool accepted, uint256 mintPrice) external onlyOwner {
        paymentTokens[token] = PaymentToken({accepted: accepted, mintPrice: mintPrice});
        emit PaymentTokenSet(token, accepted, mintPrice);
    }

    function setMaxSupply(uint256 newMaxSupply) external onlyOwner {
        if (newMaxSupply < maxSupply) revert MaxSupplyCannotDecrease(maxSupply, newMaxSupply);
        maxSupply = newMaxSupply;
        emit MaxSupplySet(newMaxSupply);
    }

    /// Troca a tesouraria. O saldo já acumulado continua da tesouraria
    /// antiga, que o saca normalmente.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    /// `address(0)` como operadora desliga o reabastecimento.
    function setOperator(address newOperator, uint256 newGasFloatTarget) external onlyOwner {
        operator = newOperator;
        gasFloatTarget = newGasFloatTarget;
        emit OperatorSet(newOperator, newGasFloatTarget);
    }

    function setPartnerShares(address partner, uint256 mintShareBps, uint256 topUpShareBps) external onlyOwner {
        if (partner == address(0)) revert ZeroAddress();
        if (mintShareBps > MAX_PARTNER_SHARE_BPS) revert ShareTooHigh(mintShareBps);
        if (topUpShareBps > MAX_PARTNER_SHARE_BPS) revert ShareTooHigh(topUpShareBps);
        partnerMintShareBps[partner] = mintShareBps;
        partnerTopUpShareBps[partner] = topUpShareBps;
        emit PartnerSharesSet(partner, mintShareBps, topUpShareBps);
    }

    function setTransferGuard(ITransferGuard guard) external onlyOwner {
        transferGuard = guard;
        emit TransferGuardSet(address(guard));
    }

    // ===== transferência =====

    /// Mint e burn passam direto; transferência entre carteiras consulta a
    /// trava do contrato de execução.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) {
            ITransferGuard guard = transferGuard;
            if (address(guard) != address(0) && guard.isLocked(tokenId)) revert InstanceLocked(tokenId);
        }
    }
}
