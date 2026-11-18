// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {InstanceVault} from "./InstanceVault.sol";
import {IV3PositionAdapter} from "./V3PositionAdapters.sol";

interface IWETH {
    function deposit() external payable;
}

/// Executa os trades das instâncias.
///
/// Modelo de custódia: cada instância (NFT) tem um cofre (`InstanceVault`)
/// com o que é dela. Para abrir, este contrato tira a cotação do cofre, troca
/// e põe o ativo no cofre; para fechar, o inverso. A faixa de liquidez (ordem
/// limite, LP) nasce com o cofre como dono do NFT. Entre uma chamada e outra
/// este contrato só guarda as taxas ainda não sacadas. O dono do NFT saca do
/// cofre a qualquer momento, sem passar por aqui.
///
/// Só a carteira operadora (o assinador do backend) inicia trades. Ela decide;
/// este contrato limita e registra. O que uma operadora comprometida consegue
/// fazer é limitado aqui, não no backend:
///  - o resultado de um trade só vai para o cofre da instância;
///  - só mercados liberados pelo dono (um a um, ou todos com `anyMarket`);
///  - valor por trade limitado pelo dono, que também pode pausar;
///  - no pool direto, preço executado preso ao preço médio do pool (TWAP);
///  - no agregador, aprovação exata a destinos aprovados pelo multisig e
///    medição do que voltou, com o preço médio de um pool de referência
///    quando o par tem um;
///  - faixas de liquidez só em pools da factory cadastrada para o
///    gerenciador, com o cofre como dono do NFT;
///  - taxa nunca acima de `volumeFeeBps`, que o multisig limita a
///    `MAX_VOLUME_FEE_BPS`;
///  - um trade que perde mais que `lossPauseBps` do custo pausa a instância.
///
/// Cada trade emite um evento com o `decision` que a operadora informou: o
/// hash do registro da decisão do agente, publicado fora da chain. É o que
/// liga o que o agente decidiu ao que foi executado.
///
/// Não é atualizável: um contrato que move os fundos dos cofres não deve
/// poder mudar de código. Versão nova = contrato novo e cofres novos.
contract TradeExecutor is Ownable2Step, ReentrancyGuard, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// Teto da taxa de volume: 1%.
    uint16 public constant MAX_VOLUME_FEE_BPS = 100;
    uint256 public constant MAX_DEVIATION_BPS = 1_000;

    struct Market {
        address base;
        address quote;
        bool enabled;
        /// Janela do preço médio, em segundos.
        uint32 twapWindow;
        /// Quanto o preço executado pode ser pior que o preço médio. Precisa
        /// cobrir a taxa do pool e o impacto de preço de uma ordem normal.
        uint16 maxDeviationBps;
    }

    /// Limites definidos pelo dono da instância. Nascem zerados: uma
    /// instância não opera até o dono dizer quanto pode ir em cada trade.
    struct Limits {
        uint256 maxPerTrade;
        bool paused;
        /// Libera todos os mercados: os pools cadastrados e qualquer par cuja
        /// cotação o multisig aceita. É o que as habilidades que caçam pools
        /// novos precisam, já que o pool não existe quando o dono configura.
        bool anyMarket;
    }

    struct Position {
        /// Ativo comprado, no cofre.
        uint256 base;
        /// Cotação gasta para comprar, com a taxa.
        uint256 cost;
    }

    /// Um par negociado pelo agregador. A chave dele (ver `pairKey`) ocupa o
    /// lugar do endereço do pool nos mapas de posição e de mercados liberados.
    struct Pair {
        address base;
        address quote;
    }

    /// A rota de um swap pelo agregador: o contrato a chamar e o calldata,
    /// montados fora da chain.
    struct Route {
        address target;
        bytes data;
    }

    /// Um gerenciador de posições (NFT) de um fork do Uniswap V3.
    struct PositionVenue {
        /// De onde os pools desse gerenciador vêm.
        address factory;
        /// Como montar as chamadas desse fork.
        IV3PositionAdapter adapter;
        /// Desabilitar impede faixas novas; as abertas continuam saindo.
        bool enabled;
        /// Faixas aqui não pagam taxa (parceria com o AMM).
        bool feeExempt;
        /// Janela do preço médio, em segundos. 0 = sem trava de preço, só
        /// para AMM cujos pools não guardam histórico.
        uint32 twapWindow;
        /// Quantos ticks o preço atual pode estar longe do médio para abrir
        /// ou fechar uma faixa (100 ticks ≈ 1%).
        uint24 maxTickDeviation;
    }

    /// Uma faixa aberta, cujo NFT está no cofre.
    struct Range {
        address manager;
        address pool;
        address base;
        address quote;
        uint128 liquidity;
    }

    /// Os parâmetros de uma faixa nova.
    struct RangeOpen {
        uint256 tokenId;
        address manager;
        address pool;
        /// Qual dos dois tokens do pool é a cotação (a taxa é contada nele).
        address quote;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        uint256 amount0Min;
        uint256 amount1Min;
        uint16 feeBps;
        uint256 deadline;
        bytes32 decision;
    }

    /// Os parâmetros do fechamento de uma faixa.
    struct RangeClose {
        uint256 tokenId;
        uint256 nftId;
        uint256 amount0Min;
        uint256 amount1Min;
        uint16 feeBps;
        uint256 deadline;
        bytes32 decision;
    }

    IERC721 public immutable nft;
    address public immutable weth;
    address public immutable vaultImplementation;

    address public operator;
    address public treasury;
    /// Taxa máxima por trade, sobre a cotação que entra ou sai. A operadora
    /// informa a de cada trade (zero nos AMMs parceiros), nunca acima desta.
    uint16 public volumeFeeBps;
    /// Perda num único trade, em pontos-base do custo, a partir da qual a
    /// instância é pausada sozinha. 0 = desligado.
    uint16 public lossPauseBps;

    mapping(address pool => Market) public markets;
    mapping(uint256 tokenId => Limits) public limits;
    mapping(uint256 tokenId => mapping(address market => bool)) public marketAllowed;
    mapping(uint256 tokenId => mapping(address market => Position)) public positions;
    mapping(uint256 tokenId => mapping(uint256 nftId => Range)) public ranges;
    /// Instâncias que não pagam taxa (as da casa, as da whitelist).
    mapping(uint256 tokenId => bool) public feeExempt;

    /// Um assinante escolhido pelo dono da instância, além da operadora. A
    /// delegação guarda quem delegou e só vale enquanto ele for o dono: quem
    /// compra a NFT não herda o assinante do vendedor.
    struct Delegation {
        address owner;
        address signer;
    }

    mapping(uint256 tokenId => Delegation) private _delegations;

    /// Taxas acumuladas e ainda não sacadas, por beneficiário e por token.
    mapping(address account => mapping(address token => uint256)) public claimable;

    /// Contratos de roteamento que podem receber a entrada de um swap.
    mapping(address target => bool) public aggregators;
    /// Tokens aceitos como cotação no agregador e nas faixas.
    mapping(address token => bool) public quoteTokens;
    /// Par de cada chave já usada.
    mapping(address key => Pair) public pairs;
    /// Pool cadastrado cujo preço médio também limita os swaps do par pelo
    /// agregador. `address(0)` = par sem referência de preço.
    mapping(address key => address) public referencePool;
    mapping(address manager => PositionVenue) public positionVenues;

    /// Pool com swap em andamento; só ele pode chamar o callback.
    address private _activePool;

    event VaultCreated(uint256 indexed tokenId, address vault);
    event PositionOpened(
        uint256 indexed tokenId, address indexed market, uint256 quoteIn, uint256 fee, uint256 baseOut, bytes32 decision
    );
    event PositionClosed(
        uint256 indexed tokenId,
        address indexed market,
        uint256 baseIn,
        uint256 quoteOut,
        uint256 fee,
        int256 pnl,
        bytes32 decision
    );
    event PositionDropped(uint256 indexed tokenId, address indexed market, uint256 base, uint256 cost);
    event RangeOpened(
        uint256 indexed tokenId,
        address indexed manager,
        uint256 indexed nftId,
        address pool,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint256 fee,
        bytes32 decision
    );
    event RangeClosed(
        uint256 indexed tokenId,
        address indexed manager,
        uint256 indexed nftId,
        uint256 baseOut,
        uint256 quoteOut,
        uint256 fee,
        bytes32 decision
    );
    event RangeDropped(uint256 indexed tokenId, address indexed manager, uint256 indexed nftId);
    event Wrapped(uint256 indexed tokenId, uint256 amount);
    event LimitsSet(uint256 indexed tokenId, uint256 maxPerTrade, bool paused, bool anyMarket);
    event MarketAllowedSet(uint256 indexed tokenId, address indexed market, bool allowed);
    event FeeExemptSet(uint256 indexed tokenId, bool exempt);
    event SignerSet(uint256 indexed tokenId, address indexed owner, address signer);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);
    event MarketSet(
        address indexed pool, address base, address quote, bool enabled, uint32 twapWindow, uint16 maxDeviationBps
    );
    event OperatorSet(address operator);
    event TreasurySet(address treasury);
    event VolumeFeeSet(uint16 volumeFeeBps);
    event AggregatorSet(address indexed target, bool allowed);
    event QuoteTokenSet(address indexed token, bool allowed);
    event PairReferenceSet(address indexed key, address indexed pool);
    event PositionVenueSet(
        address indexed manager,
        address factory,
        address adapter,
        bool enabled,
        bool feeExempt,
        uint32 twapWindow,
        uint24 maxTickDeviation
    );
    event LossPauseSet(uint16 lossPauseBps);
    event InstanceAutoPaused(uint256 indexed tokenId, address indexed market, uint256 cost, uint256 proceeds);

    error NotOperator();
    error NotSigner(uint256 tokenId);
    error NotInstanceOwner(uint256 tokenId);
    error Expired();
    error LengthMismatch();
    error EmptyBatch();
    error MarketDisabled(address pool);
    error MarketNotAllowed(uint256 tokenId, address market);
    error InstancePaused(uint256 tokenId);
    error OverTradeLimit(uint256 tokenId, uint256 amount, uint256 maxPerTrade);
    error ZeroAmount();
    error PositionExists(uint256 tokenId, address market);
    error NoPosition(uint256 tokenId, address market);
    error PositionStillHeld(uint256 tokenId, address market);
    error InsufficientOutput(uint256 out, uint256 minOut);
    error PriceDeviation(uint256 out, uint256 expectedAtTwap);
    error SwapNotFilled();
    error BadCallback();
    error InvalidMarket();
    error FeeTooHigh(uint16 feeBps, uint16 maxBps);
    error ZeroAddress();
    error NothingToWithdraw();
    error AggregatorNotAllowed(address target);
    error QuoteTokenNotAllowed(address token);
    error InvalidPair();
    error AggregatorCallFailed();
    error VenueDisabled(address manager);
    error InvalidRange();
    error NoRange(uint256 tokenId, uint256 nftId);
    error RangeStillHeld(uint256 tokenId, uint256 nftId);
    error RangeNotInVault(uint256 nftId);
    error RangePriceDeviation(int24 spot, int24 mean);

    modifier onlyInstanceOwner(uint256 tokenId) {
        if (nft.ownerOf(tokenId) != msg.sender) revert NotInstanceOwner(tokenId);
        _;
    }

    constructor(
        address initialOwner,
        IERC721 nft_,
        address weth_,
        address operator_,
        address treasury_,
        uint16 volumeFeeBps_
    ) Ownable(initialOwner) {
        if (address(nft_) == address(0) || weth_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (volumeFeeBps_ > MAX_VOLUME_FEE_BPS) revert FeeTooHigh(volumeFeeBps_, MAX_VOLUME_FEE_BPS);
        nft = nft_;
        weth = weth_;
        vaultImplementation = address(new InstanceVault());
        operator = operator_;
        treasury = treasury_;
        volumeFeeBps = volumeFeeBps_;

        emit OperatorSet(operator_);
        emit TreasurySet(treasury_);
        emit VolumeFeeSet(volumeFeeBps_);
    }

    // ===== cofres =====

    /// O endereço do cofre de uma instância, exista ele ou não. Dá para
    /// depositar nele antes de ele ser criado.
    function vaultOf(uint256 tokenId) public view returns (address) {
        return Clones.predictDeterministicAddress(vaultImplementation, bytes32(tokenId));
    }

    /// Cria o cofre. Qualquer um pode chamar; o executor também cria no
    /// primeiro trade.
    function createVault(uint256 tokenId) external returns (address) {
        return address(_vault(tokenId));
    }

    function _vault(uint256 tokenId) private returns (InstanceVault vault) {
        vault = InstanceVault(payable(vaultOf(tokenId)));
        if (address(vault).code.length == 0) {
            Clones.cloneDeterministic(vaultImplementation, bytes32(tokenId));
            vault.initialize(nft, tokenId);
            emit VaultCreated(tokenId, address(vault));
        }
    }

    /// Embrulha o ETH do cofre em WETH, para a instância poder operar com
    /// ele. Depositar ETH puro no cofre é o caminho mais simples para o dono.
    function wrapNative(uint256 tokenId) external nonReentrant {
        _feeFor(tokenId, 0);
        InstanceVault vault = _vault(tokenId);
        uint256 amount = address(vault).balance;
        if (amount == 0) revert ZeroAmount();
        vault.execute(weth, amount, abi.encodeCall(IWETH.deposit, ()));
        emit Wrapped(tokenId, amount);
    }

    // ===== dono da instância =====

    function setLimits(uint256 tokenId, uint256 maxPerTrade, bool paused, bool anyMarket)
        external
        onlyInstanceOwner(tokenId)
    {
        limits[tokenId] = Limits({maxPerTrade: maxPerTrade, paused: paused, anyMarket: anyMarket});
        emit LimitsSet(tokenId, maxPerTrade, paused, anyMarket);
    }

    function setMarketAllowed(uint256 tokenId, address market, bool allowed) external onlyInstanceOwner(tokenId) {
        marketAllowed[tokenId][market] = allowed;
        emit MarketAllowedSet(tokenId, market, allowed);
    }

    /// Escolhe quem, além da operadora, pode operar esta instância: abrir e
    /// fechar posições e faixas e embrulhar ETH, com as mesmas travas da
    /// operadora (limites, mercados liberados, agregadores, preço médio) e
    /// sempre com a taxa cheia. `address(0)` revoga.
    function setSigner(uint256 tokenId, address signer) external onlyInstanceOwner(tokenId) {
        _delegations[tokenId] = Delegation({owner: msg.sender, signer: signer});
        emit SignerSet(tokenId, msg.sender, signer);
    }

    /// O assinante em vigor; `address(0)` se não há, ou se a NFT mudou de
    /// dono depois da delegação.
    function signerOf(uint256 tokenId) public view returns (address) {
        Delegation memory delegation = _delegations[tokenId];
        if (delegation.signer == address(0) || nft.ownerOf(tokenId) != delegation.owner) return address(0);
        return delegation.signer;
    }

    /// Esquece uma posição sem vender: o ativo continua no cofre, e o dono
    /// passa a cuidar dele. Não gera taxa.
    ///
    /// O dono pode chamar sempre. A operadora só quando o ativo não está mais
    /// no cofre (o dono sacou) — do contrário ela poderia esquecer posições
    /// para o protocolo não cobrar a saída.
    function dropPosition(uint256 tokenId, address market) external {
        Position memory position = positions[tokenId][market];
        if (position.base == 0) revert NoPosition(tokenId, market);
        if (msg.sender != nft.ownerOf(tokenId)) {
            if (msg.sender != operator) revert NotInstanceOwner(tokenId);
            if (IERC20(_baseOf(market)).balanceOf(vaultOf(tokenId)) != 0) revert PositionStillHeld(tokenId, market);
        }
        delete positions[tokenId][market];
        emit PositionDropped(tokenId, market, position.base, position.cost);
    }

    /// Esquece uma faixa. O dono pode sempre (e saca o NFT do cofre para
    /// cuidar dela); a operadora só quando o NFT não está mais no cofre.
    function dropRange(uint256 tokenId, uint256 nftId) external {
        Range memory range = ranges[tokenId][nftId];
        if (range.manager == address(0)) revert NoRange(tokenId, nftId);
        if (msg.sender != nft.ownerOf(tokenId)) {
            if (msg.sender != operator) revert NotInstanceOwner(tokenId);
            if (_holdsNft(range.manager, nftId, vaultOf(tokenId))) revert RangeStillHeld(tokenId, nftId);
        }
        delete ranges[tokenId][nftId];
        emit RangeDropped(tokenId, range.manager, nftId);
    }

    function _holdsNft(address collection, uint256 id, address holder) private view returns (bool) {
        try IERC721(collection).ownerOf(id) returns (address current) {
            return current == holder;
        } catch {
            return false;
        }
    }

    // ===== operadora: abrir =====

    /// Um swap em lote: o que entrou e o que saiu, a dividir entre as
    /// instâncias na proporção do que cada uma pôs.
    struct Batch {
        address market;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint16 feeBps;
        bytes32 decision;
    }

    /// O que cada instância pôs num lote.
    struct Shares {
        InstanceVault[] vaults;
        /// Abrir: cotação tirada do cofre, com a taxa. Fechar: ativo vendido.
        uint256[] gross;
        /// Abrir: a taxa de cada uma. Fechar: não usado.
        uint256[] fees;
    }

    /// Abre posição para uma ou mais instâncias no mesmo swap, direto num
    /// pool cadastrado. Com várias, é o copy trade: todos entram ao mesmo
    /// preço médio, e o ativo comprado é dividido na proporção do que cada um
    /// pôs (já sem a taxa).
    function openPositions(
        uint256[] calldata tokenIds,
        address pool,
        uint256[] calldata quoteIns,
        uint256 minBaseOut,
        uint16 feeBps,
        uint256 deadline,
        bytes32 decision
    ) external nonReentrant {
        _checkBatch(tokenIds.length, quoteIns.length, deadline, feeBps);
        feeBps = _feeFor(tokenIds, feeBps);
        Market memory market = markets[pool];
        if (!market.enabled) revert MarketDisabled(pool);

        Batch memory batch = Batch(pool, market.quote, market.base, 0, 0, feeBps, decision);
        Shares memory shares = _takeQuotes(tokenIds, quoteIns, batch);
        batch.amountOut = _swapChecked(pool, market, market.quote, market.base, batch.amountIn, minBaseOut);
        _recordPositions(tokenIds, shares, batch);
    }

    /// Abre posição trocando pelo agregador. Mesmas travas de entrada do pool
    /// direto; a diferença é de onde vem o preço.
    function openViaAggregator(
        uint256[] calldata tokenIds,
        Pair calldata pair,
        uint256[] calldata quoteIns,
        uint256 minBaseOut,
        uint16 feeBps,
        uint256 deadline,
        bytes32 decision,
        Route calldata route
    ) external nonReentrant {
        _checkBatch(tokenIds.length, quoteIns.length, deadline, feeBps);
        feeBps = _feeFor(tokenIds, feeBps);
        if (!quoteTokens[pair.quote]) revert QuoteTokenNotAllowed(pair.quote);

        address key = _usePair(pair);
        Batch memory batch = Batch(key, pair.quote, pair.base, 0, 0, feeBps, decision);
        Shares memory shares = _takeQuotes(tokenIds, quoteIns, batch);
        batch.amountOut = _aggregatorSwap(key, route, pair.quote, pair.base, batch.amountIn, minBaseOut);
        _recordPositions(tokenIds, shares, batch);
    }

    /// Quem pode operar estas instâncias e com que taxa. A operadora informa
    /// a taxa de cada trade (zero nos AMMs parceiros); o assinante de um dono
    /// paga sempre a taxa cheia, ou a isenção ficaria na mão de quem paga.
    function _feeFor(uint256[] calldata tokenIds, uint16 feeBps) private view returns (uint16) {
        if (msg.sender == operator) return feeBps;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (signerOf(tokenIds[i]) != msg.sender) revert NotSigner(tokenIds[i]);
        }
        return volumeFeeBps;
    }

    function _feeFor(uint256 tokenId, uint16 feeBps) private view returns (uint16) {
        if (msg.sender == operator) return feeBps;
        if (signerOf(tokenId) != msg.sender) revert NotSigner(tokenId);
        return volumeFeeBps;
    }

    function _checkBatch(uint256 count, uint256 otherCount, uint256 deadline, uint16 feeBps) private view {
        if (block.timestamp > deadline) revert Expired();
        if (count == 0) revert EmptyBatch();
        if (otherCount != count) revert LengthMismatch();
        if (feeBps > volumeFeeBps) revert FeeTooHigh(feeBps, volumeFeeBps);
    }

    /// Confere os limites de cada instância, tira a cotação do cofre e separa
    /// a taxa. `batch.amountIn` sai com o total a trocar.
    function _takeQuotes(uint256[] calldata tokenIds, uint256[] calldata quoteIns, Batch memory batch)
        private
        returns (Shares memory shares)
    {
        uint256 count = tokenIds.length;
        shares = Shares(new InstanceVault[](count), new uint256[](count), new uint256[](count));
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            _checkCanOpen(tokenId, batch.market, quoteIns[i]);
            if (positions[tokenId][batch.market].base != 0) revert PositionExists(tokenId, batch.market);

            shares.vaults[i] = _vault(tokenId);
            uint256 received = _take(shares.vaults[i], batch.tokenIn, quoteIns[i]);
            uint256 fee = _fee(tokenId, received, batch.feeBps);
            if (fee > 0) claimable[treasury][batch.tokenIn] += fee;
            shares.gross[i] = received;
            shares.fees[i] = fee;
            batch.amountIn += received - fee;
        }
    }

    /// Divide o ativo comprado, põe cada parte no cofre e registra a posição.
    function _recordPositions(uint256[] calldata tokenIds, Shares memory shares, Batch memory batch) private {
        uint256 count = tokenIds.length;
        uint256 distributed;
        for (uint256 i = 0; i < count; i++) {
            // O último fica com o resto do arredondamento.
            uint256 share = i == count - 1
                ? batch.amountOut - distributed
                : FullMath.mulDiv(batch.amountOut, shares.gross[i] - shares.fees[i], batch.amountIn);
            distributed += share;
            // Posição com zero de ativo não é posição: não daria para fechar.
            if (share == 0) revert ZeroAmount();

            uint256 tokenId = tokenIds[i];
            positions[tokenId][batch.market] = Position({base: share, cost: shares.gross[i]});
            IERC20(batch.tokenOut).safeTransfer(address(shares.vaults[i]), share);
            emit PositionOpened(tokenId, batch.market, shares.gross[i], shares.fees[i], share, batch.decision);
        }
    }

    function _checkCanOpen(uint256 tokenId, address market, uint256 quoteIn) private view {
        Limits memory limit = limits[tokenId];
        if (limit.paused) revert InstancePaused(tokenId);
        if (!limit.anyMarket && !marketAllowed[tokenId][market]) revert MarketNotAllowed(tokenId, market);
        if (quoteIn == 0) revert ZeroAmount();
        if (quoteIn > limit.maxPerTrade) revert OverTradeLimit(tokenId, quoteIn, limit.maxPerTrade);
    }

    // ===== operadora: fechar =====

    /// Fecha a posição de uma ou mais instâncias no mesmo swap, direto no
    /// pool. A cotação recebida é dividida na proporção do ativo vendido; de
    /// cada parte sai a taxa, e o resto volta ao cofre.
    ///
    /// Fechar não olha pausa nem limites: são travas para entrar, e um stop
    /// precisa conseguir sair sempre. Vale para mercado desabilitado também.
    function closePositions(
        uint256[] calldata tokenIds,
        address pool,
        uint256 minQuoteOut,
        uint16 feeBps,
        uint256 deadline,
        bytes32 decision
    ) external nonReentrant {
        _checkBatch(tokenIds.length, tokenIds.length, deadline, feeBps);
        feeBps = _feeFor(tokenIds, feeBps);
        Market memory market = markets[pool];
        if (market.base == address(0)) revert InvalidMarket();

        Batch memory batch = Batch(pool, market.base, market.quote, 0, 0, feeBps, decision);
        Shares memory shares = _takePositions(tokenIds, batch);
        batch.amountOut = _swapChecked(pool, market, market.base, market.quote, batch.amountIn, minQuoteOut);
        _settleAll(tokenIds, shares, batch);
    }

    /// Fecha trocando pelo agregador. Não olha pausa, limites nem a lista de
    /// tokens de cotação: quem está posicionado precisa conseguir sair.
    function closeViaAggregator(
        uint256[] calldata tokenIds,
        Pair calldata pair,
        uint256 minQuoteOut,
        uint16 feeBps,
        uint256 deadline,
        bytes32 decision,
        Route calldata route
    ) external nonReentrant {
        _checkBatch(tokenIds.length, tokenIds.length, deadline, feeBps);
        feeBps = _feeFor(tokenIds, feeBps);
        address key = pairKey(pair.base, pair.quote);
        if (pairs[key].base == address(0)) revert InvalidPair();

        Batch memory batch = Batch(key, pair.base, pair.quote, 0, 0, feeBps, decision);
        Shares memory shares = _takePositions(tokenIds, batch);
        batch.amountOut = _aggregatorSwap(key, route, pair.base, pair.quote, batch.amountIn, minQuoteOut);
        _settleAll(tokenIds, shares, batch);
    }

    /// Tira de cada cofre o ativo da posição. Se o dono sacou parte, vende o
    /// que sobrou; se sacou tudo, a operadora precisa esquecer a posição
    /// (`dropPosition`) antes.
    function _takePositions(uint256[] calldata tokenIds, Batch memory batch) private returns (Shares memory shares) {
        uint256 count = tokenIds.length;
        shares = Shares(new InstanceVault[](count), new uint256[](count), new uint256[](0));
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 amount = positions[tokenId][batch.market].base;
            if (amount == 0) revert NoPosition(tokenId, batch.market);

            shares.vaults[i] = _vault(tokenId);
            uint256 held = IERC20(batch.tokenIn).balanceOf(address(shares.vaults[i]));
            if (held < amount) amount = held;
            if (amount == 0) revert NoPosition(tokenId, batch.market);

            shares.gross[i] = _take(shares.vaults[i], batch.tokenIn, amount);
            batch.amountIn += shares.gross[i];
        }
    }

    function _settleAll(uint256[] calldata tokenIds, Shares memory shares, Batch memory batch) private {
        uint256 count = tokenIds.length;
        uint256 distributed;
        for (uint256 i = 0; i < count; i++) {
            // O último fica com o resto do arredondamento.
            uint256 proceeds = i == count - 1
                ? batch.amountOut - distributed
                : FullMath.mulDiv(batch.amountOut, shares.gross[i], batch.amountIn);
            distributed += proceeds;
            _settle(tokenIds[i], shares.vaults[i], shares.gross[i], proceeds, batch);
        }
    }

    /// Encerra a posição de uma instância: separa a taxa e põe o resto no
    /// cofre.
    function _settle(uint256 tokenId, InstanceVault vault, uint256 sold, uint256 proceeds, Batch memory batch) private {
        Position memory position = positions[tokenId][batch.market];
        delete positions[tokenId][batch.market];
        // Se o dono sacou parte do ativo, o custo do que foi vendido é a
        // parte proporcional.
        uint256 cost = sold >= position.base ? position.cost : FullMath.mulDiv(position.cost, sold, position.base);

        uint256 fee = _fee(tokenId, proceeds, batch.feeBps);
        if (fee > 0) claimable[treasury][batch.tokenOut] += fee;
        _checkLoss(tokenId, batch.market, cost, proceeds);

        IERC20(batch.tokenOut).safeTransfer(address(vault), proceeds - fee);
        emit PositionClosed(
            tokenId, batch.market, sold, proceeds, fee, int256(proceeds - fee) - int256(cost), batch.decision
        );
    }

    /// Perder quase tudo num trade só não é resultado de estratégia: ou o
    /// mercado quebrou, ou alguém está executando contra o dono. A instância
    /// para de abrir posição até o dono olhar e reativar.
    function _checkLoss(uint256 tokenId, address market, uint256 cost, uint256 proceeds) private {
        if (lossPauseBps != 0 && proceeds * BPS < cost * (BPS - lossPauseBps)) {
            limits[tokenId].paused = true;
            emit InstanceAutoPaused(tokenId, market, cost, proceeds);
        }
    }

    // ===== operadora: faixas de liquidez (ordem limite, LP) =====

    /// Abre uma faixa num pool de um fork do Uniswap V3 cadastrado. O NFT da
    /// faixa nasce no cofre. A taxa incide sobre a cotação que de fato entrou
    /// na faixa, e é tirada do cofre à parte.
    function openRange(RangeOpen calldata p) external nonReentrant returns (uint256 nftId) {
        if (block.timestamp > p.deadline) revert Expired();
        if (p.feeBps > volumeFeeBps) revert FeeTooHigh(p.feeBps, volumeFeeBps);
        _feeFor(p.tokenId, p.feeBps);
        PositionVenue memory venue = positionVenues[p.manager];
        if (!venue.enabled) revert VenueDisabled(p.manager);

        (address token0, address token1) = venue.adapter.poolTokens(venue.factory, p.pool);
        _checkRangePrice(venue, p.pool);
        if (p.quote != token0 && p.quote != token1) revert InvalidRange();
        if (!quoteTokens[p.quote]) revert QuoteTokenNotAllowed(p.quote);
        if (p.amount0 == 0 && p.amount1 == 0) revert ZeroAmount();
        bool quoteIs0 = p.quote == token0;
        // O limite por trade vale para a cotação que entra. Uma faixa só de
        // ativo (vender, por ordem limite, o que já está no cofre) não traz
        // dinheiro novo, mas ainda exige a instância ativa e o mercado
        // liberado — por isso conta como 1.
        uint256 quoteIn = quoteIs0 ? p.amount0 : p.amount1;
        _checkCanOpen(p.tokenId, p.pool, quoteIn == 0 ? 1 : quoteIn);

        InstanceVault vault = _vault(p.tokenId);
        Minted memory minted = _mintRange(venue.adapter, p, vault, token0, token1);
        nftId = minted.nftId;

        uint256 fee =
            venue.feeExempt ? 0 : _fee(p.tokenId, quoteIs0 ? minted.used0 : minted.used1, _feeFor(p.tokenId, p.feeBps));
        if (fee > 0) {
            _take(vault, p.quote, fee);
            claimable[treasury][p.quote] += fee;
        }

        _recordRange(p, minted, quoteIs0 ? token1 : token0, fee);
    }

    function _recordRange(RangeOpen calldata p, Minted memory m, address base, uint256 fee) private {
        ranges[p.tokenId][m.nftId] =
            Range({manager: p.manager, pool: p.pool, base: base, quote: p.quote, liquidity: m.liquidity});
        emit RangeOpened(p.tokenId, p.manager, m.nftId, p.pool, m.liquidity, m.used0, m.used1, fee, p.decision);
    }

    /// O que o gerenciador devolveu do `mint`.
    struct Minted {
        uint256 nftId;
        uint128 liquidity;
        uint256 used0;
        uint256 used1;
    }

    /// Tira os valores do cofre, deposita no gerenciador com o cofre como
    /// dono do NFT e devolve ao cofre o que não entrou.
    function _mintRange(
        IV3PositionAdapter adapter,
        RangeOpen calldata p,
        InstanceVault vault,
        address token0,
        address token1
    ) private returns (Minted memory m) {
        uint256 in0 = p.amount0 == 0 ? 0 : _take(vault, token0, p.amount0);
        uint256 in1 = p.amount1 == 0 ? 0 : _take(vault, token1, p.amount1);
        IERC20(token0).forceApprove(p.manager, in0);
        IERC20(token1).forceApprove(p.manager, in1);

        bytes memory data = adapter.mintCall(
            IV3PositionAdapter.Mint({
                pool: p.pool,
                token0: token0,
                token1: token1,
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                amount0Desired: in0,
                amount1Desired: in1,
                amount0Min: p.amount0Min,
                amount1Min: p.amount1Min,
                recipient: address(vault),
                deadline: p.deadline
            })
        );
        (bool ok, bytes memory result) = p.manager.call(data);
        if (!ok) _bubble(result);
        (m.nftId, m.liquidity, m.used0, m.used1) = abi.decode(result, (uint256, uint128, uint256, uint256));

        IERC20(token0).forceApprove(p.manager, 0);
        IERC20(token1).forceApprove(p.manager, 0);
        if (IERC721(p.manager).ownerOf(m.nftId) != address(vault)) revert RangeNotInVault(m.nftId);
        if (in0 > m.used0) IERC20(token0).safeTransfer(address(vault), in0 - m.used0);
        if (in1 > m.used1) IERC20(token1).safeTransfer(address(vault), in1 - m.used1);
    }

    /// Retira a faixa inteira, com a taxa ganha no pool, e queima o NFT. A
    /// nossa taxa incide sobre a cotação que saiu; o resto volta ao cofre.
    /// Vale com o gerenciador desabilitado: quem está posicionado sai sempre.
    function closeRange(RangeClose calldata p) external nonReentrant {
        if (block.timestamp > p.deadline) revert Expired();
        if (p.feeBps > volumeFeeBps) revert FeeTooHigh(p.feeBps, volumeFeeBps);
        uint16 feeBps = _feeFor(p.tokenId, p.feeBps);
        Range memory range = ranges[p.tokenId][p.nftId];
        if (range.manager == address(0)) revert NoRange(p.tokenId, p.nftId);
        delete ranges[p.tokenId][p.nftId];

        PositionVenue memory venue = positionVenues[range.manager];
        _checkRangePrice(venue, range.pool);
        InstanceVault vault = _vault(p.tokenId);
        (uint256 baseOut, uint256 quoteOut) = _exitRange(
            vault,
            range,
            venue.adapter.exitCall(p.nftId, range.liquidity, p.amount0Min, p.amount1Min, address(this), p.deadline)
        );

        uint256 fee = venue.feeExempt ? 0 : _fee(p.tokenId, quoteOut, feeBps);
        if (fee > 0) claimable[treasury][range.quote] += fee;
        if (baseOut > 0) IERC20(range.base).safeTransfer(address(vault), baseOut);
        if (quoteOut > fee) IERC20(range.quote).safeTransfer(address(vault), quoteOut - fee);
        emit RangeClosed(p.tokenId, range.manager, p.nftId, baseOut, quoteOut, fee, p.decision);
    }

    /// O preço atual do pool tem de estar perto do médio. Junto com o próprio
    /// pool — que só aceita depósito de um lado só fora do preço atual —, isso
    /// põe uma ordem de venda acima do preço médio e uma de compra abaixo.
    ///
    /// Vale também para fechar: se o preço estiver fora, a operadora espera;
    /// o dono não fica preso, porque saca o NFT do cofre e retira sozinho.
    function _checkRangePrice(PositionVenue memory venue, address pool) private view {
        if (venue.twapWindow == 0) return;
        (int24 spot, int24 mean) = venue.adapter.ticks(pool, venue.twapWindow);
        int256 gap = int256(spot) - int256(mean);
        if (gap < 0) gap = -gap;
        if (uint256(gap) > venue.maxTickDeviation) revert RangePriceDeviation(spot, mean);
    }

    /// O cofre (dono do NFT) chama o gerenciador; os valores chegam aqui e
    /// são medidos.
    function _exitRange(InstanceVault vault, Range memory range, bytes memory exitData)
        private
        returns (uint256 baseOut, uint256 quoteOut)
    {
        uint256 baseBefore = IERC20(range.base).balanceOf(address(this));
        uint256 quoteBefore = IERC20(range.quote).balanceOf(address(this));
        vault.execute(range.manager, 0, exitData);
        baseOut = IERC20(range.base).balanceOf(address(this)) - baseBefore;
        quoteOut = IERC20(range.quote).balanceOf(address(this)) - quoteBefore;
    }

    // ===== pelo agregador =====

    /// Chave de um par no caminho do agregador. Faz o papel do endereço do
    /// pool: é o que o dono passa a `setMarketAllowed` para liberar o par.
    function pairKey(address base, address quote) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(base, quote)))));
    }

    /// Token base de um mercado, seja ele um pool cadastrado ou um par.
    function _baseOf(address market) private view returns (address) {
        address base = markets[market].base;
        return base != address(0) ? base : pairs[market].base;
    }

    /// Confere o par e registra a chave dele na primeira vez.
    function _usePair(Pair calldata pair) private returns (address key) {
        if (pair.base == address(0) || pair.quote == address(0) || pair.base == pair.quote) revert InvalidPair();
        key = pairKey(pair.base, pair.quote);
        // A chave não pode coincidir com um pool cadastrado: os dois dividem
        // os mapas de posição.
        if (markets[key].base != address(0)) revert InvalidPair();
        if (pairs[key].base == address(0)) pairs[key] = Pair(pair.base, pair.quote);
    }

    /// Entrega `amountIn` de `tokenIn` ao agregador e mede o que voltou.
    ///
    /// O contrato não entende a rota; o que ele garante é o que mede:
    ///  - o agregador só consegue puxar `amountIn` (aprovação exata, zerada
    ///    em seguida) — as taxas guardadas aqui ficam fora do alcance;
    ///  - a entrada inteira foi consumida;
    ///  - a saída chegou neste contrato e é pelo menos `minOut`;
    ///  - havendo pool de referência para o par, a saída respeita o preço
    ///    médio dele, na tolerância daquele mercado.
    function _aggregatorSwap(
        address key,
        Route calldata route,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) private returns (uint256 amountOut) {
        if (!aggregators[route.target]) revert AggregatorNotAllowed(route.target);

        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(route.target, amountIn);
        (bool ok,) = route.target.call(route.data);
        if (!ok) revert AggregatorCallFailed();
        IERC20(tokenIn).forceApprove(route.target, 0);

        // As posições foram dimensionadas pelo valor todo: sobra ou falta de
        // entrada é erro, como no pool direto.
        if (IERC20(tokenIn).balanceOf(address(this)) + amountIn != inBefore) revert SwapNotFilled();

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        address priceSource = referencePool[key];
        if (priceSource != address(0)) {
            Market memory market = markets[priceSource];
            uint256 expected = _quoteAtTwap(priceSource, market.twapWindow, tokenIn, tokenOut, amountIn);
            if (amountOut * BPS < expected * (BPS - market.maxDeviationBps)) {
                revert PriceDeviation(amountOut, expected);
            }
        }
    }

    // ===== taxa e saque =====

    /// A taxa de um valor: zero para instância isenta.
    function _fee(uint256 tokenId, uint256 amount, uint16 feeBps) private view returns (uint256) {
        if (feeBps == 0 || feeExempt[tokenId]) return 0;
        return (amount * feeBps) / BPS;
    }

    /// Saca as taxas acumuladas de quem chama, no token indicado. Quem saca
    /// paga o gas.
    function withdraw(address token) external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();
        claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    // ===== swap e preço =====

    /// Tira `amount` do cofre e devolve o que de fato chegou (tokens com taxa
    /// na transferência entregam menos).
    function _take(InstanceVault vault, address token, uint256 amount) private returns (uint256 received) {
        uint256 before = IERC20(token).balanceOf(address(this));
        vault.transferOut(token, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
    }

    /// Troca `amountIn` de `tokenIn` direto no pool, recebendo aqui. Falar com
    /// o pool sem passar por um router tira um contrato de terceiros do
    /// caminho do dinheiro.
    function _swap(address pool, address tokenIn, address tokenOut, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        bool zeroForOne = tokenIn < tokenOut;
        uint256 before = IERC20(tokenOut).balanceOf(address(this));

        _activePool = pool;
        (int256 amount0, int256 amount1) = IUniswapV3Pool(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                // Sem limite de preço próprio: quem limita é minOut e o TWAP.
                zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
                abi.encode(tokenIn)
            );
        _activePool = address(0);

        // Pool sem liquidez para a ordem inteira consome só parte da entrada.
        // Aqui isso é erro: as posições foram dimensionadas pelo valor todo.
        if (uint256(zeroForOne ? amount0 : amount1) != amountIn) revert SwapNotFilled();
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - before;
    }

    /// Troca e confere o resultado contra o mínimo pedido pela operadora e
    /// contra o preço médio do pool.
    function _swapChecked(
        address pool,
        Market memory market,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) private returns (uint256 amountOut) {
        amountOut = _swap(pool, tokenIn, tokenOut, amountIn);
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        uint256 expected = _quoteAtTwap(pool, market.twapWindow, tokenIn, tokenOut, amountIn);
        if (amountOut * BPS < expected * (BPS - market.maxDeviationBps)) revert PriceDeviation(amountOut, expected);
    }

    /// Chamado pelo pool no meio do swap para receber o token de entrada.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _activePool) revert BadCallback();
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IERC20(tokenIn).safeTransfer(msg.sender, owed);
    }

    /// Quanto de `tokenOut` vale `amountIn` de `tokenIn` ao preço médio da
    /// janela, sem taxa nem impacto de preço. É a referência que impede uma
    /// operadora comprometida de mover o preço num bloco, executar contra o
    /// usuário e desfazer: o preço médio de uma janela não se move com um swap.
    function _quoteAtTwap(address pool, uint32 window, address tokenIn, address tokenOut, uint256 amountIn)
        private
        view
        returns (uint256)
    {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 span = int56(uint56(window));
        int24 meanTick = int24(delta / span);
        // Arredonda para baixo também nos ticks negativos.
        if (delta < 0 && (delta % span != 0)) meanTick--;

        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(meanTick);
        // sqrtRatio² é o preço de token0 em token1, em Q192. Acima de 2^128 o
        // quadrado estoura 256 bits, então reduz a precisão para Q128.
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return tokenIn < tokenOut
                ? FullMath.mulDiv(ratioX192, amountIn, 1 << 192)
                : FullMath.mulDiv(1 << 192, amountIn, ratioX192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return tokenIn < tokenOut
            ? FullMath.mulDiv(ratioX128, amountIn, 1 << 128)
            : FullMath.mulDiv(1 << 128, amountIn, ratioX128);
    }

    function _bubble(bytes memory reason) private pure {
        if (reason.length == 0) revert InvalidRange();
        assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
        }
    }

    // ===== administração =====

    /// Isenta (ou deixa de isentar) uma instância da taxa. A operadora também
    /// pode: isentar só tira receita do protocolo, nunca do usuário, e é o
    /// que o painel de administração faz com os bots da casa e a whitelist.
    function setFeeExempt(uint256 tokenId, bool exempt) external {
        if (msg.sender != owner() && msg.sender != operator) revert NotOperator();
        feeExempt[tokenId] = exempt;
        emit FeeExemptSet(tokenId, exempt);
    }

    /// Cadastra ou altera um mercado. Os tokens são conferidos contra o
    /// próprio pool. Desabilitar impede novas entradas; posições abertas
    /// continuam podendo ser fechadas.
    function setMarket(
        address pool,
        address base,
        address quote,
        bool enabled,
        uint32 twapWindow,
        uint16 maxDeviationBps
    ) external onlyOwner {
        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();
        bool matches = (base == token0 && quote == token1) || (base == token1 && quote == token0);
        if (!matches || twapWindow == 0 || maxDeviationBps > MAX_DEVIATION_BPS) revert InvalidMarket();

        markets[pool] = Market({
            base: base, quote: quote, enabled: enabled, twapWindow: twapWindow, maxDeviationBps: maxDeviationBps
        });
        emit MarketSet(pool, base, quote, enabled, twapWindow, maxDeviationBps);
    }

    /// Cadastra um gerenciador de posições de um fork do Uniswap V3: a
    /// factory dos pools dele e o adaptador que monta as chamadas.
    function setPositionVenue(address manager, PositionVenue calldata venue) external onlyOwner {
        if (manager == address(0) || venue.factory == address(0) || address(venue.adapter) == address(0)) {
            revert ZeroAddress();
        }
        positionVenues[manager] = venue;
        emit PositionVenueSet(
            manager,
            venue.factory,
            address(venue.adapter),
            venue.enabled,
            venue.feeExempt,
            venue.twapWindow,
            venue.maxTickDeviation
        );
    }

    function setOperator(address newOperator) external onlyOwner {
        operator = newOperator;
        emit OperatorSet(newOperator);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    function setVolumeFee(uint16 newVolumeFeeBps) external onlyOwner {
        if (newVolumeFeeBps > MAX_VOLUME_FEE_BPS) revert FeeTooHigh(newVolumeFeeBps, MAX_VOLUME_FEE_BPS);
        volumeFeeBps = newVolumeFeeBps;
        emit VolumeFeeSet(newVolumeFeeBps);
    }

    function setAggregator(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        aggregators[target] = allowed;
        emit AggregatorSet(target, allowed);
    }

    function setQuoteToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        quoteTokens[token] = allowed;
        emit QuoteTokenSet(token, allowed);
    }

    /// Prende os swaps de um par pelo agregador ao preço médio de um pool
    /// cadastrado do mesmo par. `pool = address(0)` remove a referência.
    function setPairReference(address base, address quote, address pool) external onlyOwner {
        if (pool != address(0)) {
            Market memory market = markets[pool];
            if (market.base != base || market.quote != quote) revert InvalidMarket();
        }
        address key = pairKey(base, quote);
        referencePool[key] = pool;
        emit PairReferenceSet(key, pool);
    }

    function setLossPause(uint16 newLossPauseBps) external onlyOwner {
        if (newLossPauseBps > BPS) revert InvalidMarket();
        lossPauseBps = newLossPauseBps;
        emit LossPauseSet(newLossPauseBps);
    }
}
