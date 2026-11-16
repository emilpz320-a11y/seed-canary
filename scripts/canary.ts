// Deploys SeedCanary to Reactive Lasna + Base Sepolia and runs the demo.
// Usage: node --experimental-strip-types scripts/canary.ts [balances|faucet|deploy|spend|settle|trip|after]
// Needs DEPLOYER_PRIVATE_KEY in .env, funded with Base Sepolia ETH. A throwaway CANARY_PRIVATE_KEY is
// generated on first deploy and appended to .env (testnet only).
import { readFileSync, writeFileSync, appendFileSync, existsSync } from 'node:fs';
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  parseEther,
  formatEther,
  type Abi,
  type Hex,
} from 'viem';
import { baseSepolia } from 'viem/chains';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';

const readEnv = () =>
  Object.fromEntries(
    readFileSync('.env', 'utf8')
      .split(/\r?\n/)
      .filter((l) => l.includes('='))
      .map((l) => l.split('=') as [string, string])
  );
let env = readEnv();
if (!env.CANARY_PRIVATE_KEY) {
  appendFileSync('.env', `\nCANARY_PRIVATE_KEY=${generatePrivateKey()}\n`);
  env = readEnv();
}
const owner = privateKeyToAccount(env.DEPLOYER_PRIVATE_KEY as Hex);
const canary = privateKeyToAccount(env.CANARY_PRIVATE_KEY as Hex);

const lasna = defineChain({
  id: 5318007,
  name: 'Reactive Lasna',
  nativeCurrency: { name: 'lREACT', symbol: 'lREACT', decimals: 18 },
  rpcUrls: { default: { http: ['https://lasna-rpc.rnk.dev/'] } },
  blockExplorers: { default: { name: 'Reactscan', url: 'https://lasna.reactscan.net' } },
});

const BASE_SEPOLIA_CALLBACK_PROXY = '0x476F44b11F5C942c58f4c8E3d0300E5710743585';
const BASE_SEPOLIA_LREACT_FAUCET = '0x2afaFD298b23b62760711756088F75B7409f5967';
const WITHDRAW_DELAY_SECONDS = 20n; // short for the demo; hours in real use
const SHOP = '0x0000000000000000000000000000000000005109';
const THIEF = '0x000000000000000000000000000000000000dEaD';

const artifact = (name: string) =>
  JSON.parse(readFileSync(`artifacts/contracts/${name}.sol/${name}.json`, 'utf8')) as { abi: Abi; bytecode: Hex };
const vaultArt = artifact('EscapeVault');
const watcherArt = artifact('CanaryWatcher');
const baitArt = artifact('BaitToken');

const base = {
  pub: createPublicClient({ chain: baseSepolia, transport: http() }),
  wal: createWalletClient({ account: owner, chain: baseSepolia, transport: http() }),
  canaryWal: createWalletClient({ account: canary, chain: baseSepolia, transport: http() }),
};
const react = {
  pub: createPublicClient({ chain: lasna, transport: http() }),
  wal: createWalletClient({ account: owner, chain: lasna, transport: http() }),
};

// Lasna rejects a zero priority fee, which is what viem estimates on a quiet chain.
const lasnaFees = async () => {
  const tip = 1_000_000_000n;
  return { maxPriorityFeePerGas: tip, maxFeePerGas: (await react.pub.getGasPrice()) * 2n + tip };
};

const state: Record<string, string> = existsSync('deployments.json')
  ? JSON.parse(readFileSync('deployments.json', 'utf8'))
  : {};
const log = (k: string, v: string) => {
  state[k] = v;
  writeFileSync('deployments.json', JSON.stringify(state, null, 2));
  console.log(`${k}: ${v}`);
};
const mined = (hash: Hex) => base.pub.waitForTransactionReceipt({ hash });

async function balances() {
  const [b, r] = await Promise.all([
    base.pub.getBalance({ address: owner.address }),
    react.pub.getBalance({ address: owner.address }),
  ]);
  console.log(`owner ${owner.address}\n  Base Sepolia ${formatEther(b)} ETH\n  Lasna ${formatEther(r)} lREACT`);
}

async function faucet() {
  // 1 Base Sepolia ETH -> 100 lREACT.
  const hash = await base.wal.writeContract({
    address: BASE_SEPOLIA_LREACT_FAUCET,
    abi: [{ type: 'function', name: 'request', stateMutability: 'payable', inputs: [{ name: 'recipient', type: 'address' }], outputs: [] }],
    functionName: 'request',
    args: [owner.address],
    value: parseEther('0.004'),
  });
  await mined(hash);
  log('faucetTx', hash);
}

