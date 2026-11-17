// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// Como montar as chamadas ao gerenciador de posições (NFT) de um fork do
/// Uniswap V3. O executor fala com qualquer fork por um destes: o que muda
/// entre forks é como o pool é identificado (taxa ou tick spacing) e, por
/// isso, o `mint`. Retirar a faixa (`decreaseLiquidity`, `collect`, `burn`
/// num `multicall`) é igual em todos.
///
/// Não guarda estado nem fundos. Fork novo = adaptador novo, cadastrado pelo
/// multisig no executor, sem reimplantar o executor.
interface IV3PositionAdapter {
    struct Mint {
        address pool;
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /// Os tokens do pool, conferindo na factory que o pool é dela. Reverte se
    /// não for: é o que impede a operadora de depositar num pool falso.
    function poolTokens(address factory, address pool) external view returns (address token0, address token1);

    /// O tick atual do pool e o tick médio dos últimos `window` segundos. O
    /// executor só mexe numa faixa com os dois perto um do outro: é o que
    /// impede uma operadora comprometida de mover o pool, depositar ou retirar
    /// no preço movido e desfazer.
    function ticks(address pool, uint32 window) external view returns (int24 spot, int24 mean);

    /// O calldata do `mint` no gerenciador.
    function mintCall(Mint calldata params) external view returns (bytes memory);

    /// O calldata que retira a faixa inteira, com a taxa ganha, para
    /// `recipient`, e queima o NFT.
    function exitCall(
        uint256 nftId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        uint256 deadline
    ) external pure returns (bytes memory);
}

interface IV3PoolTokens {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IFeeTierPool is IV3PoolTokens {
    function fee() external view returns (uint24);
}

interface ITickSpacingPool is IV3PoolTokens {
    function tickSpacing() external view returns (int24);
}

interface IFeeTierFactory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface ITickSpacingFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

struct FeeTierMintParams {
    address token0;
    address token1;
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    address recipient;
    uint256 deadline;
}

struct TickSpacingMintParams {
    address token0;
    address token1;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    address recipient;
    uint256 deadline;
}

interface IFeeTierPositionManager {
    function mint(FeeTierMintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface ITickSpacingPositionManager {
    function mint(TickSpacingMintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// As chamadas comuns a todos os forks.
interface IV3PositionManager {
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}

interface IV3Observe {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

abstract contract V3PositionAdapterBase is IV3PositionAdapter {
    error NotFactoryPool(address pool);
    error NoSpotPrice(address pool);

    /// O `slot0` muda de forma entre forks, mas começa sempre por
    /// `(sqrtPriceX96, tick)`: só essas duas palavras são lidas.
    function ticks(address pool, uint32 window) external view returns (int24 spot, int24 mean) {
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!ok || data.length < 64) revert NoSpotPrice(pool);
        int256 tick;
        assembly ("memory-safe") {
            tick := mload(add(data, 64))
        }
        spot = int24(tick);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        (int56[] memory cumulatives,) = IV3Observe(pool).observe(secondsAgos);
        int56 delta = cumulatives[1] - cumulatives[0];
        int56 span = int56(uint56(window));
        mean = int24(delta / span);
        // Arredonda para baixo também nos ticks negativos.
        if (delta < 0 && (delta % span != 0)) mean--;
    }

    function exitCall(
        uint256 nftId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        uint256 deadline
    ) external pure returns (bytes memory) {
        bytes[] memory steps = new bytes[](3);
        steps[0] = abi.encodeCall(
            IV3PositionManager.decreaseLiquidity,
            (IV3PositionManager.DecreaseLiquidityParams(nftId, liquidity, amount0Min, amount1Min, deadline))
        );
        steps[1] = abi.encodeCall(
            IV3PositionManager.collect,
            (IV3PositionManager.CollectParams(nftId, recipient, type(uint128).max, type(uint128).max))
        );
        steps[2] = abi.encodeCall(IV3PositionManager.burn, (nftId));
        return abi.encodeCall(IV3PositionManager.multicall, (steps));
    }
}

/// Uniswap V3 e os forks que identificam o pool pela taxa (`fee`, uint24).
contract FeeTierAdapter is V3PositionAdapterBase {
    function poolTokens(address factory, address pool) external view returns (address token0, address token1) {
        token0 = IFeeTierPool(pool).token0();
        token1 = IFeeTierPool(pool).token1();
        if (IFeeTierFactory(factory).getPool(token0, token1, IFeeTierPool(pool).fee()) != pool) {
            revert NotFactoryPool(pool);
        }
    }

    function mintCall(Mint calldata p) external view returns (bytes memory) {
        return abi.encodeCall(
            IFeeTierPositionManager.mint,
            (FeeTierMintParams(
                    p.token0,
                    p.token1,
                    IFeeTierPool(p.pool).fee(),
                    p.tickLower,
                    p.tickUpper,
                    p.amount0Desired,
                    p.amount1Desired,
                    p.amount0Min,
                    p.amount1Min,
                    p.recipient,
                    p.deadline
                ))
        );
    }
}

/// Forks que identificam o pool pelo tick spacing (`int24`), como a Ramses V3.
contract TickSpacingAdapter is V3PositionAdapterBase {
    function poolTokens(address factory, address pool) external view returns (address token0, address token1) {
        token0 = ITickSpacingPool(pool).token0();
        token1 = ITickSpacingPool(pool).token1();
        if (ITickSpacingFactory(factory).getPool(token0, token1, ITickSpacingPool(pool).tickSpacing()) != pool) {
            revert NotFactoryPool(pool);
        }
    }

    function mintCall(Mint calldata p) external view returns (bytes memory) {
        return abi.encodeCall(
            ITickSpacingPositionManager.mint,
            (TickSpacingMintParams(
                    p.token0,
                    p.token1,
                    ITickSpacingPool(p.pool).tickSpacing(),
                    p.tickLower,
                    p.tickUpper,
                    p.amount0Desired,
                    p.amount1Desired,
                    p.amount0Min,
                    p.amount1Min,
                    p.recipient,
                    p.deadline
                ))
        );
    }
}
