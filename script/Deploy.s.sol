// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BotInstanceNFT} from "../src/BotInstanceNFT.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";

/// Implanta o `BotInstanceNFT` e o `TradeExecutor`, configura o que a
/// operadora precisa e entrega os dois ao dono final.
///
///   forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
///
/// Variáveis: OWNER (multisig), TREASURY, OPERATOR (a chave do motor, também
/// `minter` do NFT), WETH, VOLUME_FEE_BPS, AGGREGATORS e QUOTE_TOKENS
/// (endereços separados por vírgula) e, opcional, MAX_SUPPLY.
///
/// A configuração é feita com o deployer como dono; no fim a posse passa
/// ao OWNER em dois passos (`Ownable2Step`): ele precisa chamar
/// `acceptOwnership` nos dois contratos. Fora de uma chain local, o OWNER não
/// pode ser o próprio deployer, a não ser com ALLOW_DEPLOYER_OWNER=true.
///
/// Os endereços vão para `deployments/<chainid>.json`.
contract Deploy is Script {
    struct Config {
        address owner;
        address treasury;
        address operator;
        address weth;
        uint16 volumeFeeBps;
        uint256 maxSupply;
        address[] aggregators;
        address[] quoteTokens;
    }

    /// Chains de teste: anvil e hardhat.
    function _isLocal() internal view returns (bool) {
        return block.chainid == 31337;
    }

    function run() external virtual returns (BotInstanceNFT nft, TradeExecutor executor) {
        Config memory config = Config({
            owner: vm.envAddress("OWNER"),
            treasury: vm.envAddress("TREASURY"),
            operator: vm.envAddress("OPERATOR"),
            weth: vm.envAddress("WETH"),
            volumeFeeBps: uint16(vm.envUint("VOLUME_FEE_BPS")),
            maxSupply: vm.envOr("MAX_SUPPLY", uint256(10_000)),
            aggregators: vm.envAddress("AGGREGATORS", ","),
            quoteTokens: vm.envAddress("QUOTE_TOKENS", ",")
        });

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        require(
            _isLocal() || config.owner != deployer || vm.envOr("ALLOW_DEPLOYER_OWNER", false),
            "OWNER is the deployer: point it at the multisig (or ALLOW_DEPLOYER_OWNER=true)"
        );
        (nft, executor) = deploy(config, deployer);
        vm.stopBroadcast();

        write(nft, executor, config);
    }

    /// Implanta e configura, com `deployer` como dono durante a configuração.
    /// Deve ser chamada dentro de um broadcast do deployer.
    function deploy(Config memory config, address deployer)
        public
        returns (BotInstanceNFT nft, TradeExecutor executor)
    {
        // Mint público grátis: o NFT pago saiu do plano.
        nft = new BotInstanceNFT(deployer, config.treasury, config.maxSupply, 0);
        executor = new TradeExecutor(
            deployer, IERC721(address(nft)), config.weth, config.operator, config.treasury, config.volumeFeeBps
        );

        // O motor cunha os NFTs com o id da instância no banco.
        nft.setMinter(config.operator);
        for (uint256 i = 0; i < config.aggregators.length; i++) {
            executor.setAggregator(config.aggregators[i], true);
        }
        for (uint256 i = 0; i < config.quoteTokens.length; i++) {
            executor.setQuoteToken(config.quoteTokens[i], true);
        }

        if (config.owner != deployer) {
            nft.transferOwnership(config.owner);
            executor.transferOwnership(config.owner);
        }
    }

    function write(BotInstanceNFT nft, TradeExecutor executor, Config memory config) public {
        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "block", block.number);
        vm.serializeAddress(key, "owner", config.owner);
        vm.serializeAddress(key, "treasury", config.treasury);
        vm.serializeAddress(key, "operator", config.operator);
        vm.serializeAddress(key, "weth", config.weth);
        vm.serializeUint(key, "volumeFeeBps", config.volumeFeeBps);
        vm.serializeAddress(key, "nft", address(nft));
        string memory json = vm.serializeAddress(key, "executor", address(executor));
        vm.writeJson(json, string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"));
    }
}
