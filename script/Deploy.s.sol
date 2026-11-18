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
/// (endereços separados por vírgula), MINT_PRICE_WEI (o preço do mint em
/// ETH, em wei; obrigatório, para o NFT não nascer grátis por esquecimento)
/// e, opcional, MAX_SUPPLY. Depois, o multisig muda o preço (e aceita outros
/// tokens, como o USDG) com `setPaymentToken`.
///
/// Preço em dólar (opcional): com PRICE_POOL (um pool v3 WETH/dólar, o
/// WETH/USDG da Ramses), o mint em ETH passa a custar MINT_PRICE_USD
/// (em unidades do token de dólar: 100 USDG = 100000000) ao preço médio
/// do pool, e o mint no token de dólar (MINT_USD_TOKEN) é ligado ao mesmo
/// preço. TWAP_WINDOW (segundos, padrão 1800) é a janela; MINT_MIN_WEI e
/// MINT_MAX_WEI (padrão: metade e o dobro de MINT_PRICE_WEI) seguram o
/// preço contra um pool manipulado. MINT_PRICE_WEI vira o preço de reserva,
/// usado se o multisig desligar o preço em dólar.
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
        /// Preço do mint em ETH, em wei.
        uint256 mintPrice;
        address[] aggregators;
        address[] quoteTokens;
        /// `pool == address(0)`: só o preço fixo em ETH.
        BotInstanceNFT.UsdPricing usdPricing;
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
            mintPrice: vm.envUint("MINT_PRICE_WEI"),
            aggregators: vm.envAddress("AGGREGATORS", ","),
            quoteTokens: vm.envAddress("QUOTE_TOKENS", ","),
            usdPricing: _usdPricingFromEnv()
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

    function _usdPricingFromEnv() internal view returns (BotInstanceNFT.UsdPricing memory pricing) {
        address pool = vm.envOr("PRICE_POOL", address(0));
        if (pool == address(0)) return pricing;
        uint256 reserve = vm.envUint("MINT_PRICE_WEI");
        pricing = BotInstanceNFT.UsdPricing({
            pool: pool,
            usd: vm.envAddress("MINT_USD_TOKEN"),
            weth: vm.envAddress("WETH"),
            window: uint32(vm.envOr("TWAP_WINDOW", uint256(30 minutes))),
            usdPrice: vm.envUint("MINT_PRICE_USD"),
            minWei: vm.envOr("MINT_MIN_WEI", reserve / 2),
            maxWei: vm.envOr("MINT_MAX_WEI", reserve * 2)
        });
    }

    /// Implanta e configura, com `deployer` como dono durante a configuração.
    /// Deve ser chamada dentro de um broadcast do deployer.
    function deploy(Config memory config, address deployer)
        public
        returns (BotInstanceNFT nft, TradeExecutor executor)
    {
        // Mint pago em ETH; o id escolhido pelo motor (`mintTo`) continua
        // grátis para o minter.
        nft = new BotInstanceNFT(deployer, config.treasury, config.maxSupply, config.mintPrice);
        executor = new TradeExecutor(
            deployer, IERC721(address(nft)), config.weth, config.operator, config.treasury, config.volumeFeeBps
        );

        // O motor cunha os NFTs com o id da instância no banco.
        nft.setMinter(config.operator);
        // Preço em dólar: o mint em ETH segue o pool e o token de dólar é
        // aceito pelo mesmo valor. `setUsdPricing` consulta o pool: sem
        // histórico para a janela, a implantação para aqui.
        if (config.usdPricing.pool != address(0)) {
            nft.setUsdPricing(config.usdPricing);
            nft.setPaymentToken(config.usdPricing.usd, true, config.usdPricing.usdPrice);
        }
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
        vm.serializeUint(key, "mintPriceWei", config.mintPrice);
        vm.serializeAddress(key, "pricePool", config.usdPricing.pool);
        vm.serializeUint(key, "mintPriceUsd", config.usdPricing.usdPrice);
        vm.serializeAddress(key, "nft", address(nft));
        string memory json = vm.serializeAddress(key, "executor", address(executor));
        vm.writeJson(json, string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"));
    }
}
