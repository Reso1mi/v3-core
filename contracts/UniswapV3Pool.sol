// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3Pool.sol';

import './NoDelegateCall.sol';

import './libraries/LowGasSafeMath.sol';
import './libraries/SafeCast.sol';
import './libraries/Tick.sol';
import './libraries/TickBitmap.sol';
import './libraries/Position.sol';
import './libraries/Oracle.sol';

import './libraries/FullMath.sol';
import './libraries/FixedPoint128.sol';
import './libraries/TransferHelper.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/SqrtPriceMath.sol';
import './libraries/SwapMath.sol';

import './interfaces/IUniswapV3PoolDeployer.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/callback/IUniswapV3MintCallback.sol';
import './interfaces/callback/IUniswapV3SwapCallback.sol';
import './interfaces/callback/IUniswapV3FlashCallback.sol';

contract UniswapV3Pool is IUniswapV3Pool, NoDelegateCall {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override factory;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override token0;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override token1;
    /// @inheritdoc IUniswapV3PoolImmutables
    uint24 public immutable override fee;

    /// @inheritdoc IUniswapV3PoolImmutables
    int24 public immutable override tickSpacing;

    /// @inheritdoc IUniswapV3PoolImmutables
    uint128 public immutable override maxLiquidityPerTick;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }
    /// @inheritdoc IUniswapV3PoolState
    Slot0 public override slot0;

    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal1X128;

    // accumulated protocol fees in token0/token1 units
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    /// @inheritdoc IUniswapV3PoolState
    ProtocolFees public override protocolFees;

    /// @inheritdoc IUniswapV3PoolState
    uint128 public override liquidity;

    /// @inheritdoc IUniswapV3PoolState
    mapping(int24 => Tick.Info) public override ticks;
    /// @inheritdoc IUniswapV3PoolState
    mapping(int16 => uint256) public override tickBitmap;
    /// @inheritdoc IUniswapV3PoolState
    mapping(bytes32 => Position.Info) public override positions;
    /// @inheritdoc IUniswapV3PoolState
    Oracle.Observation[65535] public override observations;

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    /**
     * @notice 重入锁：防止重入攻击
     * @dev 为什么需要重入锁？
     *      因为 Pool 使用余额检查来验证支付：
     *      1. 记录转账前余额
     *      2. 调用回调函数（外部调用！）
     *      3. 检查转账后余额
     *      
     *      如果没有重入锁，恶意合约可以在回调中再次调用 Pool，
     *      导致余额检查失效。
     *      
     *      例如：mint → 回调 → 恶意再次 mint → 余额检查通过（但实际没支付）
     */
    modifier lock() {
        require(slot0.unlocked, 'LOK');  // 检查是否已锁定
        slot0.unlocked = false;          // 上锁
        _;                               // 执行函数
        slot0.unlocked = true;           // 解锁
    }

    /// @dev Prevents calling a function from anyone except the address returned by IUniswapV3Factory#owner()
    /**
     * @notice 只允许工厂合约的所有者调用
     * @dev 用于管理员功能，如设置协议费率、收取协议费用
     */
    modifier onlyFactoryOwner() {
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

    constructor() {
        int24 _tickSpacing;
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters();
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    /// @dev Common checks for valid tick inputs.
    /**
     * @notice 验证 tick 范围的有效性
     * @dev 确保：
     *      1. tickLower < tickUpper（下界必须小于上界）
     *      2. tickLower >= MIN_TICK（不能低于最小 tick）
     *      3. tickUpper <= MAX_TICK（不能高于最大 tick）
     */
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, 'TLU');
        require(tickLower >= TickMath.MIN_TICK, 'TLM');
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');
    }

    /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
    /**
     * @notice 获取当前区块时间戳（截断为 32 位）
     * @dev 截断是有意为之，用于节省存储空间
     *      32 位时间戳足够使用到 2106 年
     */
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    /**
     * @notice 获取 Pool 的 token0 余额
     * @dev Gas 优化：使用 staticcall 避免冗余的 extcodesize 检查
     *      这比直接调用 IERC20(token0).balanceOf(address(this)) 更省 gas
     */
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) =
            token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    /**
     * @notice 获取 Pool 的 token1 余额
     * @dev Gas 优化：使用 staticcall 避免冗余的 extcodesize 检查
     */
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) =
            token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external
        view
        override
        noDelegateCall
        returns (
            int56 tickCumulativeInside,
            uint160 secondsPerLiquidityInsideX128,
            uint32 secondsInside
        )
    {
        checkTicks(tickLower, tickUpper);

        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        {
            Tick.Info storage lower = ticks[tickLower];
            Tick.Info storage upper = ticks[tickUpper];
            bool initializedLower;
            (tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = (
                lower.tickCumulativeOutside,
                lower.secondsPerLiquidityOutsideX128,
                lower.secondsOutside,
                lower.initialized
            );
            require(initializedLower);

            bool initializedUpper;
            (tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = (
                upper.tickCumulativeOutside,
                upper.secondsPerLiquidityOutsideX128,
                upper.secondsOutside,
                upper.initialized
            );
            require(initializedUpper);
        }

        Slot0 memory _slot0 = slot0;

        if (_slot0.tick < tickLower) {
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } else if (_slot0.tick < tickUpper) {
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    _slot0.tick,
                    _slot0.observationIndex,
                    liquidity,
                    _slot0.observationCardinality
                );
            return (
                tickCumulative - tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 -
                    secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                time - secondsOutsideLower - secondsOutsideUpper
            );
        } else {
            return (
                tickCumulativeUpper - tickCumulativeLower,
                secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128,
                secondsOutsideUpper - secondsOutsideLower
            );
        }
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        noDelegateCall
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
    }

    /// @inheritdoc IUniswapV3PoolActions
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext)
        external
        override
        lock
        noDelegateCall
    {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew =
            observations.grow(observationCardinalityNextOld, observationCardinalityNext);
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev not locked because it initializes unlocked
    function initialize(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, 'AI');

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        emit Initialize(sqrtPriceX96, tick);
    }

    /**
     * @notice 修改 position 的参数结构体
     * @dev 用于 mint 和 burn 操作
     */
    struct ModifyPositionParams {
        // position 的所有者
        // - 如果通过 NPM：owner = NPM 合约地址（多个用户共享）
        // - 如果直接调用：owner = msg.sender（独立 position）
        address owner;
        
        // 价格区间的下界和上界
        int24 tickLower;
        int24 tickUpper;
        
        // 流动性变化量
        // - 正数：增加流动性（mint）
        // - 负数：减少流动性（burn）
        int128 liquidityDelta;
    }

    /// @dev Effect some changes to a position
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return position a storage pointer referencing the position with the given owner and tick range
    /// @return amount0 the amount of token0 owed to the pool, negative if the pool should pay the recipient
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    /**
     * @notice 修改 position（增加或减少流动性）
     * @dev 核心逻辑：
     *      1. 更新 position 和 tick 的状态
     *      2. 根据当前价格位置计算需要的代币数量
     * @param params 包含 owner、价格区间、流动性变化量
     * @return position 存储引用
     * @return amount0 token0 的变化量（正数=需要支付，负数=应该收到）
     * @return amount1 token1 的变化量（正数=需要支付，负数=应该收到）
     */
    function _modifyPosition(ModifyPositionParams memory params)
        private
        noDelegateCall
        returns (
            Position.Info storage position,
            int256 amount0,
            int256 amount1
        )
    {
        // 验证 tick 范围的有效性
        checkTicks(params.tickLower, params.tickUpper);

        // 缓存 slot0（节省 gas）
        Slot0 memory _slot0 = slot0;

        // 更新 position 和 tick 的状态（手续费、流动性等）
        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick
        );

        // 根据当前价格位置计算需要的代币数量
        // 关键：Uniswap V3 的集中流动性只在价格区间内有效
        if (params.liquidityDelta != 0) {
            if (_slot0.tick < params.tickLower) {
                // ========== 情况 1：当前价格在区间下方 ==========
                // 价格 < tickLower，流动性全部是 token0
                // 
                // 价格轴：  当前价格 ← | [tickLower ←→ tickUpper]
                //                    ↑
                //                 区间下界
                //
                // 只需要 token0，不需要 token1
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // ========== 情况 2：当前价格在区间内部 ==========
                // tickLower ≤ 价格 < tickUpper，流动性处于活跃状态
                //
                // 价格轴：  [tickLower ← 当前价格 → tickUpper]
                //                        ↑
                //                    价格在区间内
                //
                // 需要同时提供 token0 和 token1
                
                uint128 liquidityBefore = liquidity; // 缓存当前流动性

                // 更新预言机（因为流动性变化会影响 TWAP）
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                // 计算 token0 数量（当前价格 → 上界）
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,                        // 当前价格
                    TickMath.getSqrtRatioAtTick(params.tickUpper),  // 上界价格
                    params.liquidityDelta
                );
                
                // 计算 token1 数量（下界 → 当前价格）
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),  // 下界价格
                    _slot0.sqrtPriceX96,                        // 当前价格
                    params.liquidityDelta
                );

                // 更新全局流动性（只有在区间内的流动性才计入全局）
                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } else {
                // ========== 情况 3：当前价格在区间上方 ==========
                // 价格 ≥ tickUpper，流动性全部是 token1
                //
                // 价格轴：  [tickLower ←→ tickUpper] | → 当前价格
                //                                  ↑
                //                               区间上界
                //
                // 只需要 token1，不需要 token0
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev Gets and updates a position with the given liquidity delta
    /// @param owner the owner of the position
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    /// @param tick the current tick, passed to avoid sloads
    /**
     * @notice 更新 position 和相关 tick 的状态
     * @dev 核心功能：
     *      1. 更新 tick 的流动性和费用累计值
     *      2. 更新 tickBitmap（标记 tick 是否初始化）
     *      3. 计算并更新 position 的手续费
     * @param owner position 的所有者（可能是 NPM 合约或直接调用者）
     * @param tickLower 价格区间下界
     * @param tickUpper 价格区间上界
     * @param liquidityDelta 流动性变化量（正数=增加，负数=减少）
     * @param tick 当前 tick（避免重复读取存储）
     * @return position 存储引用
     */
    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        // 获取或创建 position
        // 注意：如果是通过 NPM，多个用户可能共享同一个 position（owner = NPM）
        position = positions.get(owner, tickLower, tickUpper);

        // 缓存全局费用增长（节省 gas）
        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128;
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128;

        // 记录 tick 是否发生翻转（从未初始化→初始化，或反之）
        bool flippedLower;
        bool flippedUpper;
        
        if (liquidityDelta != 0) {
            // 获取当前时间和预言机数据
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    slot0.tick,
                    slot0.observationIndex,
                    liquidity,
                    slot0.observationCardinality
                );

            // 更新下界 tick
            // flippedLower = true 表示这个 tick 从未初始化变为初始化（或反之）
            flippedLower = ticks.update(
                tickLower,
                tick,                           // 当前 tick
                liquidityDelta,                 // 流动性变化
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,                          // lower = false（下界）
                maxLiquidityPerTick
            );
            
            // 更新上界 tick
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,                           // upper = true（上界）
                maxLiquidityPerTick
            );

            // 如果 tick 发生翻转，更新 tickBitmap
            // tickBitmap 用于快速查找下一个初始化的 tick
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        // 计算区间内的费用增长
        // 这是计算 position 应得手续费的关键
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        // 更新 position 的流动性和手续费
        // 会计算自上次更新以来累积的手续费，并记录到 tokensOwed
        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        // 如果是减少流动性，且 tick 不再有流动性，清理 tick 数据
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    /**
     * @notice 添加流动性到指定价格区间
     * @dev 可以被任何人调用：
     *      - 普通用户通过 NonfungiblePositionManager 调用（recipient = NPM 合约）
     *      - 高级用户/合约直接调用（recipient = 调用者自己）
     * @param recipient position 的所有者地址
     *                  - 如果通过 NPM：recipient = NPM 合约地址（所有用户共享 position）
     *                  - 如果直接调用：recipient = msg.sender（独立 position，不可转让）
     * @param tickLower 价格区间下界
     * @param tickUpper 价格区间上界
     * @param amount 要添加的流动性数量
     * @param data 传递给回调函数的数据（通常包含付款人信息）
     * @return amount0 需要支付的 token0 数量
     * @return amount1 需要支付的 token1 数量
     */
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        // 验证流动性数量大于 0
        require(amount > 0);
        
        // 修改 position，计算需要的代币数量
        // owner = recipient（可能是 NPM 合约，也可能是直接调用者）
        (, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: recipient,                      // position 的所有者
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(amount).toInt128()  // 正数 = 增加流动性
                })
            );

        // 转换为 uint256（amount0Int 和 amount1Int 必定为正）
        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        // 记录转账前的余额（用于后续验证）
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        
        // 回调调用者，要求支付代币
        // msg.sender 可能是：
        // - NonfungiblePositionManager（会从用户转账到 Pool）
        // - 直接调用的合约（需要实现回调接口）
        // data中的 payer 字段才是真正的付款人（用户账户EOA等）
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        
        // 验证支付：检查余额是否增加了足够的数量
        if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), 'M0');
        if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), 'M1');

        // 发出事件
        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /**
     * @notice 收取累积的代币（手续费 + burn 后的代币）
     * @dev 只有 position 的所有者可以调用
     *      - 如果通过 NPM：msg.sender = NPM 合约，NPM 会验证 NFT 所有权
     *      - 如果直接创建：msg.sender = position 所有者
     * @param recipient 接收代币的地址
     * @param tickLower 价格区间下界
     * @param tickUpper 价格区间上界
     * @param amount0Requested 请求收取的 token0 数量（可以小于等于 tokensOwed0）
     * @param amount1Requested 请求收取的 token1 数量（可以小于等于 tokensOwed1）
     * @return amount0 实际收取的 token0 数量
     * @return amount1 实际收取的 token1 数量
     */
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        // 获取调用者的 position
        // 注意：这里不需要 checkTicks，因为无效的 position 不会有 tokensOwed
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        // 计算实际可以收取的数量（取请求数量和欠款的较小值）
        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        // 收取 token0
        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;  // 减少欠款
            TransferHelper.safeTransfer(token0, recipient, amount0);  // 转账
        }
        
        // 收取 token1
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;  // 减少欠款
            TransferHelper.safeTransfer(token1, recipient, amount1);  // 转账
        }

        // 发出事件
        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    /**
     * @notice 移除流动性（不转账代币，只记录欠款）
     * @dev 只有 position 的所有者可以调用
     *      burn 只是减少流动性并计算应得的代币，不实际转账
     *      需要调用 collect() 来实际收取代币
     * @param tickLower 价格区间下界
     * @param tickUpper 价格区间上界
     * @param amount 要移除的流动性数量
     * @return amount0 应得的 token0 数量（记录在 tokensOwed0 中）
     * @return amount1 应得的 token1 数量（记录在 tokensOwed1 中）
     */
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        // 修改 position，计算应得的代币数量
        // liquidityDelta 为负数 = 减少流动性
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,                      // position 所有者
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(amount).toInt128()  // 负数 = 减少流动性
                })
            );

        // 转换为 uint256（amount0Int 和 amount1Int 为负数，取反后为正）
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        // 将应得的代币记录到 tokensOwed 中
        // 注意：这里不实际转账，只是记账
        // 用户需要调用 collect() 来实际收取代币
        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),  // 累加欠款
                position.tokensOwed1 + uint128(amount1)   // 累加欠款
            );
        }

        // 发出事件
        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    struct SwapCache {
        // the protocol fee for the input token
        uint8 feeProtocol;
        // liquidity at the beginning of the swap
        uint128 liquidityStart;
        // the timestamp of the current block
        uint32 blockTimestamp;
        // the current value of the tick accumulator, computed only if we cross an initialized tick
        int56 tickCumulative;
        // the current value of seconds per liquidity accumulator, computed only if we cross an initialized tick
        uint160 secondsPerLiquidityCumulativeX128;
        // whether we've computed and cached the above two accumulators
        bool computedLatestObservation;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        uint128 protocolFee;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    /// @inheritdoc IUniswapV3PoolActions
    /**
     * @notice 执行代币交换
     * @param recipient 接收输出代币的地址
     * @param zeroForOne 交换方向：true = 卖出token0买入token1，false = 卖出token1买入token0
     * @param amountSpecified 指定的交换数量：正数 = 精确输入，负数 = 精确输出
     * @param sqrtPriceLimitX96 价格限制（防止滑点过大）：zeroForOne=true时应小于当前价格，否则应大于当前价格
     * @param data 传递给回调函数的数据
     * @return amount0 token0的变化量（正数=池子收到，负数=池子支付）
     * @return amount1 token1的变化量（正数=池子收到，负数=池子支付）
     */
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override noDelegateCall returns (int256 amount0, int256 amount1) {
        // ========== 第一阶段：参数验证与初始化 ==========
        
        // 1. 验证交换数量不为0
        require(amountSpecified != 0, 'AS');

        // 2. 保存当前状态快照（用于后续比较和恢复）
        Slot0 memory slot0Start = slot0;

        // 3. 重入锁检查（防止重入攻击）
        require(slot0Start.unlocked, 'LOK');
        
        // 4. 价格限制验证
        // zeroForOne=true（卖token0）：价格应下降，限制价格必须 < 当前价格 且 > 最小价格
        // zeroForOne=false（卖token1）：价格应上升，限制价格必须 > 当前价格 且 < 最大价格
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            'SPL'
        );

        // 5. 上锁（防止重入）
        slot0.unlocked = false;

        // ========== 第二阶段：缓存和状态初始化 ==========
        
        // 创建交换缓存（存储不变的初始值）
        SwapCache memory cache =
            SwapCache({
                liquidityStart: liquidity,              // 起始流动性（用于后续比较）
                blockTimestamp: _blockTimestamp(),      // 当前区块时间戳
                feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4), // 协议费率
                secondsPerLiquidityCumulativeX128: 0,   // 每单位流动性的累计秒数（延迟计算）
                tickCumulative: 0,                      // tick累计值（延迟计算）
                computedLatestObservation: false        // 是否已计算最新观察值
            });

        // 判断是精确输入还是精确输出
        // 正数 = 精确输入（指定输入数量，计算输出）
        // 负数 = 精确输出（指定输出数量，计算输入）
        bool exactInput = amountSpecified > 0;

        // 创建交换状态（会在循环中不断更新）
        SwapState memory state =
            SwapState({
                amountSpecifiedRemaining: amountSpecified,  // 剩余待交换数量
                amountCalculated: 0,                        // 已计算的输出/输入数量
                sqrtPriceX96: slot0Start.sqrtPriceX96,     // 当前价格（会随交换更新）
                tick: slot0Start.tick,                      // 当前tick（会随交换更新）
                feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128, // 全局费用增长
                protocolFee: 0,                             // 累计的协议费用
                liquidity: cache.liquidityStart             // 当前流动性（会在跨tick时更新）
            });

        // ========== 第三阶段：核心交换循环 ==========
        // 循环条件：还有剩余数量 且 未达到价格限制
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;

            // 记录本步骤的起始价格
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            // --- 步骤1：在一个word（256个tick）内找到下一个初始化的tick ---
            // 返回值：
            // - tickNext: 下一个tick位置（可能是初始化的tick，也可能是word边界）
            // - initialized: 是否真的找到了初始化的tick
            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                tickSpacing,
                zeroForOne
            );

            // 边界检查：确保不超出全局tick范围
            // （tickBitmap不知道全局边界，需要手动限制）
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // 获取下一个tick对应的价格
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // --- 步骤2：计算本步骤的交换结果 ---
            // 目标价格：取 (下一个tick价格) 和 (价格限制) 中更接近当前价格的那个
            // 这样可以确保不会超过用户设定的滑点限制
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,                 // 当前价格
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96             // 如果下一个tick超过限制，使用价格限制
                    : step.sqrtPriceNextX96,        // 否则使用下一个tick的价格
                state.liquidity,                    // 当前流动性
                state.amountSpecifiedRemaining,     // 剩余待交换数量
                fee                                 // 手续费率
            );

            // --- 步骤3：更新剩余数量和已计算数量 ---
            if (exactInput) {
                // 精确输入模式：
                // - 减少剩余输入（输入 + 手续费）
                // - 增加已计算的输出（注意是负数，因为是池子支付）
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                // 精确输出模式：
                // - 增加剩余输出（因为amountSpecified是负数）
                // - 增加已计算的输入（输入 + 手续费）
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            // --- 步骤4：处理协议费用 ---
            // 如果设置了协议费用，从手续费中分出一部分给协议
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;  // 协议费用 = 总手续费 / feeProtocol
                step.feeAmount -= delta;                              // 从LP费用中扣除
                state.protocolFee += uint128(delta);                  // 累加到协议费用
            }

            // --- 步骤5：更新全局费用增长 ---
            // 将本步骤的手续费（扣除协议费后）分配给所有LP
            // feeGrowthGlobalX128 表示每单位流动性累计的手续费（Q128格式）
            if (state.liquidity > 0)
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

            // --- 步骤6：处理tick跨越 ---
            // ⚠️ 重要：流动性变化只发生在跨越初始化的tick时！
            // 如果交换在tick内部进行，流动性保持不变
            
            // 检查是否到达了下一个tick的价格
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // 只有当tick真的被初始化时才执行跨越操作
                if (step.initialized) {
                    // 首次跨越初始化tick时，计算观察值（用于预言机）
                    // 这是一个延迟计算的优化：只在真正需要时才计算
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    
                    // 跨越tick，获取流动性变化量
                    // cross函数会更新tick的外部累计值，并返回liquidityNet
                    int128 liquidityNet =
                        ticks.cross(
                            step.tickNext,
                            (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                            (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
                            cache.secondsPerLiquidityCumulativeX128,
                            cache.tickCumulative,
                            cache.blockTimestamp
                        );
                    
                    // 向左移动（zeroForOne=true）时，流动性变化取反
                    // 原因：tick存储的是"从左向右跨越时"的流动性变化
                    // 从右向左跨越时，需要反向应用这个变化
                    if (zeroForOne) liquidityNet = -liquidityNet;

                    // ⭐ 更新当前流动性（这是流动性改变的唯一位置！）
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                // 更新当前tick
                // 注意：向左移动时，当前tick = tickNext - 1（因为tick代表价格区间的左端点）
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // 价格变化了但没有到达下一个tick（在tick内部移动）
                // ⭐ 注意：这里只更新tick值，流动性保持不变！
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        } // while循环结束

        // ========== 第四阶段：更新存储状态 ==========
        
        // 如果tick发生了变化，需要更新slot0和预言机
        if (state.tick != slot0Start.tick) {
            // 写入新的预言机观察值
            (uint16 observationIndex, uint16 observationCardinality) =
                observations.write(
                    slot0Start.observationIndex,
                    cache.blockTimestamp,
                    slot0Start.tick,
                    cache.liquidityStart,
                    slot0Start.observationCardinality,
                    slot0Start.observationCardinalityNext
                );
            // 更新slot0的所有相关字段
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // tick没变，只更新价格（价格可能在tick内部移动）
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // 如果流动性发生了变化，更新全局流动性
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // 更新全局费用增长和协议费用
        // 注意：溢出是可接受的，协议需要在达到uint128.max之前提取费用
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;  // 更新token0的费用增长
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;  // 累加协议费用
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;  // 更新token1的费用增长
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;  // 累加协议费用
        }

        // ========== 第五阶段：计算最终金额 ==========
        
        // 根据交换方向和模式计算最终的amount0和amount1
        // zeroForOne=true: 卖token0买token1，amount0为正（池子收到），amount1为负（池子支付）
        // zeroForOne=false: 卖token1买token0，amount0为负（池子支付），amount1为正（池子收到）
        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // ========== 第六阶段：代币转账和回调验证 ==========
        // 采用"先转出，后验证支付"的闪电贷模式
        
        if (zeroForOne) {
            // 卖token0买token1的情况
            
            // 1. 如果需要支付token1（amount1<0），先转给接收者
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

            // 2. 记录转账前的token0余额
            uint256 balance0Before = balance0();
            
            // 3. 调用回调函数，调用者需要在回调中支付token0
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            
            // 4. 验证支付：检查余额增加是否足够（防止支付不足）
            require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
        } else {
            // 卖token1买token0的情况（逻辑相同，token0和token1互换）
            
            // 1. 如果需要支付token0（amount0<0），先转给接收者
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));

            // 2. 记录转账前的token1余额
            uint256 balance1Before = balance1();
            
            // 3. 调用回调函数，调用者需要在回调中支付token1
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            
            // 4. 验证支付：检查余额增加是否足够（防止支付不足）
            require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
        }

        // ========== 第七阶段：发出事件并解锁 ==========
        
        // 发出Swap事件，记录交换详情
        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        
        // 解锁，允许后续调用
        slot0.unlocked = true;
    }

    /// @inheritdoc IUniswapV3PoolActions
    /**
     * @notice 闪电贷：借出代币，在同一交易中归还并支付手续费
     * @dev 典型用途：
     *      - 套利：借代币 → 在其他 DEX 套利 → 归还 + 手续费
     *      - 清算：借代币 → 清算抵押品 → 归还 + 手续费
     *      - 自我对冲：借代币 → 执行复杂策略 → 归还 + 手续费
     * @param recipient 接收借出代币的地址
     * @param amount0 借出的 token0 数量
     * @param amount1 借出的 token1 数量
     * @param data 传递给回调函数的数据
     */
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override lock noDelegateCall {
        // 获取当前流动性（用于计算手续费分配）
        uint128 _liquidity = liquidity;
        require(_liquidity > 0, 'L');

        // 计算手续费（向上取整，确保协议不会亏损）
        // 手续费率 = pool 的 fee（例如 3000 = 0.3%）
        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        
        // 记录转账前的余额
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        // ========== 第一步：先转出代币给接收者 ==========
        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        // ========== 第二步：回调调用者，要求归还代币 + 手续费 ==========
        // 调用者需要在回调中：
        // 1. 使用借出的代币执行操作（套利、清算等）
        // 2. 归还借出的代币 + 手续费
        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        // ========== 第三步：验证归还 ==========
        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        // 验证余额增加至少等于手续费（借出的代币 + 手续费）
        require(balance0Before.add(fee0) <= balance0After, 'F0');
        require(balance1Before.add(fee1) <= balance1After, 'F1');

        // 计算实际支付的金额（可能大于最低要求的手续费）
        // 这是安全的，因为我们已经验证了 balanceAfter >= balanceBefore + fee
        uint256 paid0 = balance0After - balance0Before;
        uint256 paid1 = balance1After - balance1Before;

        // ========== 第四步：分配手续费 ==========
        if (paid0 > 0) {
            // 获取协议费率（低 4 位）
            uint8 feeProtocol0 = slot0.feeProtocol % 16;
            
            // 计算协议费用（如果 feeProtocol0 = 0，则全部给 LP）
            uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;
            
            // 累加协议费用
            if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0);
            
            // 剩余部分分配给 LP（更新全局费用增长）
            feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - fees0, FixedPoint128.Q128, _liquidity);
        }
        
        if (paid1 > 0) {
            // 获取协议费率（高 4 位）
            uint8 feeProtocol1 = slot0.feeProtocol >> 4;
            
            // 计算协议费用
            uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;
            
            // 累加协议费用
            if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);
            
            // 剩余部分分配给 LP
            feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - fees1, FixedPoint128.Q128, _liquidity);
        }

        // 发出事件
        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner {
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10)) &&
                (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );
        uint8 feeProtocolOld = slot0.feeProtocol;
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock onlyFactoryOwner returns (uint128 amount0, uint128 amount1) {
        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        if (amount0 > 0) {
            if (amount0 == protocolFees.token0) amount0--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            if (amount1 == protocolFees.token1) amount1--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}
