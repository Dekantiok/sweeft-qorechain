# SWEEFT

## Technical Implementation Blueprint

**Project:** Decentralized Commerce and Trust Ecosystem\
**Blockchain:** QoreChain\
**Backend:** Python / Django\
**Frontend:** Django Templates, Tailwind CSS, HTMX\
**Smart Contracts:** Solidity / Foundry\
**AI Infrastructure:** Baseten (replaceable provider integration)\
**Database:** PostgreSQL\
**Architecture:** Modular Monolith with On-chain Settlement

------------------------------------------------------------------------

# 1. Implementation Objectives

Sweeft will be implemented as a commerce ecosystem connecting buyers,
sellers, payment infrastructure, fulfilment verification and
programmable escrow.

The implementation has five primary objectives:

1.  Enable buyers and sellers to discover products and initiate
    transactions.
2.  Secure transactions through programmable escrow.
3.  Verify fulfilment through an oracle and attestation system.
4.  Build commercial reputation from completed and verified
    transactions.
5.  Integrate AI to simplify commerce workflows without giving AI
    control over funds.

The system will use Django for application logic and user interfaces,
while Solidity contracts deployed on QoreChain handle critical on-chain
operations.

## Core implementation principle

**Django coordinates the application. Smart contracts enforce financial
rules. QoreChain provides the blockchain infrastructure.**

AI assists users but does not independently authorize financial
transactions.

------------------------------------------------------------------------

# 2. System Architecture

Sweeft will use a modular monolithic architecture.

There will be:

-   One Django application.
-   One PostgreSQL database.
-   One Django template-based frontend.
-   One Solidity smart-contract project.
-   A collection of external integrations.
-   One AI provider adapter that can be replaced without rewriting the
    application.

### High-level architecture

``` text
                       USERS
                         |
          +--------------+--------------+
          |              |              |
       Browser        AI Chat        WhatsApp
          |              |              |
          +--------------+--------------+
                         |
                  DJANGO APPLICATION
                         |
      +------------------+------------------+
      |                  |                  |
  Sweeft Market      Sweeft Vault       Sweeft AI
      |                  |                  |
      |             Escrow Engine           |
      |                  |                  |
      +------------------+------------------+
                         |
              BUSINESS LOGIC LAYER
                         |
       +-----------------+-----------------+
       |                 |                 |
   Sweeft Cred       Sweeft Oracle     Notifications
       |                 |                 |
       +-----------------+-----------------+
                         |
                  BLOCKCHAIN LAYER
                         |
                    QORECHAIN
                         |
       +-----------------+-----------------+
       |                 |                 |
  Vault Contract    Oracle Registry   Cred Registry
       |
  PQC Authorization
       |
  QoreChain Infrastructure
```

The Django application communicates with smart contracts through a
dedicated blockchain integration module.

External services such as payment providers, logistics providers and AI
models must be accessed through adapters.

This makes it possible to replace providers without redesigning the core
business logic.

------------------------------------------------------------------------

# 3. Repository Structure

Use a single GitHub repository.

``` text
sweeft/
│
├── config/
│   ├── settings/
│   │   ├── base.py
│   │   ├── development.py
│   │   └── production.py
│   ├── urls.py
│   ├── asgi.py
│   └── wsgi.py
│
├── apps/
│   ├── participants/
│   ├── marketplace/
│   ├── commerce/
│   ├── escrow/
│   ├── reputation/
│   ├── oracle/
│   ├── governance/
│   ├── ai/
│   ├── notifications/
│   └── blockchain/
│
├── templates/
│   ├── base.html
│   ├── components/
│   ├── marketplace/
│   ├── escrow/
│   ├── reputation/
│   ├── oracle/
│   ├── governance/
│   └── dashboard/
│
├── static/
│   ├── css/
│   ├── js/
│   └── images/
│
├── integrations/
│   ├── qorechain/
│   ├── payments/
│   ├── logistics/
│   └── ai_providers/
│
├── contracts/
│   ├── src/
│   ├── test/
│   ├── script/
│   └── foundry.toml
│
├── tests/
│   ├── integration/
│   └── e2e/
│
├── docs/
│   ├── architecture.md
│   ├── contracts.md
│   ├── api.md
│   └── security.md
│
├── .env.example
├── Dockerfile
├── docker-compose.yml
├── manage.py
├── requirements.txt
└── README.md
```

