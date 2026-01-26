// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './FullMath.sol';
import './SqrtPriceMath.sol';

/// @title 计算单个 tick 范围内的 swap 结果
/// @notice 在单个价格区间（两个相邻已初始化 tick 之间）内计算 swap 的输入输出
/// 
/// ==================== 核心概念 ====================
/// 
/// 1. 这个函数处理的是"单步"swap，即在当前流动性不变的情况下能完成多少交换
/// 2. 每次 swap 可能需要多次调用此函数（跨越多个 tick）
/// 3. 价格变动方向由 current 和 target 的大小关系决定
///
/// ==================== 两种 swap 模式 ====================
/// 
/// exactIn (amountRemaining >= 0):
///   - 用户指定输入金额，计算能得到多少输出
///   - 例如："我要卖 100 USDC，能得到多少 ETH？"
///
/// exactOut (amountRemaining < 0):
///   - 用户指定输出金额，计算需要多少输入
///   - 例如："我要买 1 ETH，需要多少 USDC？"
///
/// ==================== 两种交易方向 ====================
///
/// zeroForOne = true (token0 -> token1):
///   - 卖出 token0，买入 token1
///   - 价格下降（sqrtPrice 变小）
///   - 例如：ETH/USDC 池中卖 ETH 换 USDC
///
/// zeroForOne = false (token1 -> token0):
///   - 卖出 token1，买入 token0  
///   - 价格上升（sqrtPrice 变大）
///   - 例如：ETH/USDC 池中用 USDC 买 ETH
///
library SwapMath {
    /// @notice 计算单步 swap 的结果
    /// @dev 手续费 + 实际输入量 永远不会超过 amountRemaining（当 exactIn 时）
    /// 
    /// @param sqrtRatioCurrentX96 当前价格的平方根（Q64.96 格式）
    /// @param sqrtRatioTargetX96 目标价格的平方根（不能超过此价格，通常是下一个已初始化 tick 的价格）
    /// @param liquidity 当前可用流动性（在此价格区间内的 LP 提供的流动性总和）
    /// @param amountRemaining 剩余待交换金额：
    ///                        - >= 0: exactIn 模式，表示剩余输入量
    ///                        - < 0:  exactOut 模式，表示剩余输出量（负数）
    /// @param feePips 手续费率，以百万分之一为单位（如 3000 = 0.3%）
    /// 
    /// @return sqrtRatioNextX96 swap 后的新价格，不会超过 sqrtRatioTargetX96
    /// @return amountIn 本次 step 实际输入的 token 数量
    /// @return amountOut 本次 step 实际输出的 token 数量
    /// @return feeAmount 本次 step 收取的手续费
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    )
        internal
        pure
        returns (
            uint160 sqrtRatioNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        // ==================== Step 1: 确定交易方向和模式 ====================
        
        // 通过比较当前价格和目标价格确定方向
        // current >= target 说明价格要下降，即 zeroForOne
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        
        // amountRemaining >= 0 表示 exactIn 模式（指定输入）
        bool exactIn = amountRemaining >= 0;

        // ==================== Step 2: 计算能否到达目标价格 ====================

        if (exactIn) {
            // === exactIn 模式：已知输入，求输出 ===
            
            // 2.1 扣除手续费后的可用输入量
            // 例如：输入 1000，费率 0.3%，可用 = 1000 * (1e6 - 3000) / 1e6 = 997
            uint256 amountRemainingLessFee = FullMath.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);
            
            // 2.2 计算从当前价格到目标价格需要多少输入
            // getAmount0Delta: 计算价格变动需要的 token0 数量
            // getAmount1Delta: 计算价格变动需要的 token1 数量
            // roundUp=true: 向上取整，确保输入足够
            amountIn = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            
            // 2.3 判断能否到达目标价格
            if (amountRemainingLessFee >= amountIn) {
                // 输入足够，可以到达目标价格
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                // 输入不够，根据实际输入量计算能到达的价格
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
            }
        } else {
            // === exactOut 模式：已知输出，求输入 ===
            
            // 2.1 计算从当前价格到目标价格能产生多少输出
            // roundUp=false: 向下取整，保守估计输出
            amountOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            
            // 2.2 判断能否满足输出需求
            // 注意：amountRemaining 是负数，所以用 -amountRemaining 得到正数
            if (uint256(-amountRemaining) >= amountOut) {
                // 目标价格范围内的输出足够，到达目标价格
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                // 需要的输出量小于该范围能提供的，根据输出量反推价格
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    uint256(-amountRemaining),
                    zeroForOne
                );
            }
        }

        // ==================== Step 3: 计算精确的输入输出量 ====================

        // max = true 表示到达了目标价格（即跨越了整个 tick 区间）
        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96;

        // 根据实际到达的价格重新计算输入输出
        // 这是因为 Step 2 中计算的 amountIn/amountOut 是针对目标价格的
        // 如果没到达目标价格，需要根据实际价格重新计算
        if (zeroForOne) {
            // zeroForOne: 输入 token0，输出 token1
            amountIn = max && exactIn
                ? amountIn  // 已经计算过了，复用
                // amountIn 和 amountRemainingLessFee 由于精度问题，可能不完全相等，所以需要重新精确计算
                // 没有到达目标价格，根据实际价格重新计算输入量，向上取整，确保输入足够
                : SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut  // 已经计算过了，复用
                : SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            // oneForZero: 输入 token1，输出 token0
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }

        // ==================== Step 4: 边界处理 ====================

        // exactOut 模式下，确保输出不超过用户需求
        // 由于精度问题，计算出的 amountOut 可能略大于需求
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }

        // ==================== Step 5: 计算手续费 ====================

        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // exactIn 模式下，如果没有到达目标价格
            // 说明剩余输入量全部被消耗（部分作为实际输入，剩余作为手续费）
            // amountIn ~= amountRemainingLessFee
            // fee = 总输入 - 实际用于交换的输入
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            // 正常情况：根据实际输入量计算手续费
            // fee = amountIn * feePips / (1e6 - feePips)
            // 例如：amountIn=997, feePips=3000
            // fee = 997 * 3000 / 997000 ≈ 3
            // 总输入 = 997 + 3 = 1000
            feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }
}
