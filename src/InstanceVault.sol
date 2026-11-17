// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// O cofre de uma instância: guarda tudo o que é dela (o token de cotação, os
/// ativos comprados e os NFTs de faixa de liquidez) separado de qualquer outra
/// instância e do protocolo.
///
/// Um cofre por NFT, criado pelo `TradeExecutor` num endereço determinístico
/// (dá para depositar antes de ele existir). Quem manda nele são duas partes,
/// cada uma com um poder só:
///  - o executor move fundos, mas só pelas funções do executor, que limitam o
///    que a operadora pode fazer e mandam o resultado de volta para cá;
///  - o dono atual do NFT saca o que quiser, quando quiser, para a própria
///    carteira. Nenhuma trava do executor alcança o saque.
///
/// Transferir o NFT transfere o cofre: o novo dono passa a sacar.
///
/// Não é atualizável e o executor dele não muda. Versão nova do executor =
/// cofres novos, e o dono move os fundos sacando daqui.
contract InstanceVault is IERC721Receiver {
    using SafeERC20 for IERC20;

    address public executor;
    IERC721 public nft;
    uint256 public tokenId;

    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event NativeWithdrawn(address indexed to, uint256 amount);
    event NftWithdrawn(address indexed collection, uint256 indexed id, address indexed to);

    error AlreadyInitialized();
    error NotExecutor();
    error NotInstanceOwner();

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    modifier onlyInstanceOwner() {
        if (msg.sender != nft.ownerOf(tokenId)) revert NotInstanceOwner();
        _;
    }

    /// Chamado uma vez, pelo executor, na mesma transação que cria o clone.
    function initialize(IERC721 nft_, uint256 tokenId_) external {
        if (executor != address(0)) revert AlreadyInitialized();
        executor = msg.sender;
        nft = nft_;
        tokenId = tokenId_;
    }

    // ===== dono do NFT =====

    /// Saca `amount` de `token` para o dono. `type(uint256).max` = tudo.
    function withdraw(address token, uint256 amount) external onlyInstanceOwner {
        if (amount == type(uint256).max) amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(token, msg.sender, amount);
    }

    /// Saca ETH. `type(uint256).max` = tudo.
    function withdrawNative(uint256 amount) external onlyInstanceOwner {
        if (amount == type(uint256).max) amount = address(this).balance;
        Address.sendValue(payable(msg.sender), amount);
        emit NativeWithdrawn(msg.sender, amount);
    }

    /// Saca um NFT (uma faixa de liquidez, por exemplo). Depois disso o
    /// executor não consegue mais fechar a faixa; quem cuida é o dono.
    function withdrawNft(address collection, uint256 id) external onlyInstanceOwner {
        // `transferFrom`, não `safeTransferFrom`: quem chama é o próprio
        // destino, e um contrato sem `onERC721Received` não pode ficar sem
        // conseguir sacar.
        IERC721(collection).transferFrom(address(this), msg.sender, id);
        emit NftWithdrawn(collection, id, msg.sender);
    }

    // ===== executor =====

    function transferOut(address token, address to, uint256 amount) external onlyExecutor {
        IERC20(token).safeTransfer(to, amount);
    }

    /// Uma chamada em nome do cofre. O executor só a usa com calldata montado
    /// por ele mesmo: embrulhar ETH e fechar faixas de liquidez, que exigem o
    /// dono do NFT da faixa como remetente.
    function execute(address target, uint256 value, bytes calldata data) external onlyExecutor returns (bytes memory) {
        return Address.functionCallWithValue(target, data, value);
    }

    // ===== recebimento =====

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
