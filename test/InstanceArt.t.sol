// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BotInstanceNFT} from "../src/BotInstanceNFT.sol";
import {InstanceArt} from "../src/InstanceArt.sol";

contract InstanceArtTest is Test {
    BotInstanceNFT nft;

    address alice = makeAddr("alice");
    uint256 constant PRICE = 0.08 ether;

    string constant JSON_PREFIX = "data:application/json;base64,";
    string constant SVG_PREFIX = "data:image/svg+xml;base64,";

    function setUp() public {
        nft = new BotInstanceNFT(makeAddr("multisig"), makeAddr("treasury"), 200, PRICE);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nft.mint{value: PRICE}(address(0));
    }

    function test_tokenURIIsSelfContainedJson() public view {
        string memory json = string(_decode(_strip(nft.tokenURI(1), JSON_PREFIX)));

        assertEq(vm.parseJsonString(json, ".name"), "Lucrios Bot #1");
        assertEq(vm.parseJsonUint(json, ".attributes[0].value"), 1);
        assertGt(bytes(vm.parseJsonString(json, ".description")).length, 0);
    }

    function test_imageIsAnEmbeddedSvgThatLoadsNothingFromOutside() public view {
        string memory json = string(_decode(_strip(nft.tokenURI(1), JSON_PREFIX)));
        string memory svg = string(_decode(_strip(vm.parseJsonString(json, ".image"), SVG_PREFIX)));

        assertTrue(_startsWith(svg, '<svg xmlns="http://www.w3.org/2000/svg"'));
        assertTrue(_contains(svg, ">#0001</text>"), "numero com quatro digitos");
        assertTrue(_contains(svg, "</svg>"));
        // O namespace é a única URL permitida: nada de imagem, fonte ou script de fora.
        assertEq(_count(svg, "http"), 1);
        assertFalse(_contains(svg, "<image"));
        assertFalse(_contains(svg, "<script"));
        assertFalse(_contains(svg, "@import"));
    }

    function test_svgIsTheImageOfTheTokenURI() public view {
        string memory json = string(_decode(_strip(nft.tokenURI(1), JSON_PREFIX)));
        bytes memory svg = _decode(_strip(vm.parseJsonString(json, ".image"), SVG_PREFIX));
        assertEq(svg, InstanceArt.svg(1));
    }

    function test_numberIsPaddedToFourDigitsAndGrowsPastThat() public pure {
        assertTrue(_contains(string(InstanceArt.svg(42)), ">#0042</text>"));
        assertTrue(_contains(string(InstanceArt.svg(9999)), ">#9999</text>"));
        assertTrue(_contains(string(InstanceArt.svg(12345)), ">#12345</text>"));
    }

    function test_unknownTokenHasNoMetadata() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        nft.tokenURI(2);
    }

    /// Todo id produz JSON válido: o número é o único dado variável.
    function testFuzz_everyIdYieldsValidJson(uint256 tokenId) public pure {
        string memory json = string(_decode(_strip(InstanceArt.tokenURI(tokenId), JSON_PREFIX)));
        assertEq(vm.parseJsonUint(json, ".attributes[0].value"), tokenId);
    }

    // ===== apoio =====

    function _strip(string memory value, string memory prefix) private pure returns (string memory) {
        assertTrue(_startsWith(value, prefix), "prefixo do data URI");
        bytes memory raw = bytes(value);
        uint256 skip = bytes(prefix).length;
        bytes memory rest = new bytes(raw.length - skip);
        for (uint256 i = 0; i < rest.length; i++) {
            rest[i] = raw[i + skip];
        }
        return string(rest);
    }

    function _startsWith(string memory value, string memory prefix) private pure returns (bool) {
        bytes memory a = bytes(value);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _contains(string memory value, string memory needle) private pure returns (bool) {
        return _count(value, needle) > 0;
    }

    function _count(string memory value, string memory needle) private pure returns (uint256 found) {
        bytes memory a = bytes(value);
        bytes memory b = bytes(needle);
        if (a.length < b.length) return 0;
        for (uint256 i = 0; i + b.length <= a.length; i++) {
            bool same = true;
            for (uint256 j = 0; j < b.length; j++) {
                if (a[i + j] != b[j]) {
                    same = false;
                    break;
                }
            }
            if (same) found++;
        }
    }

    /// Base64 padrão, com padding — o que o `Base64.encode` da OpenZeppelin produz.
    function _decode(string memory encoded) private pure returns (bytes memory out) {
        bytes memory data = bytes(encoded);
        require(data.length % 4 == 0, "base64: tamanho");
        if (data.length == 0) return out;

        uint256 padding = data[data.length - 1] == "=" ? (data[data.length - 2] == "=" ? 2 : 1) : 0;
        out = new bytes(data.length / 4 * 3 - padding);
        uint256 o;
        for (uint256 i = 0; i < data.length; i += 4) {
            uint256 chunk = (_sextet(data[i]) << 18) | (_sextet(data[i + 1]) << 12) | (_sextet(data[i + 2]) << 6)
                | _sextet(data[i + 3]);
            if (o < out.length) out[o++] = bytes1(uint8(chunk >> 16));
            if (o < out.length) out[o++] = bytes1(uint8(chunk >> 8));
            if (o < out.length) out[o++] = bytes1(uint8(chunk));
        }
    }

    function _sextet(bytes1 char) private pure returns (uint256) {
        uint8 c = uint8(char);
        if (c >= 65 && c <= 90) return c - 65;
        if (c >= 97 && c <= 122) return c - 71;
        if (c >= 48 && c <= 57) return c + 4;
        if (c == 43) return 62;
        if (c == 47) return 63;
        if (c == 61) return 0;
        revert("base64: caractere");
    }
}
