# Sweeft — QCAI audit workspace

Two-stage audit as required for Post-Quantum dApp:

- **Stage 1**: submit the full `contracts/src/` + `contracts/test/` to the
  QoreChain dashboard Contract Auditor (EVM/Solidity setting — NOT the
  CosmWasm + PQC setting, which reports a mismatch for us). Keep the PDF in
  `stage-1/`.
- **Stage 2**: after every Stage 1 finding is fixed (regression test) or
  documented as a false positive in `docs/AUDIT.md`, re-audit with the same
  setting and keep the PDF in `stage-2/`.

The quantum-readiness rating will show "Not scored" for EVM — expected. Our
PQC design (pqcVerify / pqcKeyStatus precompiles at `0x…0a01` / `0x…0a02`,
registration proofs, EVM-window scoping) is documented in `docs/AUDIT.md`.

Stage 1 bundle command:
