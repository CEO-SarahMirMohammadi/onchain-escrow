# Onchain Escrow

## Overview

Onchain Escrow is a Solidity-first escrow system for freelance and service agreements. A buyer funds a fixed-value agreement, a seller completes agreed milestones, and payment becomes available only after buyer approval. Either party can raise a dispute for owner-operated arbitration.

The core business logic lives in Solidity. JavaScript is limited to Hardhat configuration, deployment, and contract tests; there is no frontend or off-chain business-logic service.

## Problem

Freelance work often relies on trust around payment timing and delivery. Buyers risk paying before work is complete, while sellers risk delivering without a reliable path to payment. Informal milestone agreements are difficult to enforce consistently across parties.

## Solution

The escrow contract holds the buyer's full ERC-20 commitment and enforces the agreement's milestone count, fixed milestone value, deadline, participant permissions, and state transitions. Funds are accounted for on-chain and made withdrawable only after an approved milestone or an arbitration outcome.

## Architecture

- `MockUSDC` is a six-decimal ERC-20 for local development. The owner can mint test balances, and each address can claim one faucet allocation.
- `ReentrantMockUSDC` is an adversarial callback token used to verify the escrow's reentrancy guard in tests.
- `Escrow` owns the agreement state machine, custody accounting, dispute outcomes, refund accounting, and seller claimable balances.
- OpenZeppelin Contracts supplies ERC-20, ownership, safe token operations, and reentrancy protection.
- Hardhat compiles and tests the contracts and runs the deployment script. No JavaScript module implements business rules.

## Escrow State Machine

```text
Created -> Funded -> InProgress -> Completed
   |          |          |
   +----------+----------+-> Disputed -> Resolved
   |          |
   +----------+-> Cancelled
```

`Created` can be funded or cancelled by the buyer. `Funded` can be accepted by the seller or cancelled by the buyer before acceptance. Acceptance starts `InProgress`. Approved milestone releases advance the completed count, and the final release sets `Completed`. Either participant may dispute a funded or in-progress escrow. Only the contract owner, acting as arbitrator, may resolve it. Cancelled and resolved buyer amounts are withdrawn through the buyer-initiated refund function.

## Smart Contracts

### MockUSDC

`MockUSDC` implements ERC-20 with six decimals, owner-only `mint(address,uint256)`, and a one-time `faucet()` for local testing. It is a test asset, not a production stablecoin.

### Escrow

`createEscrow` records the buyer, seller, token, total and per-milestone amounts, milestone count, and deadline. The plan requires equal-value milestones whose total exactly matches the escrow amount. Funding is a single exact `SafeERC20.safeTransferFrom` from the buyer.

The contract tracks submitted and approved current milestones, per-milestone submission references, cumulative seller allocations, buyer refunds, and token-denominated seller claims. `getEscrow`, `getUserContribution`, and `getRemainingAmount` expose agreement and accounting views.

## Milestone Flow

1. The buyer creates an agreement with a seller, ERC-20, exact milestone plan, and future deadline.
2. The buyer approves the escrow contract for the token amount and calls `fundEscrow`.
3. The seller accepts before the deadline.
4. The seller submits a nonzero `bytes32` reference to the current milestone before the deadline.
5. The buyer approves that submission.
6. Anyone may call `releaseMilestone`; this credits the seller's pull-payment balance. The seller calls `withdraw(token)` to receive accumulated funds.

Approval and release are separate actions so that the approval is explicit, while payout remains independent of a third-party push transfer.

## Dispute Resolution

The buyer or seller may raise a dispute while the escrow is funded or in progress. The owner is the configured arbitrator and can allocate the remaining escrow balance entirely to the seller, entirely to the buyer, or split it by basis points. Seller allocations become claimable; buyer allocations become refundable. Any milestone allocations made before the dispute remain accounted for and are not part of the remaining balance.

This owner-operated arbitration model is intentionally simple for a portfolio project. Production use should replace or constrain the arbitrator with an agreed governance or independent dispute process.

## Security Model

- `SafeERC20` handles token operations and rejects unsuccessful transfers.
- `Ownable` restricts dispute resolutions and test-token minting.
- `ReentrancyGuard` protects funding, seller withdrawals, and buyer refunds.
- State and claim balances are updated before external token transfers; a failed transfer reverts the complete transaction.
- Explicit role, state, amount, and deadline checks constrain transitions and submissions.
- Seller payments and buyer refunds use pull-based claims rather than unsolicited payout calls.
- The escrow accepts arbitrary ERC-20 tokens; production deployments should apply a token allowlist and account for non-standard or fee-on-transfer assets.

This code is educational and has not been audited. Do not use it to custody production funds without an independent security review.

## Events

The contract emits `EscrowCreated`, `EscrowFunded`, `EscrowAccepted`, `MilestoneSubmitted`, `MilestoneApproved`, `PaymentReleased`, `DisputeRaised`, `DisputeResolved`, `EscrowCancelled`, and `RefundIssued`. `PaymentWithdrawn` records completed seller claims.

## Testing

The single test file covers deployment, token decimals and faucet, creation and funding, seller acceptance, milestone submissions and approvals, sequential milestones, pull payments, cancellation, disputes and all arbitration outcomes, refunds, deadlines, role checks, invalid transitions, repeated or empty claim attempts, and a malicious token callback attempting to reenter funding.

## Installation

Requires Node.js and npm.

```bash
npm install
npm run compile
npm test
```

## Usage

On the local Hardhat network, deploy both contracts with:

```bash
npm run deploy
```

For Sepolia, copy `.env.example` to `.env`, set `SEPOLIA_RPC_URL` and `PRIVATE_KEY`, then run:

```bash
npm run deploy:sepolia
```

The deployment script prints the token and escrow addresses. A buyer must approve the escrow contract to spend the selected token before funding. On a local network, use `MockUSDC.mint` as its owner or claim `faucet()` once per account.

## Project Structure

```text
contracts/
  Escrow.sol
  MockUSDC.sol
scripts/
  deploy.js
test/
  Escrow.test.js
hardhat.config.js
package.json
.env.example
.gitignore
requirements.txt
README.md
LICENSE
```

## Design Decisions

- Equal fixed-value milestones keep agreement arithmetic explicit and prevent the last milestone from silently absorbing a remainder.
- Funding occurs once for the full amount, so the seller's agreed payment is already secured before work begins.
- Releasing a milestone creates a seller claim instead of making an external payment in the approval transaction.
- Arbitration allocates only the amount still held for that escrow; prior milestone claims remain final.
- An escrow deadline limits funding, seller acceptance, and milestone submission. Buyer approval and claims may occur after the deadline.
- `requirements.txt` is present to match the requested project layout; this project has no Python dependencies.

## Future Improvements

- Add an approved-token registry and support safe accounting for unusual ERC-20 implementations.
- Add buyer and seller agreement acceptance, milestone descriptions, and encrypted or content-addressed evidence.
- Replace owner-only arbitration with an appealable decentralized or multi-party arbitration process.
- Add pause controls, formal verification, fuzz and invariant tests, and an independent audit.
- Add deployment verification and network-specific configuration without moving business rules off-chain.

## Resume Description

Built a Solidity-first, milestone-based freelance escrow using OpenZeppelin ERC-20 safety utilities, access control, reentrancy protection, pull payments, and owner-mediated dispute resolution; validated the state machine with Hardhat tests.