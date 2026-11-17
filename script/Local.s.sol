// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {BotInstanceNFT} from "../src/BotInstanceNFT.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {Token, MockWETH, MockAggregator} from "../test/Mocks.sol";
import {Deploy} from "./Deploy.s.sol";

/// Uma chain local pronta para o motor operar pelo cofre, para os testes de
/// ponta a ponta (o backend roda contra isto na CI):
///
///   anvil &
///   forge script script/Local.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
///
/// Usa as contas padrão do anvil:
///   0 — deployer e dono dos contratos;
///   1 — operadora (a chave do motor) e `minter`;
///   2 — dona do bot da casa 900001, que dá os limites dele.
///
/// Implanta um WETH, um token (MEME) e um agregador de mentira que troca a
/// um preço fixo (1 WETH = 1.000 MEME, nos dois sentidos), cunha o NFT
/// 900001, libera 10 WETH por trade e põe no cofre 5 WETH e 1 ETH. Os
/// endereços vão para `deployments/local.json`.
contract Local is Deploy {
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant OPERATOR_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant HOUSE_OWNER_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    uint256 public constant HOUSE_BOT = 900_001;
    uint16 public constant VOLUME_FEE_BPS = 50;

    function run() external override returns (BotInstanceNFT nft, TradeExecutor executor) {
        require(_isLocal(), "Local.s.sol only runs on a local chain (31337)");
        address deployer = vm.addr(DEPLOYER_KEY);
        address operator = vm.addr(OPERATOR_KEY);
        address houseOwner = vm.addr(HOUSE_OWNER_KEY);

        vm.startBroadcast(DEPLOYER_KEY);
        MockWETH weth = new MockWETH();
        Token meme = new Token("MEME");
        MockAggregator aggregator = new MockAggregator();
        weth.mint(address(aggregator), 1_000_000e18);
        meme.mint(address(aggregator), 1_000_000_000e18);

        address[] memory aggregators = new address[](1);
        aggregators[0] = address(aggregator);
        address[] memory quotes = new address[](1);
        quotes[0] = address(weth);
        Config memory config = Config({
            owner: deployer,
            treasury: deployer,
            operator: operator,
            weth: address(weth),
            volumeFeeBps: VOLUME_FEE_BPS,
            maxSupply: 10_000,
            aggregators: aggregators,
            quoteTokens: quotes
        });
        (nft, executor) = deploy(config, deployer);

        // O bot da casa, com o cofre carregado antes de existir.
        nft.mintTo(houseOwner, HOUSE_BOT);
        address vault = executor.vaultOf(HOUSE_BOT);
        weth.mint(vault, 5e18);
        (bool sent,) = vault.call{value: 1 ether}("");
        require(sent, "could not fund the vault with eth");
        vm.stopBroadcast();

        vm.startBroadcast(HOUSE_OWNER_KEY);
        executor.setLimits(HOUSE_BOT, 10e18, false, true);
        vm.stopBroadcast();

        write(nft, executor, config);
        string memory key = "local";
        vm.serializeJson(key, vm.readFile(_path(vm.toString(block.chainid))));
        vm.serializeAddress(key, "meme", address(meme));
        vm.serializeAddress(key, "aggregator", address(aggregator));
        vm.serializeAddress(key, "vault", vault);
        vm.serializeAddress(key, "houseOwner", houseOwner);
        vm.serializeUint(key, "houseBot", HOUSE_BOT);
        string memory json = vm.serializeBytes32(key, "operatorKey", bytes32(OPERATOR_KEY));
        vm.writeJson(json, _path("local"));
    }

    function _path(string memory name) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/", name, ".json");
    }
}
