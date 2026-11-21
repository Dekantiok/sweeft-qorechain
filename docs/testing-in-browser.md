# Test Sweeft in the browser (Diana testnet)

Everything runs on **QoreChain Diana** (EVM chain ID `9800`). You need an EVM
wallet (MetaMask or the QoreX browser wallet) and one of the demo accounts.

## 1. Start the app

```bash
cd /root/projects/sweeft-qorechain
sudo service postgresql start        # if not running
.venv/bin/python manage.py runserver 127.0.0.1:8001
```

Open **http://127.0.0.1:8001** — the nav shows a **Connect wallet** button.

## 2. Get a wallet account

The demo accounts are derived from the testnet mnemonic in `.env`
(`SWEEFT_DEPLOYER_MNEMONIC`). **Testnet only — never reuse this phrase
anywhere else.**

| Index | Role | EVM address |
|---|---|---|
| 0 | buyer / deployer | `0xcaF82Bd8EBd87634eFb610aE63a7bCf1CE3ac87D` |
| 1 | seller | `0x8508BF11b1C2D225c1727F4C7b75B5e3d3C84cB0` |
| 2 | oracle verifier | `0x9E9745aABd5706291C0D4CA2FD2022B832a875c8` |
| 3–5 | dispute resolvers | `0xe075…cA54`, `0x3726…677e`, `0xB0BD…9646` |

Import the mnemonic into MetaMask (`Import account → Seed phrase`). It derives
the same `0x…` addresses (standard Ethereum path).

Check which account you need per action:

- **Buying** — buyer (index 0)
- **Listing** and **marking delivered** — seller (index 1)
- **Raising a dispute** — buyer or seller of that escrow
- **Joining/voting on the board** — any staked resolver (already staked)

## 3. Connect

Click **Connect wallet** in the nav. A dialog opens with the wallets detected
in your browser:

- **QoreX** — signs the login challenge with your **ML-DSA-87 key**; the server
  verifies it against the key registered on chain. This is the full
  post-quantum experience and is required for the release step.
- **MetaMask / EVM wallet** — connects by `personal_sign`; fine for buying,
  disputes, voting and claiming. Switches to Diana automatically.

Sign the login message and the nav switches to your account menu. No
"install" page — if neither wallet is detected, the dialog says so once and
links to both.

## 4. EVM windows (why transactions get refused)

QoreChain admits EVM transactions only while the account has an **open
authorization window**. Without one, the wallet shows a "refused" error. Open
one for the account you are testing (the tool manages any index):

```bash
# buyer (index 0)
.venv/bin/python tools/qor_account.py window --index 0

# seller (index 1) — needed to create listings / mark delivered
.venv/bin/python tools/qor_account.py window --index 1 --max-value 10000000
```

Check the state any time:

```bash
.venv/bin/python tools/qor_account.py status --index 1
```

Balance low? Transfer QOR from the buyer account (or the faucet, once per 24h
at https://dashboard.qorechain.io/faucet).

## 5. What to try

1. **Marketplace** — open `/marketplace/`, press *Refresh from chain*, open a
   listing, **Buy with escrow** (buyer’s wallet, price goes into the Vault).
2. **Release** — on `/escrow/<id>/` press **Sign release in QoreX**. This one
   is signed with the **ML-DSA-87 post-quantum key**, so it requires the QoreX
   wallet (`signArbitrary`); MetaMask alone cannot do this step. Without
   QoreX you can still run the scripted release:
   `.venv/bin/python tools/e2e_django_relay.py`
3. **Disputes** — on a funded escrow press **Raise dispute** (buyer or seller
   wallet). Then open `/disputes/`, and with a staked resolver wallet
   **Join board** → **Vote** → **Claim resolver reward**.
4. **Governance** — `/governance/` shows executed proposals; the registry,
   vault and dispute board are owned by DAO v2.
5. **Dashboard** — `/dashboard/` shows everything projected from chain events;
   *Refresh from chain* pulls the latest blocks.

## Troubleshooting

| Symptom | Fix |
|---|---|
| “does not admit this transaction” | Open an EVM window (§4) — it expired or the value cap is hit |
| “No EVM wallet found” | Install MetaMask/QoreX; reload the page |
| Transactions land but pages look stale | Press *Refresh from chain* — the indexer runs ~8 blocks behind the tip |
| Faucet says wait | Once per 24h per address; transfer QOR from the buyer account instead |