### Application boundaries

  Django app      Responsibility
  --------------- ------------------------------------------------------
  participants    Participant profiles, roles and wallet associations
  marketplace     Product/service listings and discovery
  commerce        Orders and commercial transaction records
  escrow          Escrow lifecycle and settlement coordination
  reputation      Buyer and seller trust scores
  oracle          Fulfilment evidence and verification
  governance      Sweeft-specific governance
  ai              AI conversations, tool execution and orchestration
  notifications   Email and transaction notifications
  blockchain      Contract interaction and blockchain event processing

Keep business logic inside the relevant Django apps. Do not turn
`integrations/` into another application layer containing business
rules.

------------------------------------------------------------------------

# 4. Implementation of Sweeft Components

## 4.1 Sweeft Market

**Purpose:** Provide the environment where buyers and sellers discover
and transact.

### Features

-   Product and service listings.
-   Seller profiles.
-   Product descriptions and images.
-   Pricing and availability.
-   Search and filtering.
-   Product detail pages.
-   Initiate purchase.
-   Create an escrow transaction from a listing.

### Core models

**Listing**

-   seller
-   title
-   description
-   category
-   price
-   currency
-   availability
-   images
-   status
-   created_at

**Category**

-   name
-   description

**ListingImage**

-   listing
-   image
-   uploaded_at

### Workflow

``` text
Seller creates listing
        |
Listing becomes available
        |
Buyer discovers listing
        |
Buyer initiates purchase
        |
Escrow transaction created
        |
Buyer funds escrow
```

The marketplace should not independently manage funds. Financial
operations must go through Sweeft Vault.

## 4.2 Sweeft Vault

**Purpose:** Secure transactions through programmable escrow.

This is the most important component of the MVP.

### Escrow lifecycle

``` text
CREATED
   |
AWAITING_DEPOSIT
   |
FUNDED
   |
SELLER_NOTIFIED
   |
FULFILMENT_PENDING
   |
DELIVERED
   |
INSPECTION
   |
RELEASE_ELIGIBLE
   |
COMPLETED
```

Additional states:

-   CANCELLED
-   REFUNDED
-   EXPIRED

### Transaction information

Each escrow must contain:

-   Unique transaction identifier.
-   Buyer wallet address.
-   Seller wallet address.
-   Product or service description.
-   Agreed amount.
-   Token or currency.
-   Inspection duration.
-   Creation timestamp.
-   Funding timestamp.
-   Fulfilment status.
-   Verification reference.
-   Contract address.
-   Transaction hashes.

### Core contract: `SweeftVault.sol`

Responsibilities:

1.  Create escrow.
2.  Accept buyer deposits.
3.  Record transaction state.
4.  Notify or expose funding status.
5.  Accept fulfilment verification.
6.  Enforce inspection conditions.
7.  Release funds to the seller.
8.  Refund funds when permitted by agreed contract rules.

### Critical settlement rule

Funds must not be released simply because a timer expires.

The contract must enforce the agreed fulfilment conditions.

For the MVP:

-   Buyer confirms receipt: release becomes eligible.
-   Valid oracle attestation confirms fulfilment: release becomes
    eligible after the agreed inspection period.
-   If fulfilment is not verified, the escrow remains locked.

A full dispute-resolution system is outside the initial MVP scope.

### Security requirements

-   Only the buyer can fund their escrow.
-   Only authorized parties can perform their permitted actions.
-   Seller cannot release funds to themselves.
-   Escrow terms cannot be silently modified after funding.
-   Prevent duplicate deposits and releases.
-   Use checks-effects-interactions or reentrancy protection.
-   Emit events for important state transitions.

## 4.3 Sweeft Oracle

**Purpose:** Verify real-world fulfilment and provide evidence that can
be used by the escrow contract.

