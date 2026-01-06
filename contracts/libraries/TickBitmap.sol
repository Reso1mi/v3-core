// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './BitMath.sol';

/// @title Packed tick initialized state library
/// @notice Stores a packed mapping of tick index to its initialized state
/// @dev The mapping uses int16 for keys since ticks are represented as int24 and there are 256 (2^8) values per word.
library TickBitmap {
    /// @notice Computes the position in the mapping where the initialized bit for a tick lives
    /// @param tick The tick for which to compute the position
    /// @return wordPos The key in the mapping containing the word in which the bit is stored
    /// @return bitPos The bit position in the word where the flag is stored
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(tick % 256);
    }

    /// @notice Flips the initialized state for a given tick from false to true, or vice versa
    /// @param self The mapping in which to flip the tick
    /// @param tick The tick to flip
    /// @param tickSpacing The spacing between usable ticks
    function flipTick(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing
    ) internal {
        require(tick % tickSpacing == 0); // ensure that the tick is spaced
        (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        uint256 mask = 1 << bitPos;
        self[wordPos] ^= mask;
    }

    /// @notice 在单个 word (256 bits) 范围内查找下一个已初始化的 tick
    /// @dev 这是 swap 的核心函数，用于确定价格移动的边界
    /// 
    /// TickBitmap 结构说明:
    /// - 使用 mapping(int16 => uint256) 存储 tick 的初始化状态
    /// - 每个 uint256 (256 bits) 表示 256 个连续 compressed tick 的状态
    /// - wordPos (int16): 哪个 256-bit word
    /// - bitPos (uint8): word 内的哪一位 (0-255)
    ///
    /// 位图布局示意 (数值越大价格越高):
    /// wordPos = -1                    wordPos = 0                     wordPos = 1
    /// [255...128...64...32...0]      [255...128...64...32...0]       [255...128...64...32...0]
    ///  <-- 价格降低 (lte=true)                                         价格升高 (lte=false) -->
    ///
    /// @param self TickBitmap 存储引用
    /// @param tick 当前 tick 位置
    /// @param tickSpacing tick 间距 (由 fee tier 决定: 500->10, 3000->60, 10000->200)
    /// @param lte 搜索方向: true=向左搜索(价格降低), false=向右搜索(价格升高)
    /// @return next 找到的下一个 tick (可能未初始化，表示 word 边界)
    /// @return initialized 该 tick 是否已初始化 (有流动性边界)
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        // Step 1: 计算压缩后的 tick 索引
        // 将实际 tick 转换为 tickSpacing 的倍数索引
        // 例: tick=150, tickSpacing=60 -> compressed=2
        int24 compressed = tick / tickSpacing;
        // 负数除法向零取整，但我们需要向负无穷取整
        // 例: tick=-1, tickSpacing=60 -> -1/60=0(Solidity默认), 但应该是 -1
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity

        if (lte) {
            // === 向左搜索 (价格降低方向, token0 -> token1) ===
            
            // Step 2: 获取当前 tick 在 bitmap 中的位置
            (int16 wordPos, uint8 bitPos) = position(compressed);
            
            // Step 3: 构建掩码，保留当前位及其右边所有位
            // 例: bitPos=5 -> mask = 0b111111 (保留 bit 0-5)
            // all the 1s at or to the right of the current bitPos
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            
            // Step 4: 应用掩码，只保留当前位及右边的已初始化 tick
            uint256 masked = self[wordPos] & mask;

            // Step 5: 检查是否找到已初始化的 tick
            // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
            initialized = masked != 0;
            
            // Step 6: 计算下一个 tick
            // - 找到了: 用 MSB 定位最近的已初始化 tick
            // - 没找到: 返回当前 word 的最右边界
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            next = initialized
                ? (compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing
                : (compressed - int24(bitPos)) * tickSpacing;
        } else {
            // === 向右搜索 (价格升高方向, token1 -> token0) ===
            
            // Step 2: 从下一个 tick 开始搜索 (当前 tick 状态不影响向右搜索)
            // start from the word of the next tick, since the current tick state doesn't matter
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            
            // Step 3: 构建掩码，保留当前位及其左边所有位
            // 例: bitPos=5 -> mask = 0b111...100000
            // all the 1s at or to the left of the bitPos
            uint256 mask = ~((1 << bitPos) - 1);
            
            // Step 4: 应用掩码
            uint256 masked = self[wordPos] & mask;

            // Step 5: 检查是否找到
            // if there are no initialized ticks to the left of the current tick, return leftmost in the word
            initialized = masked != 0;
            
            // Step 6: 计算下一个 tick
            // - 找到了: 用 LSB 定位最近的已初始化 tick
            // - 没找到: 返回当前 word 的最左边界 (type(uint8).max = 255)
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            next = initialized
                ? (compressed + 1 + int24(BitMath.leastSignificantBit(masked) - bitPos)) * tickSpacing
                : (compressed + 1 + int24(type(uint8).max - bitPos)) * tickSpacing;
        }
    }
}
