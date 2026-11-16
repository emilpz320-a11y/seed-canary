# SeedCanary

**A bait address from your seed that must never move. If it moves, your seed leaked, and your vault escapes to cold storage by itself.**
Built for the Reactive Omni Buildathon, track *Set It and Forget It*.

**Demo video (1:52):** https://youtu.be/rx4uisFy0Zo

## Why I want this running
Seed phrases leak quietly: a cloud backup, a photo, a clipboard logger, a fake wallet update. You usually find out
when the money is gone. Sweeper bots work through a stolen seed in derivation order and take everything that moves
in the first seconds.

A canary turns that habit against them. I park a little ERC-20 dust on an address from the same seed and never
touch it. Nobody has a reason to move it except someone holding my seed. The first `Transfer` or `Approval` that
address signs is a perfect alarm: no false positives, no price feeds, no heuristics.

Reactive Network makes the alarm do something. A reactive contract subscribes to that one address, and the moment
the bait moves it calls `evacuate()` on my vault, which sends everything to a cold wallet from a different seed.
No server, no bot, no keeper to keep alive. I set it up once and forget it.

```
Base Sepolia                      Reactive Network (Lasna)                    any supported chain
canary moves its bait ──Transfer──▶ CanaryWatcher.react()
                                     └─ for every vault registered ──callback──▶ EscapeVault.evacuate()
                                                                                  └─ ETH + tracked ERC-20s → cold wallet
```

