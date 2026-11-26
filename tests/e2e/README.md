# E2E tests

Two tiers:

1. **`test_smoke.py`** (this directory, runs in CI) — Django test client
   covering the judge journey: marketplace renders, escrow detail renders,
   `/api/v1/` reflects the same rows, `/security/` renders with the
   relayer-health card. Run: `python manage.py test tests.e2e.test_smoke`

2. **Browser/wallet flows** (not in CI) — the Playwright suite that drove
   the 32/32 result against v8 (`docs/deployments.md`) exercised real
   QoreX/MetaMask signing against Diana. It needs testnet keys and a
   funded wallet, so it stays a manual step:
   `python tools/e2e_marketplace.py` (on-chain flow) and the scripts in
   `tools/e2e_*.py`. Re-run after every deploy; paste the tx hashes into
   `docs/deployments.md`.