Blockchain transactions can prove that an event was recorded. They
cannot independently prove that a physical product was delivered.

Sweeft Oracle bridges that gap.

### Verification sources

For the MVP:

1.  Buyer delivery confirmation.
2.  Seller fulfilment confirmation.
3.  Authorized independent verifier.
4.  Logistics-provider confirmation, where available.

AI may assist in assessing submitted evidence, but AI-generated
conclusions must not automatically count as trusted oracle attestations.

### Core model: `FulfilmentEvidence`

-   escrow
-   submitted_by
-   evidence_type
-   evidence_reference
-   description
-   verification_status
-   submitted_at

### Core contract: `SweeftOracleRegistry.sol`

Responsibilities:

-   Register authorized verifiers.
-   Record fulfilment attestations.
-   Associate attestations with escrow IDs.
-   Validate authorized attestation submissions.
-   Emit verification events.

### MVP verification flow

``` text
Seller submits fulfilment evidence
              |
       Oracle receives evidence
              |
     Verification is performed
              |
       Authorized verifier
        approves evidence
              |
    Attestation recorded on-chain
              |
      Vault checks attestation
              |
       Release becomes eligible
```

The initial version can use a controlled verifier account. A
decentralized multi-provider oracle network is a future improvement.

## 4.4 Sweeft Cred

**Purpose:** Establish commercial trust using transaction history and
verified behaviour.

Sweeft Cred should measure actual commercial performance rather than
simply allowing users to give one another arbitrary ratings.

### Reputation dimensions

  Metric                       Proposed weight
  -------------------------- -----------------
  Successful fulfilment                    40%
  Completed transactions                   25%
  Buyer feedback                           20%
  Verification reliability                 15%

These are initial configurable weights, not permanent protocol rules.

### Core model: `ReputationProfile`

-   participant
-   total_transactions
-   successful_transactions
-   cancelled_transactions
-   verified_fulfilments
-   average_feedback
-   trust_score
-   updated_at

### Core contract: `SweeftCredRegistry.sol`

Responsibilities:

-   Record verified commercial outcomes.
-   Associate reputation updates with participant addresses.
-   Prevent duplicate transaction scoring.
-   Expose reputation data for other applications.

### Important rule

Only eligible, verified commercial events should influence the score.

A transaction should not be counted as successful simply because a user
marked it as completed without satisfying the relevant verification
rules.

## 4.5 Sweeft AI

**Purpose:** Make commerce easier through natural-language interaction.

AI should function as a commerce assistant, not as the authority
controlling transactions.

### MVP capabilities

-   Create a listing through conversation.
-   Describe an intended purchase.
-   Extract transaction details.
-   Identify missing information.
-   Generate an escrow draft.
-   Explain transaction conditions.
-   Check escrow status.
-   Guide users through funding and fulfilment.
-   Answer questions about reputation and verification.

### Example interaction

Buyer:

> "I want to buy a laptop from Daniel for ₦450,000. He will deliver it
> within three days."

AI extracts:

``` json
{
  "item": "Laptop",
  "seller": "Daniel",
  "amount": 450000,
  "currency": "NGN",
  "delivery_period": "3 days"
}
```

The system identifies missing information:

-   Seller identity or wallet association.
-   Buyer identity or wallet association.
-   Inspection duration.
-   Payment method.

AI asks for the missing details and creates a draft.

The buyer reviews the transaction and explicitly authorizes its
creation.

### AI tool architecture

Expose controlled application functions:

``` text
create_listing_draft()
search_listings()
create_escrow_draft()
get_escrow_status()
get_reputation()
submit_fulfilment_evidence()
confirm_receipt()
```

These tools should call Django services, not directly execute arbitrary
smart-contract transactions.

Financial authorization must remain outside the AI model.

### AI provider architecture

Use a provider adapter:

``` text
apps/ai/
    services/
        orchestrator.py
        tools.py
        conversation.py

integrations/ai_providers/
    base.py
    baseten.py
```

Baseten is the initial provider. The adapter allows a different
inference provider to be introduced later.

## 4.6 Sweeft DAO

**Purpose:** Govern Sweeft-specific application policies.

