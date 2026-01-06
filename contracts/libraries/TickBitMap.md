## tickSpacing、compressed、wordPos、bitPos 关系详解

### 1. tickSpacing（tick间距）

tickSpacing 是 Uniswap V3 池子的一个参数，决定了哪些 tick 可以被初始化（放置流动性）。

```
fee = 0.05% (500)   → tickSpacing = 10
fee = 0.30% (3000)  → tickSpacing = 60  
fee = 1.00% (10000) → tickSpacing = 200
```

**意义**：不是所有 tick 都能放流动性，只有 `tick % tickSpacing == 0` 的 tick 才行。

```
tickSpacing = 60 时，可初始化的 tick：
..., -180, -120, -60, 0, 60, 120, 180, ...
```

### 2. compressed（压缩后的tick索引）

```solidity
int24 compressed = tick / tickSpacing;
```

**作用**：将稀疏的 tick 空间压缩成连续的索引空间。

```
tickSpacing = 60 的例子：

原始 tick    →  compressed
-180         →  -3
-120         →  -2
-60          →  -1
0            →  0
60           →  1
120          →  2
180          →  3
```

**为什么需要压缩？** 节省存储空间。如果直接用 tick 做索引，tickSpacing=60 时，bitmap 中 98.3% 的位置永远为 0（浪费）。

### 3. wordPos 和 bitPos（位图定位）

```solidity
int16 wordPos = int16(compressed >> 8);      // 高位：第几个 word
uint8 bitPos  = uint8(uint24(compressed % 256));  // 低位：word 内第几位
```

**原理**：一个 `uint256` 有 256 位，可以表示 256 个连续的 compressed tick。

```
compressed 值的二进制分解：
┌─────────────────┬──────────────┐
│  高位 (wordPos) │ 低位 (bitPos)│
│    int16        │   uint8      │
└─────────────────┴──────────────┘
        ↓                ↓
   第几个 word      word 内第几位
```

### 4. 完整映射示例

假设 `tickSpacing = 60`：

```
tick     compressed   wordPos   bitPos   位图位置
─────────────────────────────────────────────────
-15360   -256         -1        0        word[-1] 的 bit 0
-15300   -255         -1        1        word[-1] 的 bit 1
...
-60      -1           -1        255      word[-1] 的 bit 255
0        0            0         0        word[0] 的 bit 0
60       1            0         1        word[0] 的 bit 1
120      2            0         2        word[0] 的 bit 2
...
15300    255          0         255      word[0] 的 bit 255
15360    256          1         0        word[1] 的 bit 0
```

### 5. 图示

```
                    TickBitmap 结构
                    ================
                    
mapping(int16 => uint256)
        ↓
   ┌─────────┬─────────────────────────────────────────────┐
   │ wordPos │                  uint256 (256 bits)         │
   ├─────────┼─────────────────────────────────────────────┤
   │   -1    │ [bit255][bit254]...[bit1][bit0] ← compressed -256 ~ -1   │
   │    0    │ [bit255][bit254]...[bit1][bit0] ← compressed 0 ~ 255     │
   │    1    │ [bit255][bit254]...[bit1][bit0] ← compressed 256 ~ 511   │
   └─────────┴─────────────────────────────────────────────┘

每个 bit = 1 表示该 compressed tick 已初始化（有流动性边界）
```

### 6. 从 tick 到位图的完整转换

```
输入: tick = 7200, tickSpacing = 60

Step 1: compressed = 7200 / 60 = 120
Step 2: wordPos = 120 >> 8 = 0     (120 的二进制: 01111000)
Step 3: bitPos  = 120 % 256 = 120

结果: 查找 self[0] 的第 120 位
```

```
输入: tick = -7200, tickSpacing = 60

Step 1: compressed = -7200 / 60 = -120
Step 2: wordPos = -120 >> 8 = -1   (负数右移向下取整)
Step 3: bitPos  = -120 % 256 = 136 (uint8 转换)

结果: 查找 self[-1] 的第 136 位
```

### 7. 为什么这样设计？

1. **Gas 效率**：一次 SLOAD 读取 256 个 tick 的状态
2. **批量查找**：`nextInitializedTickWithinOneWord` 可以用位运算一次找到最近的已初始化 tick
3. **空间压缩**：通过 tickSpacing 减少需要存储的 tick 数量