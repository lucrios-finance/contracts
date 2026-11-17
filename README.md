# Lucrios contracts

Smart contracts of [Lucrios](https://lucrios.finance): trading bot instances
sold as NFTs on Robinhood Chain. Each NFT is one bot instance that trades from
its owner's wallet.

> **Status: unaudited and not deployed.** Do not use these contracts with real
> funds. Interfaces may still change.

## Contracts

| Contract | What it does |
|---|---|
| `BotInstanceNFT` | ERC-721 where each token is one bot instance. Paid mint in rounds (price and supply set by the owner multisig), free mint of a chosen id by the minter (the backend, when an agent is created), credit top-ups, partner revenue share, and pull-based withdrawals. |
| `InstanceArt` | The token metadata, built on-chain: `tokenURI` returns the name, description and an SVG image as a `data:` URI. No server, IPFS or gateway is involved. |
| `InstanceVault` | One vault per NFT, holding everything that belongs to that instance: the quote token, the assets it bought and its liquidity-range NFTs. The current owner of the NFT withdraws anything at any time. Transferring the NFT transfers the vault. |
| `TradeExecutor` | Executes the trades of the instances, moving funds between their vaults and the venues. Charges the volume fee. Not upgradeable. |
| `UniswapV4Adapter` | Swaps directly on a Uniswap v4 pool. A stateless target for the executor's aggregator path. |
| `FeeTierAdapter`, `TickSpacingAdapter` | Build the calls to the position manager of a Uniswap V3 fork, for liquidity ranges. One identifies pools by fee tier (Uniswap V3), the other by tick spacing (Ramses V3). A new fork is a new adapter registered by the multisig. |

### Custody model

Each instance trades from its own vault. The vault address is deterministic
(`executor.vaultOf(tokenId)`), so the owner can deposit before it exists; the
executor creates it on the first trade. ETH sent to the vault is wrapped by
the operator.

To enter, the executor takes the quote token from the vault, swaps and puts
the asset back in the vault; to exit, the reverse. A liquidity range is
minted with the vault as the owner of the position NFT. Between calls the
executor only holds fees that were not withdrawn yet.

The owner of the NFT withdraws from the vault directly, with no call to the
executor, so no executor rule can hold funds back. If the owner withdraws
the asset of an open position, the executor sells what is left; if nothing
is left, the position is dropped.

Only the operator wallet (the backend signer) starts trades. It decides; the
contracts limit and record. What a compromised operator can do is limited
on-chain:

- the result of a trade only goes to the vault of the instance;
- the owner sets a maximum per trade and the markets the instance may trade
  (one by one, or all of them with `anyMarket`), and can pause it; exits are
  always allowed;
- on the direct Uniswap v3 path, the executed price is held to the pool's own
  time-weighted average, within a per-market tolerance;
- on the aggregator path the executor approves exactly the input, only to
  targets approved by the multisig, and measures what came back. Pairs with a
  reference pool are also held to its average price;
- liquidity ranges only go into pools of the factory registered for that
  position manager, and only while the pool's current tick is close to its
  time-weighted average. With single-sided deposits, this keeps a sell order
  above the average price and a buy order below it;
- the fee of a trade is never above `volumeFeeBps`, which the multisig can
  set up to 1%;
- a trade that loses more than a configurable share of its cost pauses the
  instance until its owner re-enables it.

Without a reference pool, a compromised operator can still route one trade
per instance at a bad price before the loss pause stops it, bounded by the
owner's maximum per trade.

### Execution paths

1. **Direct Uniswap v3 pool** — `openPositions` / `closePositions`.
2. **Aggregator** — `openViaAggregator` / `closeViaAggregator`, with a route
   built off-chain. The `UniswapV4Adapter` is one such target.
3. **Liquidity ranges** on any registered Uniswap V3 fork — `openRange` /
   `closeRange`. Used for limit orders (a single-sided range) and liquidity
   provision.

Every trade event carries a `decision`: the hash of the agent's decision
record, published off-chain. Anyone can check that a trade matches the
decision that was published for it.

### Fees

A volume fee on the quote token that enters or leaves each trade, taken from
the trade itself. The operator passes the fee of each trade (zero on partner
venues) and the contract refuses anything above `volumeFeeBps`. Instances
marked `feeExempt` and position venues marked `feeExempt` pay nothing. Fees
accrue as claimable balances and are withdrawn by the treasury.

## Development

Requires [Foundry](https://book.getfoundry.sh/). Dependencies are not vendored:

```bash
forge install foundry-rs/forge-std@v1.17.0 --no-git
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-git
forge install Uniswap/v3-core@0.8 --no-git

forge fmt --check
forge test
```

Compiler: solc 0.8.28, optimizer on (200 runs), via IR (the executor does not
fit in 24 KB without it).

The code comments are in Portuguese.

### Deploying

`script/Deploy.s.sol` deploys `BotInstanceNFT` and `TradeExecutor`, sets the
operator as minter, allows the aggregators and quote tokens, and hands both
contracts to `OWNER` (two-step: the owner calls `acceptOwnership`). Outside a
local chain it refuses an `OWNER` equal to the deployer. Addresses go to
`deployments/<chainid>.json`.

```bash
OWNER=0x… TREASURY=0x… OPERATOR=0x… WETH=0x… VOLUME_FEE_BPS=50 \
AGGREGATORS=0x…,0x… QUOTE_TOKENS=0x… \
forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
```

`script/Local.s.sol` builds a ready local chain for end-to-end tests: mock
WETH, token and aggregator, the contracts, house bot 900001 with its vault
funded and limits set (`deployments/local.json`). CI runs it on anvil, and the
backend runs its vault tests against that chain.

```bash
anvil &
forge script script/Local.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

The TypeScript SDK ([`@lucrios/sdk`](https://github.com/lucrios-finance/sdk))
ships ABIs generated from these contracts; CI fails when they drift apart.

## Security

Found a vulnerability? Please do not open a public issue. Use GitHub's private
vulnerability reporting on this repository.

## License

GPL-2.0-or-later. The contracts use math libraries from Uniswap v3-core, which
are licensed under the same terms.