QoreChain already has network-level governance. Sweeft DAO should not
attempt to duplicate it.

### Sweeft governance scope

-   Oracle verifier approval.
-   Application fee policies.
-   Treasury allocation.
-   Reputation parameters.
-   Ecosystem grants.
-   Sweeft contract upgrades, where upgradeability is used.

### MVP implementation

Start with a simple governance interface and proposal registry.

Do not introduce a complicated governance token, speculative tokenomics
or elaborate voting mechanisms into the initial build.

The DAO can be expanded after the core commerce infrastructure works.

------------------------------------------------------------------------

# 5. QoreChain Integration

QoreChain is the underlying blockchain infrastructure.

Sweeft should integrate with its identity, wallet, transaction and
post-quantum security capabilities instead of recreating them.

### Integration responsibilities

**Identity and wallet**

-   Support QoreChain wallet addresses.
-   Associate participant profiles with wallet addresses.
-   Use supported QoreChain identity/sign-in mechanisms where practical.

**Smart contracts**

-   Deploy Sweeft contracts to Diana Testnet.
-   Interact with contracts through Web3.py.
-   Read contract events and transaction receipts.
-   Store transaction hashes and contract references.

**Post-quantum security**

-   Investigate the documented QoreChain quantum-ready EVM authorization
    workflow.
-   Implement a narrowly scoped authorization mechanism for sensitive
    contract operations.
-   Verify post-quantum authorization using the documented QoreChain
    mechanism.
-   Demonstrate the mechanism in a real transaction.

Do not assume that an ordinary EVM transaction automatically has
post-quantum protection.

The exact QoreChain precompile interface, authorization sequence and
network availability must be confirmed against the current official
documentation before implementation.

### Integration module

``` text
integrations/qorechain/
    client.py
    accounts.py
    transactions.py
    contracts.py
    events.py
    pqc.py
```

Keep QoreChain-specific functionality isolated from the main escrow
business logic.

This makes the application easier to test and potentially portable to
another EVM-compatible network.

------------------------------------------------------------------------

# 6. Payment Architecture

Payments should be decoupled from the escrow business logic.

Create a provider interface:

``` python
class PaymentProvider:

    def create_payment(self, transaction):
        raise NotImplementedError

    def verify_payment(self, reference):
        raise NotImplementedError

    def process_refund(self, reference):
        raise NotImplementedError
```

Possible adapters:

``` text
integrations/payments/
    base.py
    qorechain.py
    paystack.py
```

### Important distinction

A successful Paystack payment is not automatically equivalent to an
on-chain escrow deposit.

The system must explicitly define how fiat payments are converted, held,
reconciled and settled.

For the hackathon MVP, prioritize native QoreChain escrow funding using
a supported token. Treat fiat integration as a separate adapter or
future phase unless the custody and settlement path is fully
implemented.

------------------------------------------------------------------------

# 7. Database Design

PostgreSQL will store application data and off-chain records.

The blockchain remains the source of truth for on-chain escrow balances
and contract-enforced state transitions.

### Principal entities

``` text
Participant
    |
    +---- Listings
    |
    +---- Orders
    |
    +---- Escrows
              |
              +---- FulfilmentEvidence
              |
              +---- Payments
              |
              +---- ReputationEvents
              |
              +---- Notifications
```

### Important design decisions

-   Store wallet addresses as participant identifiers for blockchain
    operations.
-   Store contract addresses and transaction hashes.
-   Maintain an event-processing record to prevent duplicate event
    handling.
-   Never store private keys in ordinary database fields.
-   Avoid storing unnecessary sensitive user information.
-   Store references to evidence rather than putting large files
    directly on-chain.

------------------------------------------------------------------------

# 8. Frontend Implementation

Use Django Templates.

There is no separate React or TypeScript frontend application.

### Frontend stack

-   Django Templates.
-   Tailwind CSS.
-   HTMX for partial page updates.
-   Alpine.js for lightweight browser interactions.
-   Minimal JavaScript for wallet connections and other browser-specific
    integrations.

