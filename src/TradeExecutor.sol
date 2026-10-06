// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {ITransferGuard} from "./BotInstanceNFT.sol";

/// Executa os trades das instâncias.
///
/// Modelo de custódia: os fundos ficam na carteira do dono do NFT, que dá
/// allowance do token de cotação e de cada ativo a este contrato. Para abrir,
/// o contrato puxa a cotação do dono, troca no pool e devolve o ativo ao dono.
/// Para fechar, puxa o ativo, troca, desconta as taxas e devolve a cotação.
/// Entre uma chamada e outra o contrato só guarda as taxas ainda não sacadas.
///
/// Só a carteira operadora inicia trades. O que uma operadora comprometida
/// consegue fazer é limitado aqui, não no backend:
///  - o resultado de um trade só vai para o dono da instância;
///  - só mercados cadastrados pelo multisig e liberados pelo dono;
///  - valor por trade limitado pelo dono, que também pode pausar;
///  - preço executado preso ao preço médio do pool (TWAP), dentro de uma
///    tolerância por mercado.
///
/// Há dois caminhos de execução. No pool direto, este contrato fala com um
/// pool do Uniswap v3 cadastrado. Pelo agregador, ele entrega a entrada a um
/// contrato de roteamento aprovado pelo multisig, com a rota montada fora da
/// chain, e só confere quanto voltou — é o que permite negociar tokens sem
/// pool cadastrado. Nesse caminho a trava de preço médio só existe para os
/// pares que têm um pool de referência; para os demais valem o mínimo pedido
/// pela operadora, os limites do dono e a pausa automática por perda (ver
/// `lossPauseBps`), que limita o dano de uma operadora comprometida a um
/// trade por par liberado.
///
/// Não é atualizável: um contrato com allowance de usuários não deve poder
/// mudar de código. Versão nova = contrato novo e novo approve.
contract TradeExecutor is Ownable2Step, ReentrancyGuard, ITransferGuard, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// Teto da soma das taxas de lucro (protocolo + líder).
    uint256 public constant MAX_TOTAL_FEE_BPS = 3_000;
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
    }

    struct Position {
        /// Ativo comprado, na carteira do dono.
        uint256 base;
        /// Cotação gasta para comprar.
        uint256 cost;
    }

    /// Resultado acumulado de uma instância num token de cotação. A taxa de
    /// lucro só incide sobre o que passa do pico.
    struct Pnl {
        int256 cumulative;
        int256 highWaterMark;
    }

    /// Instância que esta segue, e a taxa do líder vigente quando começou a
    /// seguir — mudança posterior da taxa não alcança quem já seguia.
    struct Follow {
        uint256 leader;
        uint16 feeBps;
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

    IERC721 public immutable nft;

    address public operator;
    address public treasury;
    /// Taxa do protocolo sobre o lucro acima do pico.
    uint16 public profitFeeBps;
    /// Taxa do líder de copy trade sobre o lucro acima do pico do seguidor.
    uint16 public leaderFeeBps;

    mapping(address pool => Market) public markets;
    mapping(uint256 tokenId => Limits) public limits;
    mapping(uint256 tokenId => mapping(address pool => bool)) public marketAllowed;
    mapping(uint256 tokenId => mapping(address pool => Position)) public positions;
    mapping(uint256 tokenId => uint256) public openCount;
    mapping(uint256 tokenId => mapping(address quote => Pnl)) public pnl;
    mapping(uint256 tokenId => Follow) public following;

    /// Pontos do lucro repassados a cada parceiro, saídos da taxa do
    /// protocolo. Endereço fora do mapa não recebe nada.
    mapping(address partner => uint16) public partnerProfitShareBps;
    /// Taxas acumuladas e ainda não sacadas, por beneficiário e por token.
    mapping(address account => mapping(address token => uint256)) public claimable;

    /// Contratos de roteamento que podem receber a entrada de um swap.
    mapping(address target => bool) public aggregators;
    /// Tokens aceitos como cotação no caminho do agregador. As taxas e o
    /// resultado acumulado são contados no token de cotação.
    mapping(address token => bool) public quoteTokens;
    /// Par de cada chave já usada.
    mapping(address key => Pair) public pairs;
    /// Pool cadastrado cujo preço médio também limita os swaps do par pelo
    /// agregador. `address(0)` = par sem referência de preço.
    mapping(address key => address) public referencePool;
    /// Perda num único trade, em pontos-base do custo, a partir da qual a
    /// instância é pausada sozinha. 0 = desligado.
    uint16 public lossPauseBps;

    /// Pool com swap em andamento; só ele pode chamar o callback.
    address private _activePool;

    event PositionOpened(uint256 indexed tokenId, address indexed pool, uint256 quoteIn, uint256 baseOut);
    event PositionClosed(
        uint256 indexed tokenId,
        address indexed pool,
        uint256 baseIn,
        uint256 quoteOut,
        int256 pnl,
        uint256 protocolFee,
        uint256 partnerFee,
        uint256 leaderFee,
        address feeRecipient
    );
    event PositionAbandoned(uint256 indexed tokenId, address indexed pool, uint256 base, uint256 cost);
    event LimitsSet(uint256 indexed tokenId, uint256 maxPerTrade, bool paused);
    event MarketAllowedSet(uint256 indexed tokenId, address indexed pool, bool allowed);
    event Followed(uint256 indexed tokenId, uint256 indexed leader, uint16 feeBps);
    event Unfollowed(uint256 indexed tokenId);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);
    event MarketSet(
        address indexed pool, address base, address quote, bool enabled, uint32 twapWindow, uint16 maxDeviationBps
    );
    event OperatorSet(address operator);
    event TreasurySet(address treasury);
    event FeesSet(uint16 profitFeeBps, uint16 leaderFeeBps);
    event PartnerProfitShareSet(address indexed partner, uint16 shareBps);
    event AggregatorSet(address indexed target, bool allowed);
    event QuoteTokenSet(address indexed token, bool allowed);
    event PairReferenceSet(address indexed key, address indexed pool);
    event LossPauseSet(uint16 lossPauseBps);
    event InstanceAutoPaused(uint256 indexed tokenId, address indexed market, uint256 cost, uint256 proceeds);

    error NotOperator();
    error NotInstanceOwner(uint256 tokenId);
    error Expired();
    error LengthMismatch();
    error EmptyBatch();
    error MarketDisabled(address pool);
    error MarketNotAllowed(uint256 tokenId, address pool);
    error InstancePaused(uint256 tokenId);
    error OverTradeLimit(uint256 tokenId, uint256 amount, uint256 maxPerTrade);
    error ZeroAmount();
    error PositionExists(uint256 tokenId, address pool);
    error NoPosition(uint256 tokenId, address pool);
    error InsufficientOutput(uint256 out, uint256 minOut);
    error PriceDeviation(uint256 out, uint256 expectedAtTwap);
    error SwapNotFilled();
    error BadCallback();
    error InvalidMarket();
    error InvalidFees();
    error ZeroAddress();
    error NothingToWithdraw();
    error HasOpenPositions(uint256 tokenId);
    error InvalidLeader(uint256 leader);
    error PositionStillClosable(uint256 tokenId, address pool);
    error AggregatorNotAllowed(address target);
    error QuoteTokenNotAllowed(address token);
    error InvalidPair();
    error AggregatorCallFailed();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    modifier onlyInstanceOwner(uint256 tokenId) {
        if (nft.ownerOf(tokenId) != msg.sender) revert NotInstanceOwner(tokenId);
        _;
    }

    constructor(
        address initialOwner,
        IERC721 nft_,
        address operator_,
        address treasury_,
        uint16 profitFeeBps_,
        uint16 leaderFeeBps_
    ) Ownable(initialOwner) {
        if (address(nft_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (uint256(profitFeeBps_) + leaderFeeBps_ > MAX_TOTAL_FEE_BPS) revert InvalidFees();
        nft = nft_;
        operator = operator_;
        treasury = treasury_;
        profitFeeBps = profitFeeBps_;
        leaderFeeBps = leaderFeeBps_;

        emit OperatorSet(operator_);
        emit TreasurySet(treasury_);
        emit FeesSet(profitFeeBps_, leaderFeeBps_);
    }

    // ===== trava de transferência do NFT =====

    function isLocked(uint256 tokenId) external view returns (bool) {
        return openCount[tokenId] > 0;
    }

    // ===== dono da instância =====

    function setLimits(uint256 tokenId, uint256 maxPerTrade, bool paused) external onlyInstanceOwner(tokenId) {
        limits[tokenId] = Limits({maxPerTrade: maxPerTrade, paused: paused});
        emit LimitsSet(tokenId, maxPerTrade, paused);
    }

    function setMarketAllowed(uint256 tokenId, address pool, bool allowed) external onlyInstanceOwner(tokenId) {
        marketAllowed[tokenId][pool] = allowed;
        emit MarketAllowedSet(tokenId, pool, allowed);
    }

    /// Passa a seguir um líder: a instância entra nos trades em lote dele e
    /// paga a taxa de líder sobre o próprio lucro. Só sem posição aberta —
    /// senão daria para trocar de líder (ou deixar de seguir) entre a compra
    /// e a venda e escapar da taxa.
    function follow(uint256 tokenId, uint256 leader) external onlyInstanceOwner(tokenId) {
        if (openCount[tokenId] > 0) revert HasOpenPositions(tokenId);
        if (leader == tokenId || leader == 0) revert InvalidLeader(leader);
        // ownerOf reverte se o líder não existe.
        nft.ownerOf(leader);

        uint16 feeBps = leaderFeeBps;
        following[tokenId] = Follow({leader: leader, feeBps: feeBps});
        emit Followed(tokenId, leader, feeBps);
    }

    function unfollow(uint256 tokenId) external onlyInstanceOwner(tokenId) {
        if (openCount[tokenId] > 0) revert HasOpenPositions(tokenId);
        delete following[tokenId];
        emit Unfollowed(tokenId);
    }

    /// Descarta o registro de uma posição sem vender: o ativo já está na
    /// carteira do dono, que passa a cuidar dele por conta própria. Não gera
    /// taxa nem mexe no resultado acumulado.
    ///
    /// O dono pode chamar sempre. A operadora só quando o fechamento normal é
    /// impossível (o dono moveu o ativo ou tirou o allowance) — do contrário
    /// ela poderia apagar posições lucrativas para o protocolo não cobrar.
    function abandonPosition(uint256 tokenId, address pool) external {
        Position memory position = positions[tokenId][pool];
        if (position.base == 0) revert NoPosition(tokenId, pool);

        address instanceOwner = nft.ownerOf(tokenId);
        if (msg.sender != instanceOwner) {
            if (msg.sender != operator) revert NotInstanceOwner(tokenId);
            IERC20 base = IERC20(_baseOf(pool));
            bool closable = base.balanceOf(instanceOwner) >= position.base
                && base.allowance(instanceOwner, address(this)) >= position.base;
            if (closable) revert PositionStillClosable(tokenId, pool);
        }

        delete positions[tokenId][pool];
        openCount[tokenId]--;
        emit PositionAbandoned(tokenId, pool, position.base, position.cost);
    }

    // ===== operadora: abrir =====

    /// Um swap em lote: o que entrou no pool e o que saiu, a dividir entre as
    /// instâncias na proporção do que cada uma pôs.
    struct Batch {
        address pool;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
    }

    /// Abre posição para uma ou mais instâncias no mesmo swap. Com várias, é
    /// o copy trade: líder e seguidores entram ao mesmo preço médio, e o
    /// ativo comprado é dividido na proporção do que cada um pôs.
    function openPositions(
        uint256[] calldata tokenIds,
        address pool,
        uint256[] calldata quoteIns,
        uint256 minBaseOut,
        uint256 deadline
    ) external onlyOperator nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        if (tokenIds.length == 0) revert EmptyBatch();
        if (quoteIns.length != tokenIds.length) revert LengthMismatch();

        Market memory market = markets[pool];
        if (!market.enabled) revert MarketDisabled(pool);

        Batch memory batch = Batch(pool, market.base, 0, 0);
        address[] memory owners;
        uint256[] memory paid;
        (owners, paid, batch.amountIn) = _pullQuotes(tokenIds, pool, quoteIns, market.quote);
        batch.amountOut = _swapChecked(pool, market, market.quote, market.base, batch.amountIn, minBaseOut);

        _recordPositions(tokenIds, owners, paid, batch);
    }

    /// Confere os limites de cada instância e puxa a cotação de cada dono.
    function _pullQuotes(uint256[] calldata tokenIds, address pool, uint256[] calldata quoteIns, address quote)
        private
        returns (address[] memory owners, uint256[] memory paid, uint256 totalIn)
    {
        uint256 count = tokenIds.length;
        owners = new address[](count);
        paid = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            _checkCanOpen(tokenId, pool, quoteIns[i]);
            owners[i] = nft.ownerOf(tokenId);
            paid[i] = _pull(quote, owners[i], quoteIns[i]);
            totalIn += paid[i];
        }
    }

    /// Divide o ativo comprado, envia a cada dono e registra a posição.
    function _recordPositions(
        uint256[] calldata tokenIds,
        address[] memory owners,
        uint256[] memory paid,
        Batch memory batch
    ) private {
        uint256 count = tokenIds.length;
        uint256 distributed;
        for (uint256 i = 0; i < count; i++) {
            // O último fica com o resto do arredondamento.
            uint256 share = i == count - 1
                ? batch.amountOut - distributed
                : FullMath.mulDiv(batch.amountOut, paid[i], batch.amountIn);
            distributed += share;
            // Posição com zero de ativo não é posição: ficaria contada como
            // aberta sem poder ser fechada nem abandonada, travando o NFT.
            if (share == 0) revert ZeroAmount();

            uint256 tokenId = tokenIds[i];
            positions[tokenId][batch.pool] = Position({base: share, cost: paid[i]});
            openCount[tokenId]++;
            IERC20(batch.tokenOut).safeTransfer(owners[i], share);
            emit PositionOpened(tokenId, batch.pool, paid[i], share);
        }
    }

    function _checkCanOpen(uint256 tokenId, address pool, uint256 quoteIn) private view {
        Limits memory limit = limits[tokenId];
        if (limit.paused) revert InstancePaused(tokenId);
        if (!marketAllowed[tokenId][pool]) revert MarketNotAllowed(tokenId, pool);
        if (quoteIn == 0) revert ZeroAmount();
        if (quoteIn > limit.maxPerTrade) revert OverTradeLimit(tokenId, quoteIn, limit.maxPerTrade);
        if (positions[tokenId][pool].base != 0) revert PositionExists(tokenId, pool);
    }

    // ===== operadora: fechar =====

    /// Fecha a posição de uma ou mais instâncias no mesmo swap. A cotação
    /// recebida é dividida na proporção do ativo de cada uma; de cada parte
    /// saem as taxas de lucro, e o resto volta para o dono.
    ///
    /// Fechar não olha pausa nem limites: são travas para entrar, e um stop
    /// precisa conseguir sair sempre.
    ///
    /// `feeRecipients[i]` é o parceiro da instância `i` (`address(0)` = sem
    /// parceiro).
    function closePositions(
        uint256[] calldata tokenIds,
        address pool,
        address[] calldata feeRecipients,
        uint256 minQuoteOut,
        uint256 deadline
    ) external onlyOperator nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        if (tokenIds.length == 0) revert EmptyBatch();
        if (feeRecipients.length != tokenIds.length) revert LengthMismatch();

        // Vale para mercado desabilitado também: desabilitar impede entradas,
        // não pode prender quem já está posicionado.
        Market memory market = markets[pool];
        if (market.base == address(0)) revert InvalidMarket();

        Batch memory batch = Batch(pool, market.quote, 0, 0);
        address[] memory owners;
        uint256[] memory sold;
        (owners, sold, batch.amountIn) = _pullPositions(tokenIds, pool, market.base);
        batch.amountOut = _swapChecked(pool, market, market.base, market.quote, batch.amountIn, minQuoteOut);

        _settleAll(tokenIds, feeRecipients, owners, sold, batch);
    }

    /// Puxa de cada dono o ativo da posição dele.
    function _pullPositions(uint256[] calldata tokenIds, address pool, address base)
        private
        returns (address[] memory owners, uint256[] memory sold, uint256 totalBase)
    {
        uint256 count = tokenIds.length;
        owners = new address[](count);
        sold = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 amount = positions[tokenId][pool].base;
            if (amount == 0) revert NoPosition(tokenId, pool);
            owners[i] = nft.ownerOf(tokenId);
            sold[i] = _pull(base, owners[i], amount);
            totalBase += sold[i];
        }
    }

    function _settleAll(
        uint256[] calldata tokenIds,
        address[] calldata feeRecipients,
        address[] memory owners,
        uint256[] memory sold,
        Batch memory batch
    ) private {
        uint256 count = tokenIds.length;
        uint256 distributed;
        for (uint256 i = 0; i < count; i++) {
            // O último fica com o resto do arredondamento.
            uint256 share = i == count - 1
                ? batch.amountOut - distributed
                : FullMath.mulDiv(batch.amountOut, sold[i], batch.amountIn);
            distributed += share;
            _settle(Settlement(tokenIds[i], batch.pool, batch.tokenOut, owners[i], sold[i], share, feeRecipients[i]));
        }
    }

    /// A parte de uma instância num fechamento.
    struct Settlement {
        uint256 tokenId;
        address pool;
        address quote;
        address instanceOwner;
        uint256 baseSold;
        uint256 proceeds;
        address feeRecipient;
    }

    /// Encerra a posição de uma instância: separa as taxas sobre o lucro que
    /// passou do pico e devolve o resto ao dono.
    function _settle(Settlement memory s) private {
        uint256 cost = positions[s.tokenId][s.pool].cost;
        delete positions[s.tokenId][s.pool];
        openCount[s.tokenId]--;

        int256 tradePnl = int256(s.proceeds) - int256(cost);
        (uint256 protocolFee, uint256 partnerFee, uint256 leaderFee) = _fees(s, tradePnl);

        // Perder quase tudo num trade só não é resultado de estratégia: ou o
        // mercado quebrou, ou alguém está executando contra o dono. A
        // instância para de abrir posição até o dono olhar e reativar.
        if (lossPauseBps != 0 && s.proceeds * BPS < cost * (BPS - lossPauseBps)) {
            limits[s.tokenId].paused = true;
            emit InstanceAutoPaused(s.tokenId, s.pool, cost, s.proceeds);
        }

        if (partnerFee > 0) claimable[s.feeRecipient][s.quote] += partnerFee;
        if (protocolFee > partnerFee) claimable[treasury][s.quote] += protocolFee - partnerFee;
        if (leaderFee > 0) claimable[_leaderBeneficiary(following[s.tokenId].leader)][s.quote] += leaderFee;

        IERC20(s.quote).safeTransfer(s.instanceOwner, s.proceeds - protocolFee - leaderFee);

        emit PositionClosed(
            s.tokenId,
            s.pool,
            s.baseSold,
            s.proceeds,
            tradePnl,
            protocolFee - partnerFee,
            partnerFee,
            leaderFee,
            s.feeRecipient
        );
    }

    /// Atualiza o resultado acumulado e calcula as taxas sobre o lucro novo.
    /// `protocolFee` inclui a fatia do parceiro.
    function _fees(Settlement memory s, int256 tradePnl)
        private
        returns (uint256 protocolFee, uint256 partnerFee, uint256 leaderFee)
    {
        Pnl storage result = pnl[s.tokenId][s.quote];
        result.cumulative += tradePnl;
        if (result.cumulative <= result.highWaterMark) return (0, 0, 0);

        // Lucro novo: só o que passou do melhor resultado anterior. Nunca é
        // maior que o lucro deste trade, então as taxas cabem no valor
        // recebido.
        uint256 profit = uint256(result.cumulative - result.highWaterMark);
        result.highWaterMark = result.cumulative;

        protocolFee = (profit * profitFeeBps) / BPS;
        if (s.feeRecipient != address(0)) {
            partnerFee = (profit * partnerProfitShareBps[s.feeRecipient]) / BPS;
            // A fatia do parceiro sai da taxa do protocolo; se a taxa foi
            // reduzida depois, o parceiro não leva mais do que ela.
            if (partnerFee > protocolFee) partnerFee = protocolFee;
        }

        Follow memory followed = following[s.tokenId];
        if (followed.leader != 0) leaderFee = (profit * followed.feeBps) / BPS;
    }

    /// Quem recebe a taxa de líder: o dono atual do NFT líder. Se o NFT não
    /// existir mais, a taxa fica com a tesouraria em vez de travar o
    /// fechamento do seguidor.
    function _leaderBeneficiary(uint256 leader) private view returns (address) {
        try nft.ownerOf(leader) returns (address leaderOwner) {
            return leaderOwner;
        } catch {
            return treasury;
        }
    }

    // ===== operadora: pelo agregador =====

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

    /// Abre posição para uma ou mais instâncias trocando pelo agregador.
    /// Mesmas travas de entrada do pool direto (pausa, mercado liberado pelo
    /// dono, limite por trade); a diferença é de onde vem o preço.
    function openViaAggregator(
        uint256[] calldata tokenIds,
        Pair calldata pair,
        uint256[] calldata quoteIns,
        uint256 minBaseOut,
        uint256 deadline,
        Route calldata route
    ) external onlyOperator nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        if (tokenIds.length == 0) revert EmptyBatch();
        if (quoteIns.length != tokenIds.length) revert LengthMismatch();
        if (!quoteTokens[pair.quote]) revert QuoteTokenNotAllowed(pair.quote);

        address key = _usePair(pair);
        Batch memory batch = Batch(key, pair.base, 0, 0);
        address[] memory owners;
        uint256[] memory paid;
        (owners, paid, batch.amountIn) = _pullQuotes(tokenIds, key, quoteIns, pair.quote);
        batch.amountOut = _aggregatorSwap(key, route, pair.quote, pair.base, batch.amountIn, minBaseOut);

        _recordPositions(tokenIds, owners, paid, batch);
    }

    /// Fecha a posição de uma ou mais instâncias trocando pelo agregador. Como
    /// no pool direto, fechar não olha pausa, limites nem a lista de tokens de
    /// cotação: quem está posicionado precisa conseguir sair.
    function closeViaAggregator(
        uint256[] calldata tokenIds,
        Pair calldata pair,
        address[] calldata feeRecipients,
        uint256 minQuoteOut,
        uint256 deadline,
        Route calldata route
    ) external onlyOperator nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        if (tokenIds.length == 0) revert EmptyBatch();
        if (feeRecipients.length != tokenIds.length) revert LengthMismatch();

        address key = pairKey(pair.base, pair.quote);
        if (pairs[key].base == address(0)) revert InvalidPair();

        Batch memory batch = Batch(key, pair.quote, 0, 0);
        address[] memory owners;
        uint256[] memory sold;
        (owners, sold, batch.amountIn) = _pullPositions(tokenIds, key, pair.base);
        batch.amountOut = _aggregatorSwap(key, route, pair.base, pair.quote, batch.amountIn, minQuoteOut);

        _settleAll(tokenIds, feeRecipients, owners, sold, batch);
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

    // ===== saque =====

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

    /// Puxa `amount` de `from` e devolve o que de fato chegou.
    function _pull(address token, address from, uint256 amount) private returns (uint256 received) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
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

    // ===== administração (multisig) =====

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

    function setOperator(address newOperator) external onlyOwner {
        operator = newOperator;
        emit OperatorSet(newOperator);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    /// A taxa de líder nova só vale para quem começar a seguir depois.
    function setFees(uint16 newProfitFeeBps, uint16 newLeaderFeeBps) external onlyOwner {
        if (uint256(newProfitFeeBps) + newLeaderFeeBps > MAX_TOTAL_FEE_BPS) revert InvalidFees();
        profitFeeBps = newProfitFeeBps;
        leaderFeeBps = newLeaderFeeBps;
        emit FeesSet(newProfitFeeBps, newLeaderFeeBps);
    }

    function setPartnerProfitShare(address partner, uint16 shareBps) external onlyOwner {
        if (partner == address(0)) revert ZeroAddress();
        if (shareBps > profitFeeBps) revert InvalidFees();
        partnerProfitShareBps[partner] = shareBps;
        emit PartnerProfitShareSet(partner, shareBps);
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
        if (newLossPauseBps > BPS) revert InvalidFees();
        lossPauseBps = newLossPauseBps;
        emit LossPauseSet(newLossPauseBps);
    }
}
