# Sweeft submission video script (3 minutes)

Format. Screen recording with voiceover. Open the demo, the explorer, and
the proof pages in tabs before recording. Keep the cursor moving. Show real
testnet data only. Total runtime target: 2 minutes 50 seconds.

## 0:00 - 0:20 Opening

You say. "Every payment in Sweeft needs a post-quantum signature that the
chain verifies. A stolen classical key moves nothing."

On screen. Landing page, intro left, paths grid right. Scroll the hero
slowly so the judges see both columns. Then point at the vault address
line. Name both address forms, EVM hex and qor1.

## 0:20 - 0:50 The problem and the lifecycle

You say. "This is a commerce ecosystem. A buyer finds an item, funds an
escrow, the seller ships it, a carrier and verifiers prove delivery, and
only then does the buyer's ML-DSA-87 signature release the money."

On screen. Play the story section on the landing page. Let it auto-step
through all four steps. Pause on step 4 where the seller receives 0.098 of
0.1 QOR after the 2 percent fee.

## 0:50 - 1:20 Live purchase on the demo

You say. "Here is the same flow live on Diana."

On screen. Open the marketplace. Open a listing. Follow the buy path as
far as wallet connection allows on camera. If a wallet is not connected,
show the connect dialog and point at the QoreX option and the note about
QoreX needing testnet mode.

## 1:20 - 1:50 Proof on-chain

You say. "Don't trust the page. Check the chain."

On screen. Switch to the explorer tab with the v8 vault, then open the
two recorded releases in docs/deployments.md. Show escrow completed and
the seller credited 0.098 QOR. Open a proof URL such as /proof/escrow/1/
and read the fields on screen, signature tier, nonce, eligibility.

## 1:50 - 2:20 The AI agent

You say. "The AI finds items, negotiates, and buys inside a mandate you
create. It cannot release funds, attest delivery, or loosen its own
limits. The signed release binds recipient, amount, and nonce."

On screen. Open the AI page. Show the mandate caps, then the chat. Ask
the assistant to find an item under a budget and show the draft it
returns. Then open the escrow page and show the Autopilot pre-authorization
block. Say the sentence about the contract deciding and the AI only
submitting.

## 2:20 - 2:50 Governance and disputes

You say. "Governance is stake-weighted with a timelock and a guardian
veto, and the dispute board is random staked panels with a real appeal.
No single party moves money."

On screen. Open governance, then disputes, then the security page. Point
at the relayer health card and the gates table. End on the security page
with the sentence about wrong-key and tampered releases reverting on
testnet.

## Closing card (last 10 seconds, text on screen)

Sweeft. Post-quantum commerce on QoreChain.
Live on Diana. Vault 0x820C...869a.
Demo https://sweeft-qorechain.onrender.com/