### Main pages

  Page                 Purpose
  -------------------- --------------------------------------------
  Landing page         Explain Sweeft and its ecosystem
  Marketplace          Browse products and services
  Listing detail       View seller and product information
  Create listing       Publish a product or service
  Dashboard            View transactions and activities
  Escrow detail        View terms, funding and transaction status
  Reputation profile   Display buyer/seller trust information
  Oracle dashboard     Review fulfilment evidence
  Governance           View proposals and decisions
  AI assistant         Natural-language commerce interface

### Design direction

Sweeft should look like a serious commerce infrastructure product rather
than a generic blockchain dashboard.

Prioritize:

-   Clear transaction status.
-   Visible escrow protection.
-   Understandable payment conditions.
-   Seller credibility.
-   Simple transaction creation.
-   Clear distinction between on-chain and off-chain activity.

------------------------------------------------------------------------

# 9. API Design

Django should expose APIs for internal integrations and external access.

Suggested endpoints:

### Marketplace

``` text
GET    /api/marketplace/listings/
POST   /api/marketplace/listings/
GET    /api/marketplace/listings/{id}/
```

### Commerce

``` text
POST   /api/commerce/orders/
GET    /api/commerce/orders/{id}/
```

### Escrow

``` text
POST   /api/escrow/
GET    /api/escrow/{id}/
POST   /api/escrow/{id}/fund/
POST   /api/escrow/{id}/confirm-receipt/
POST   /api/escrow/{id}/release/
```

### Oracle

``` text
POST   /api/oracle/evidence/
GET    /api/oracle/evidence/{id}/
POST   /api/oracle/evidence/{id}/verify/
```

### Reputation

``` text
GET    /api/cred/{wallet_address}/
GET    /api/cred/{wallet_address}/history/
```

### AI

``` text
POST   /api/ai/chat/
POST   /api/ai/tools/execute/
GET    /api/ai/conversations/{id}/
```

These endpoints are an initial interface proposal. Use Django services
for the actual business operations so template views, APIs and AI tools
all share the same logic.

------------------------------------------------------------------------

# 10. Security and Authorization

Security is particularly important because Sweeft coordinates financial
transactions.

### Application security

-   Validate all incoming data.
-   Protect state-changing requests against CSRF.
-   Rate-limit OTP and sensitive endpoints.
-   Verify payment-provider webhooks.
-   Use idempotency keys for payment and escrow operations.
-   Verify wallet ownership before associating an address with a
    participant.
-   Do not trust frontend transaction status.
-   Do not trust AI-generated authorization decisions.

### Smart-contract security

-   Enforce role-based access control.
-   Validate escrow state transitions.
-   Prevent reentrancy.
-   Prevent double withdrawals.
-   Validate oracle authorization.
-   Protect against duplicate attestations.
-   Emit events for critical actions.
-   Test unauthorized calls and invalid state transitions.

### AI security

AI must not:

-   Transfer funds without explicit user authorization.
-   Change funded escrow terms.
-   Bypass inspection requirements.
-   Approve its own oracle attestations.
-   Override contract restrictions.
-   Treat untrusted user input as system instructions.

AI can prepare an action. The user must authorize it, and the contract
must independently enforce its rules.

------------------------------------------------------------------------

# 11. Development and Testing Strategy

Use Foundry for Solidity development and testing.

Use Django's testing framework for application logic.

### Smart-contract tests

At minimum:

1.  Create escrow.
2.  Fund escrow.
3.  Reject unauthorized funding.
4.  Reject unauthorized release.
5.  Verify fulfilment attestation.
6.  Reject unregistered oracle.
7.  Release funds after valid conditions.
8.  Reject duplicate release.
9.  Reject invalid state transitions.
10. Verify post-quantum authorization requirements.

### Django tests

Test:

-   Listing creation.
-   Order creation.
-   Escrow draft validation.
-   Wallet association.
-   Contract interaction services.
-   Blockchain event processing.
-   Oracle evidence submission.
-   Reputation calculations.
-   AI tool execution.
-   Payment webhook verification.

### End-to-end test

The most important test is a complete transaction:

