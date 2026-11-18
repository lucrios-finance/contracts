// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {InstanceVault} from "./InstanceVault.sol";
import {IV3PositionAdapter} from "./V3PositionAdapters.sol";
import {TradeExecutor} from "./TradeExecutor.sol";

/// O depósito de uma faixa nova no gerenciador de posições.
///
/// Biblioteca com função pública: é implantada à parte e o `TradeExecutor` a
/// chama por `delegatecall`, para o código não contar no limite de 24 KB
/// dele (EIP-170). Roda como o executor: é ele quem tira do cofre, aprova o
/// gerenciador e devolve a sobra. Não guarda estado.
library RangeMint {
    using SafeERC20 for IERC20;

    /// Mesmos seletores dos erros do executor.
    error RangeNotInVault(uint256 nftId);
    error InvalidRange();

    /// O que o gerenciador devolveu do `mint`.
    struct Minted {
        uint256 nftId;
        uint128 liquidity;
        uint256 used0;
        uint256 used1;
    }

    /// Tira os valores do cofre, deposita no gerenciador com o cofre como
    /// dono do NFT e devolve ao cofre o que não entrou.
    function mint(
        IV3PositionAdapter adapter,
        TradeExecutor.RangeOpen calldata p,
        InstanceVault vault,
        address token0,
        address token1
    ) public returns (Minted memory m) {
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
        if (!ok) {
            // Repassa o motivo do gerenciador.
            if (result.length == 0) revert InvalidRange();
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        (m.nftId, m.liquidity, m.used0, m.used1) = abi.decode(result, (uint256, uint128, uint256, uint256));

        IERC20(token0).forceApprove(p.manager, 0);
        IERC20(token1).forceApprove(p.manager, 0);
        if (IERC721(p.manager).ownerOf(m.nftId) != address(vault)) revert RangeNotInVault(m.nftId);
        if (in0 > m.used0) IERC20(token0).safeTransfer(address(vault), in0 - m.used0);
        if (in1 > m.used1) IERC20(token1).safeTransfer(address(vault), in1 - m.used1);
    }

    /// Tira do cofre e devolve o que de fato chegou (token com taxa na
    /// transferência entrega menos).
    function _take(InstanceVault vault, address token, uint256 amount) private returns (uint256 received) {
        uint256 before = IERC20(token).balanceOf(address(this));
        vault.transferOut(token, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
    }
}
