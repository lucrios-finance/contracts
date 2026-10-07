// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// Metadados de uma instância, gerados aqui mesmo: nome, descrição e a imagem
/// como SVG embutido, tudo num `data:` URI. Não existe arquivo em servidor,
/// IPFS ou gateway — o que a carteira mostra não depende de ninguém manter
/// nada no ar, e não pode ser trocado depois.
///
/// O desenho é o cartão do app (web/app: components/NftCard). Mudou um, muda o
/// outro. A fonte é a monoespaçada de quem renderiza: um SVG usado como imagem
/// não carrega fonte de fora.
library InstanceArt {
    using Strings for uint256;

    function tokenURI(uint256 tokenId) internal pure returns (string memory) {
        string memory id = tokenId.toString();
        bytes memory json = abi.encodePacked(
            '{"name":"Lucrios Bot #',
            id,
            '","description":"One Lucrios bot instance. Whoever holds this token owns the bot: it trades from the ',
            "holder's wallet, inside limits the holder sets on-chain.",
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(svg(tokenId)),
            '","attributes":[{"trait_type":"Instance","display_type":"number","value":',
            id,
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function svg(uint256 tokenId) internal pure returns (bytes memory) {
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 430">'
            '<defs><linearGradient id="b" x1=".2" y1="0" x2=".8" y2="1">'
            '<stop offset="0" stop-color="#1d1f2b"/><stop offset="1" stop-color="#0d0f16"/></linearGradient>'
            '<linearGradient id="s" x1="0" y1=".3" x2="1" y2=".7">'
            '<stop offset=".3" stop-color="#ec4899" stop-opacity="0"/>'
            '<stop offset=".45" stop-color="#ec4899" stop-opacity=".16"/>'
            '<stop offset=".55" stop-color="#8b5cf6" stop-opacity=".16"/>'
            '<stop offset=".7" stop-color="#8b5cf6" stop-opacity="0"/></linearGradient></defs>'
            '<rect x="1.5" y="1.5" width="317" height="427" rx="34" fill="url(#b)"/>'
            '<rect x="1.5" y="1.5" width="317" height="427" rx="34" fill="url(#s)"/>'
            '<rect x="1.5" y="1.5" width="317" height="427" rx="34" fill="none" stroke="#ec4899" '
            'stroke-opacity=".45" stroke-width="3"/>'
            '<path d="M52 44v60h37" fill="none" stroke="#ec4899" stroke-width="9" stroke-linecap="round" '
            'stroke-linejoin="round"/><circle cx="89" cy="54" r="7.5" fill="#ec4899"/>'
            '<g font-family="ui-monospace,Menlo,Consolas,\'Courier New\',monospace" font-weight="500">'
            '<text x="36" y="318" font-size="20" letter-spacing="3.6" fill="#8a8f9c">INSTANCE</text>'
            '<text x="36" y="364" font-size="44" letter-spacing=".9" fill="#f5f5f7">#',
            _padded(tokenId),
            '</text><text x="36" y="398" font-size="20" letter-spacing="2" fill="#ec4899">LUCRIOS BOT</text>'
            "</g></svg>"
        );
    }

    /// Pelo menos quatro dígitos: 42 → "0042". Acima de 9999 o número cresce.
    function _padded(uint256 tokenId) private pure returns (string memory) {
        string memory id = tokenId.toString();
        uint256 length = bytes(id).length;
        if (length >= 4) return id;
        bytes memory zeros = new bytes(4 - length);
        for (uint256 i = 0; i < zeros.length; i++) {
            zeros[i] = "0";
        }
        return string.concat(string(zeros), id);
    }
}