``` text
Seller publishes product
          |
Buyer creates order
          |
Escrow contract is created
          |
Buyer deposits funds
          |
Seller receives notification
          |
Seller fulfils order
          |
Oracle verifies fulfilment
          |
Inspection conditions are satisfied
          |
Smart contract releases funds
          |
Sweeft Cred records outcome
```

This should work on Diana Testnet before spending significant time on
secondary features.

------------------------------------------------------------------------

# 12. Implementation Roadmap

The project should be implemented in the following order.

## Phase 1 --- Foundation

**Goal:** Establish the development environment.

Tasks:

-   Create GitHub repository.
-   Set up Django.
-   Configure PostgreSQL.
-   Configure environment variables.
-   Create modular Django apps.
-   Configure Tailwind CSS.
-   Set up Foundry.
-   Connect to QoreChain Diana Testnet.
-   Create a reusable blockchain client.

**Deliverable:** Running Django application connected to QoreChain.

## Phase 2 --- Sweeft Vault

**Goal:** Build the financial foundation.

Tasks:

-   Implement `SweeftVault.sol`.
-   Implement escrow state machine.
-   Add funding and release conditions.
-   Write Foundry tests.
-   Deploy to Diana Testnet.
-   Connect Django to the deployed contract.
-   Display contract state in Django templates.

**Deliverable:** Working on-chain escrow.

This phase takes priority over marketplace design.

## Phase 3 --- Sweeft Market

**Goal:** Connect commerce to escrow.

Tasks:

-   Implement participants and wallet associations.
-   Implement listings.
-   Implement orders.
-   Build marketplace templates.
-   Connect purchase initiation to escrow creation.

**Deliverable:** Buyer can purchase a listed product through escrow.

## Phase 4 --- Sweeft Oracle

**Goal:** Verify fulfilment.

Tasks:

-   Implement evidence submission.
-   Create verifier registry.
-   Implement attestation contract.
-   Connect verification to Vault.
-   Test release eligibility.

**Deliverable:** Verified fulfilment can trigger contract-enforced
settlement.

## Phase 5 --- Sweeft Cred

**Goal:** Build commercial reputation.

Tasks:

-   Implement reputation event records.
-   Calculate trust scores.
-   Connect verified outcomes to reputation updates.
-   Deploy reputation registry.
-   Display participant reputation.

**Deliverable:** Buyers and sellers have verifiable commercial
histories.

## Phase 6 --- Sweeft AI

**Goal:** Introduce intelligent commerce coordination.

Tasks:

-   Configure Baseten.
-   Implement AI provider adapter.
-   Implement structured data extraction.
-   Create controlled AI tools.
-   Implement listing and escrow drafts.
-   Add transaction-status queries.
-   Require explicit authorization before sensitive actions.

**Deliverable:** Users can initiate and manage commerce through natural
language.

## Phase 7 --- Sweeft DAO and Final Integration

**Goal:** Complete the ecosystem demonstration.

Tasks:

-   Implement proposal registry.
-   Build governance interface.
-   Connect all components.
-   Complete security testing.
-   Deploy final contracts.
-   Document architecture.
-   Record demonstration video.
-   Prepare hackathon submission.

**Deliverable:** Integrated Sweeft demonstration.

------------------------------------------------------------------------

# 13. Hackathon MVP Priorities

Not every component needs to be equally sophisticated.

The following priorities keep the project achievable.

  -----------------------------------------------------------------------
  Component               MVP priority            Implementation
  ----------------------- ----------------------- -----------------------
  Sweeft Vault            Critical                Functional
                                                  smart-contract escrow

  QoreChain integration   Critical                Real testnet deployment

  PQC integration         Critical                Demonstrable
                                                  quantum-ready
                                                  authorization

  Sweeft Oracle           Critical                Authorized fulfilment
                                                  attestation

  Sweeft Market           High                    Basic product listings
                                                  and orders

  Sweeft Cred             High                    Reputation based on
                                                  verified events

  Sweeft AI               High                    Natural-language
                                                  transaction creation

  Sweeft DAO              Low                     Basic proposal registry
                                                  and interface
  -----------------------------------------------------------------------