async function deploy() {
  const cold = privateKeyToAccount(generatePrivateKey()).address; // stands in for a hardware wallet from another seed
  log('canary', canary.address);
  log('coldWallet', cold);

  const watcherHash = await react.wal.deployContract({ abi: watcherArt.abi, bytecode: watcherArt.bytecode, value: parseEther('0.3'), ...(await lasnaFees()) });
  const watcher = (await react.pub.waitForTransactionReceipt({ hash: watcherHash })).contractAddress!;
  log('watcher', watcher);
  log('watcherDeployTx', watcherHash);

  const baitHash = await base.wal.deployContract({ abi: baitArt.abi, bytecode: baitArt.bytecode, args: [canary.address, parseEther('5')] });
  const bait = (await mined(baitHash)).contractAddress!;
  log('bait', bait);
  log('baitDeployTx', baitHash);

  const vaultHash = await base.wal.deployContract({
    abi: vaultArt.abi,
    bytecode: vaultArt.bytecode,
    args: [BASE_SEPOLIA_CALLBACK_PROXY, watcher, cold, WITHDRAW_DELAY_SECONDS],
    value: parseEther('0.002'),
  });
  const vault = (await mined(vaultHash)).contractAddress!;
  log('vault', vault);
  log('vaultDeployTx', vaultHash);

  // Prepay callback fees for the vault at the Base Sepolia callback proxy, and give the canary gas to "be robbed".
  const depositHash = await base.wal.writeContract({
    address: BASE_SEPOLIA_CALLBACK_PROXY,
    abi: [{ type: 'function', name: 'depositTo', stateMutability: 'payable', inputs: [{ name: '', type: 'address' }], outputs: [] }],
    functionName: 'depositTo',
    args: [vault],
    value: parseEther('0.0015'),
  });
  await mined(depositHash);
  log('callbackDepositTx', depositHash);
  await mined(await base.wal.sendTransaction({ to: canary.address, value: parseEther('0.0002') }));

  const armHash = await react.wal.writeContract({
    address: watcher,
    abi: watcherArt.abi,
    functionName: 'arm',
    args: [BigInt(baseSepolia.id), bait, canary.address],
    ...(await lasnaFees()),
  });
  await react.pub.waitForTransactionReceipt({ hash: armHash });
  log('armTx', armHash);
  const key = (await react.pub.readContract({
    address: watcher,
    abi: watcherArt.abi,
    functionName: 'canaryKey',
    args: [BigInt(baseSepolia.id), bait, canary.address],
  })) as Hex;
  const protectHash = await react.wal.writeContract({
    address: watcher,
    abi: watcherArt.abi,
    functionName: 'protect',
    args: [key, BigInt(baseSepolia.id), vault],
    ...(await lasnaFees()),
  });
  await react.pub.waitForTransactionReceipt({ hash: protectHash });
  log('protectTx', protectHash);
}

// Ordinary life: the owner queues a small payment; `settle` executes it after the delay.
async function spend() {
  const hash = await base.wal.writeContract({ address: state.vault as Hex, abi: vaultArt.abi, functionName: 'requestWithdraw', args: [SHOP, parseEther('0.0002')] });
  await mined(hash);
  log('spendRequestTx', hash);
}

async function settle() {
  const hash = await base.wal.writeContract({ address: state.vault as Hex, abi: vaultArt.abi, functionName: 'executeWithdraw' });
  await mined(hash);
  log('spendExecuteTx', hash);
}

// The seed leaks: the thief queues a withdrawal of everything with the owner key and sweeps the bait.
async function trip() {
  const vault = state.vault as Hex;
  const everything = await base.pub.getBalance({ address: vault });
  const queueHash = await base.wal.writeContract({ address: vault, abi: vaultArt.abi, functionName: 'requestWithdraw', args: [THIEF, everything] });
  await mined(queueHash);
  log('thiefQueueTx', queueHash);

  const sweepHash = await base.canaryWal.writeContract({ address: state.bait as Hex, abi: baitArt.abi, functionName: 'transfer', args: [THIEF, parseEther('5')] });
  const swept = await mined(sweepHash);
  log('baitSweepTx', sweepHash);
  const sweptAt = (await base.pub.getBlock({ blockNumber: swept.blockNumber })).timestamp;

  console.log('Waiting for the evacuation callback...');
  const evacuatedEvent = vaultArt.abi.find((x) => x.type === 'event' && x.name === 'Evacuated');
  // Public Base Sepolia RPCs cap eth_getLogs at 200 blocks (40 s of 200 ms blocks), so scan forward in windows.
  let from = swept.blockNumber;
  for (let i = 0; i < 60; i++) {
    const head = await base.pub.getBlockNumber();
    while (from <= head) {
      const to = from + 199n < head ? from + 199n : head;
      const logs = await base.pub.getLogs({ address: vault, event: evacuatedEvent as never, fromBlock: from, toBlock: to });
      if (logs.length > 0) {
        const at = (await base.pub.getBlock({ blockNumber: logs[0]!.blockNumber! })).timestamp;
        log('evacuationTx', logs[0]!.transactionHash!);
        log('evacuationLatencySeconds', String(at - sweptAt));
        log('coldWalletBalance', formatEther(await base.pub.getBalance({ address: state.coldWallet as Hex })));
        return;
      }
      from = to + 1n;
    }
    await new Promise((r) => setTimeout(r, 1500));
  }
  console.log('No evacuation seen yet; check Reactscan for the Tripped event.');
}

// The thief comes back for the queued withdrawal: there is nothing left to take.
async function after() {
  try {
    await base.pub.simulateContract({ account: owner, address: state.vault as Hex, abi: vaultArt.abi, functionName: 'executeWithdraw' });
    console.log('WARNING: the queued withdrawal is still executable');
  } catch {
    log('thiefExecuteBlocked', 'executeWithdraw() reverts with NothingPending: the queued withdrawal died with the evacuation');
  }
}

const cmd = process.argv[2] ?? 'balances';
await balances();
const steps: Record<string, () => Promise<void>> = { faucet, deploy, spend, settle, trip, after };
if (steps[cmd]) await steps[cmd]();
