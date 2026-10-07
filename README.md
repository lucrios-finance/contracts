# Lucrios contracts

Smart contracts of [Lucrios](https://lucrios.finance): trading bot instances
sold as NFTs on Robinhood Chain. Each NFT is one bot instance that trades from
its owner's wallet.

> **Status: unaudited and not deployed.** Do not use these contracts with real
> funds. Interfaces may still change.

## Contracts

| Contract | What it does |
|---|---|
| `BotInstanceNFT` | ERC-721 where each token is one bot instance. Paid mint in rounds (price and supply set by the owner multisig), credit top-ups, partner revenue share, and pull-based withdrawals. |
| `InstanceArt` | The token metadata, built on-chain: `tokenURI` returns the name, description and an SVG image as a `data:` URI. No server, IPFS or gateway is involved. |
| `TradeExecutor` | Executes the trades of the instances. Funds stay in the owner's wallet; the executor moves them by allowance only for the duration of a swap and sends the result back to the owner. Charges the profit fee above each instance's high-water mark. Not upgradeable. |
| `UniswapV4Adapter` | Swaps directly on a Uniswap v4 pool. A stateless target for the executor's aggregator path, kept outside the contract that holds user allowances. |

### Custody model

The owner of an instance approves the quote token and each traded asset to the
`TradeExecutor`. To enter, the executor pulls the quote token, swaps and returns
the asset to the owner; to exit, it pulls the asset, swaps, takes the fees and
returns the quote token. Between calls the executor only holds fees that were
not withdrawn yet.

Only the operator wallet starts trades. What a compromised operator can do is
limited on-chain:

- the result of a trade only goes to the owner of the instance;
- the owner sets a maximum per trade, the markets the instance may trade, and
  can pause it; exits are always allowed;
- on the direct Uniswap v3 path, the executed price is held to the pool's own
  time-weighted average, within a per-market tolerance;
- on the aggregator path the executor approves exactly the input, only to
  targets approved by the multisig, and measures what came back. Pairs with a
  reference pool are also held to its average price;
- a trade that loses more than a configurable share of its cost pauses the
  instance until its owner re-enables it.

### Execution paths

1. **Direct Uniswap v3 pool** — `openPositions` / `closePositions`.
2. **Aggregator** — `openViaAggregator` / `closeViaAggregator`, with a route
   built off-chain. The `UniswapV4Adapter` is one such target.

### Fees

Protocol fee on new profit above the instance's high-water mark, a partner
share taken out of the protocol fee, and a copy-trade leader fee paid by
followers. Fees accrue as claimable balances and are withdrawn by their
beneficiaries.

## Development

Requires [Foundry](https://book.getfoundry.sh/). Dependencies are not vendored:

```bash
forge install foundry-rs/forge-std@v1.17.0 --no-git
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-git
forge install Uniswap/v3-core@0.8 --no-git

forge fmt --check
forge test
```

Compiler: solc 0.8.28, optimizer on (200 runs).

The code comments are in Portuguese.

The TypeScript SDK ([`@lucrios/sdk`](https://github.com/lucrios-finance/sdk))
ships ABIs generated from these contracts; CI fails when they drift apart.

## Security

Found a vulnerability? Please do not open a public issue. Use GitHub's private
vulnerability reporting on this repository.

## License

GPL-2.0-or-later. The contracts use math libraries from Uniswap v3-core, which
are licensed under the same terms.
