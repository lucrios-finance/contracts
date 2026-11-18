// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

/// O preço médio de um pool v3 e a conta de quanto um valor vale nele.
///
/// Biblioteca com funções públicas: é implantada à parte e o executor a chama
/// por `delegatecall`. Fica fora do bytecode dele, que passaria do limite de
/// 24 KB (EIP-170). Não guarda estado.
library TwapPrice {
    /// Quanto de `tokenOut` vale `amountIn` de `tokenIn` ao preço médio da
    /// janela, sem taxa nem impacto de preço. É a referência que impede uma
    /// operadora comprometida de mover o preço num bloco, executar contra o
    /// usuário e desfazer: o preço médio de uma janela não se move com um swap.
    function quoteAtTwap(address pool, uint32 window, address tokenIn, address tokenOut, uint256 amountIn)
        public
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
        return quoteAtTick(meanTick, tokenIn, tokenOut, amountIn);
    }

    /// Quanto de `tokenOut` vale `amountIn` de `tokenIn` no preço do tick.
    function quoteAtTick(int24 tick, address tokenIn, address tokenOut, uint256 amountIn)
        public
        pure
        returns (uint256)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
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
}