## Live on testnet
| | |
|---|---|
| `EscapeVault` (Base Sepolia, chain 84532) | [`0xf3ccb8cf45cb1aff6bddffd6159083ccf739e53b`](https://sepolia.basescan.org/address/0xf3ccb8cf45cb1aff6bddffd6159083ccf739e53b) |
| `CanaryWatcher` (Reactive Lasna, chain 5318007) | [`0x2bafc7c50481509ac8d3844060bf9400e14d321a`](https://lasna.reactscan.net/address/0x2bafc7c50481509ac8d3844060bf9400e14d321a) |
| `BaitToken` (Base Sepolia) | [`0x42401a1bab5b72c970fe2a892f20a2ccd60cf732`](https://sepolia.basescan.org/address/0x42401a1bab5b72c970fe2a892f20a2ccd60cf732) |
| Canary address | `0xEF96DD4589B851250DE58fFeAdA329Df4d2F64fE` |
| Cold wallet | `0x9f59D3b17BBE5b706bb16B9e27406eb8Cbc1C077` |
| Callback proxy used (Base Sepolia) | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |

The full loop, from origin event to callback (recorded in the demo video and in `deployments.json`):

| Step | Chain | Transaction |
|---|---|---|
| 1. Ordinary life: the owner queues a 0.0002 ETH payment | Base Sepolia | [`0x40380710c152e76a…`](https://sepolia.basescan.org/tx/0x40380710c152e76a4f294352424c865e814dc1815e8cad58dc95d5dbe856e112) |
| 2. After the time-lock the payment goes through; the canary stays quiet | Base Sepolia | [`0xf61f03df5ba00518…`](https://sepolia.basescan.org/tx/0xf61f03df5ba005188836d2ebac0a3cb4b67e3a4228fe5ef31d687f82ff09f881) |
| 3. The seed leaks: the thief queues a withdrawal of everything with the owner key | Base Sepolia | [`0x205cc159b38c6483…`](https://sepolia.basescan.org/tx/0x205cc159b38c6483def6b4f5671df7cebd9eab148dd9e9b71a36f168edd505d1) |
| 4. **Origin event**: the thief sweeps the bait from the canary | Base Sepolia | [`0x6bea180ddc820703…`](https://sepolia.basescan.org/tx/0x6bea180ddc820703466d544504f548ee2a40d28f2fad789f5f23e42aa9d969b8) |
| 5. `react()` sees the `Transfer` and requests the callback | Reactive Lasna | [`0xbe7c8830d193923d…`](https://lasna.reactscan.net/tx/0xbe7c8830d193923d06427c1a1735bc2052ca75bd74e71de197da6230f4da25cb) |
| 6. **Callback**: `evacuate()` lands **1 s** after the bait moved; 0.0018 ETH reaches the cold wallet | Base Sepolia | [`0x4cea83814be11de2…`](https://sepolia.basescan.org/tx/0x4cea83814be11de2c963ad98d46719b9bb41eb6c7c9ea50993c5577d047e6600) |
| 7. The thief comes back for the queued withdrawal: `executeWithdraw()` reverts with `NothingPending` | Base Sepolia | simulated call, no transaction |

## How it works
- **`CanaryWatcher`** (Reactive Network). `arm(chainId, token, canary)` subscribes to `Transfer` and `Approval`
  on the bait token with `topic1 = canary`, so only events signed by the canary reach `react()`.
  `protect(key, vaultChainId, vault)` registers up to 8 vaults per canary, on any chain Reactive supports.
  When the canary trips, `react()` requests one `evacuate()` callback per vault and latches, so a sweeper
  that sends ten transactions costs one round of callbacks. `reset(key)` re-enables it after you rotate seeds.
- **`EscapeVault`** (destination chain). Holds ETH and up to 8 tracked ERC-20s. `evacuate()` is guarded by
  `onlyServiceProvider` (the Reactive callback proxy) and `onlyCallbackSender` (your watcher), and sends everything
  to `coldWallet`, which is immutable: a thief holding the owner key cannot change the escape route.
- **Spending is time-locked** (`requestWithdraw` → wait → `executeWithdraw`). This is what closes the race. A thief
  with the owner key can queue a withdrawal, but has to wait out the delay, and evacuation cancels whatever is
  queued. In the demo the delay is 20 s and the evacuation takes 1 s; in real use you would set hours.
- **`BaitToken`** is only for the demo. In real use the bait is any ERC-20 dust; 1 USDC is plenty.

## What it does not do
- A patient thief who knows about the canary and touches nothing but the vault still has to wait the full
  time-lock in the open, with a `WithdrawalRequested` event on-chain. A second subscription on that event,
  notifying the owner, is the natural next step.
- Native ETH transfers emit no event, so the bait has to be an ERC-20.
- The demo runs one vault on Base Sepolia. Several vaults on several chains are covered by the tests
  (`test_oneCanaryProtectsVaultsOnSeveralChains`), not by the live run.

## Tests
```bash
npm install
npx hardhat test solidity     # 12 tests: full bait → react → callback → evacuation loop, Approval trips too,
                              # other senders ignored, one trip per reset, several vaults on several chains,
                              # auth on evacuate/react, time-locked spending, thief with the owner key loses the race
```

## Deploy and live demo
```bash
# .env: DEPLOYER_PRIVATE_KEY=0x... funded with ~0.01 Base Sepolia ETH. A throwaway CANARY_PRIVATE_KEY is generated.
node --experimental-strip-types scripts/canary.ts faucet   # Base Sepolia ETH -> lREACT on Lasna
node --experimental-strip-types scripts/canary.ts deploy   # watcher on Lasna; bait + vault on Base Sepolia; arm; protect
node --experimental-strip-types scripts/canary.ts spend    # ordinary payment, time-locked
node --experimental-strip-types scripts/canary.ts settle   # ...executes after the delay
node --experimental-strip-types scripts/canary.ts trip     # thief queues a withdrawal and sweeps the bait -> evacuation
node --experimental-strip-types scripts/canary.ts after    # the queued withdrawal is gone
```
Addresses and transaction hashes are written to `deployments.json`. The keys in the demo are throwaway testnet keys.

### Live monitor
`web/index.html` is a dependency-free page that reads both chains over public RPC: bait balance, vault state,
cold-wallet balance and a timeline where every line links to its transaction.
```bash
npx serve .        # or any static server at the repo root, then open /web/
```

## Two things worth knowing if you build on Omni
- Lasna rejects a zero priority fee, and viem estimates exactly zero on a quiet chain: pass explicit fees.
- Public Base Sepolia RPCs cap `eth_getLogs` at 200 blocks, which is 40 s now that blocks are 200 ms. The script
  scans forward in windows and the monitor reads state with `eth_call`.

## Layout
- `contracts/CanaryWatcher.sol`: reactive contract, subscriptions and callback requests.
- `contracts/EscapeVault.sol`: time-locked vault and callback receiver.
- `contracts/BaitToken.sol`: demo bait.
- `contracts/lib/reactive-lib/`: vendored from Reactive-Network/reactive-lib-omni.
- `scripts/canary.ts`: deploy and demo (viem).
- `web/index.html`: live monitor.

## License
MIT