### What not to build initially

Avoid spending time on:

-   Separate React frontend.
-   Native mobile applications.
-   Complex tokenomics.
-   Cross-chain transactions.
-   A large logistics network.
-   Fully decentralized oracle consensus.
-   Full dispute arbitration.
-   Multiple AI agents.
-   Microservices.
-   A custom blockchain identity system.
-   An elaborate governance voting economy.

These can become future development areas.

------------------------------------------------------------------------

# 14. Demonstration Scenario

The final demonstration should tell one coherent story.

### Scenario: Buying a laptop through Sweeft

**Step 1 --- Discovery**

A seller lists a laptop on Sweeft Market.

**Step 2 --- Transaction creation**

A buyer discovers the listing and initiates a purchase.

Alternatively, the buyer describes the intended transaction to Sweeft
AI, which prepares an escrow draft.

**Step 3 --- Agreement**

Buyer and seller review the transaction details and agree to the terms.

**Step 4 --- Escrow funding**

The buyer funds the escrow through Sweeft Vault.

The transaction is recorded on QoreChain.

**Step 5 --- Fulfilment**

The seller receives confirmation and delivers the laptop.

**Step 6 --- Verification**

The delivery is confirmed through Sweeft Oracle.

**Step 7 --- Settlement**

After the agreed inspection conditions are satisfied, the contract
releases the funds to the seller.

**Step 8 --- Reputation**

Sweeft Cred records the successful transaction.

The buyer and seller now have an additional verified commercial record.

**Step 9 --- Governance**

The demonstration can show how Sweeft DAO manages application-level
policies, such as approving a new oracle verifier.

This single scenario demonstrates the relationship between the entire
ecosystem.

------------------------------------------------------------------------

# 15. Final Definition of Done

Sweeft should not be considered complete merely because the website
works.

The hackathon MVP is complete when:

-   [ ] Django application runs successfully.
-   [ ] Marketplace listings can be created.
-   [ ] Buyers can initiate transactions.
-   [ ] Escrow contracts are deployed to QoreChain.
-   [ ] Buyers can fund escrow.
-   [ ] Seller and buyer permissions are enforced.
-   [ ] Fulfilment evidence can be submitted.
-   [ ] Authorized oracle attestations are recorded.
-   [ ] Contract conditions control fund release.
-   [ ] Reputation updates from verified outcomes.
-   [ ] AI can create validated transaction drafts.
-   [ ] AI cannot independently authorize financial settlement.
-   [ ] QoreChain's post-quantum mechanism is demonstrably integrated.
-   [ ] Tests cover critical contract and application operations.
-   [ ] README explains setup, architecture and deployment.
-   [ ] Demo demonstrates an actual testnet transaction.

------------------------------------------------------------------------

# 16. Architectural Decisions to Preserve

1.  **Django Templates remain the frontend.** No separate
    React/TypeScript application for the MVP.
2.  **Django remains a modular monolith.** No premature microservices.
3.  **Solidity contracts enforce financial rules.** Django does not
    become the authority over on-chain funds.
4.  **QoreChain provides identity and blockchain infrastructure.**
    Sweeft does not build a competing chain identity system.
5.  **AI is an assistant, not a financial authority.**
6.  **Oracle verification is distinct from AI assessment.**
7.  **Payment providers remain replaceable.**
8.  **Sweeft Cred uses verified commercial activity.**
9.  **Sweeft DAO governs Sweeft, not QoreChain.**
10. **The MVP prioritizes one complete, verifiable commerce transaction
    over numerous unfinished features.**

## Final implementation philosophy

Build Sweeft as one connected system, not seven independent products.

The marketplace creates demand. Vault protects the transaction. Oracle
verifies fulfilment. Cred establishes trust. AI simplifies interaction.
DAO governs the ecosystem. QoreChain provides the underlying
infrastructure.

**The first milestone is simple: a buyer must be able to purchase a
product, fund an on-chain escrow, receive verified fulfilment and
release payment under rules enforced by a QoreChain smart contract.**

Everything else should build around that working transaction.
