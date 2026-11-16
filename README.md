# PoC: Distributor yield-share redirection via aToken donation

Morpheus Bug Bounty v2 report M-01. Foundry test against the DEPLOYED
Morpheus Capital contracts on an Ethereum mainnet fork pinned to block
26425790 (2026-11-16 ~06:29 UTC).

## Run

```
forge test -vvv
```

No setup needed: the fork (RPC + pinned block) is selected in the test's
`setUp` via `vm.createSelectFork`. To use your own RPC endpoint:

```
MAINNET_RPC_URL=https://your-ethereum-rpc forge test -vvv
```

Tested with forge 1.9.0. All dependencies are vendored under `lib/`.

## What it proves (3/3 tests pass)

- `test_controlNoDonation` — without a donation, the USDT pool earns 149 MOR
  (5.03%) of the period's 2,975 MOR emission; the attacker (90% of the pool's
  virtual deposits) accrues 134 MOR.
- `test_donationRedirectsRewards` — with a $450 aUSDT donation to the
  Distributor, the same pool earns 1,347 MOR (45.28%); the attacker accrues
  1,212 MOR. The donation is a real cost: the next `withdrawYield` sweeps
  $480 (donation + real yield) to L1Sender.
- `test_claimAfterLock` — after the 14-day claim lock, the attacker claims
  the full 1,212 MOR via the LayerZero mint message.

No privileged accounts are used: the attacker is an ordinary address
(`0xA77A`) funded with `deal`/`vm.deal`. Nothing here touches mainnet.

## Simulation notes (documented in the test file; none change the target contracts)

- The fork is at a block where a distribution is already due, but staking
  triggers a distribution first, so the test warps +25h to pass
  `minRewardsDistributePeriod` (1 day). Warping makes Chainlink feeds stale,
  so the price consumer is mocked to return the pinned-block prices (fresh
  prices hold in production).
- Aave interest accrues realistically: the warp + the attacker's Aave supply
  interaction updates the liquidity index, so aToken balances grow by ~25h of
  interest for every Aave pool.
- stETH does NOT rebase in a fork (Lido oracle never runs), so the daily
  stETH rebase (~0.294 stETH on 3,582 stETH @ ~3% APY) is simulated by
  transferring 0.294 stETH to the Distributor before the distribution.
  Without it the PoC would UNDERSTATE total real yield and OVERSTATE the
  attack.
- USDT (Tether) returns no data on approve/transfer, so the test uses a
  low-level call for USDT approvals (like SafeERC20 does).
