# AtomicBridge

## Overview

I've developed `AtomicBridge`, a Clarity smart contract designed to facilitate secure and trustless atomic swaps of assets (SIP-010 tokens) across different blockchains using the principles of Hash-Time Locked Contracts (HTLCs). My primary goal with this contract is to ensure that transactions are truly atomic: either both parties successfully receive their intended assets, or neither transaction occurs, thus eliminating the risk of partial execution and safeguarding participants' funds.

## Features

* **Atomic Swaps:** Guarantees that either both legs of a cross-chain swap complete or neither does.
* **Hash-Time Locked Contracts (HTLCs):** Leverages cryptographic hash locks and time locks for secure asset exchange.
* **SIP-010 Token Compatibility:** Fully integrates with SIP-010 compliant fungible tokens, allowing for broad asset support.
* **Flexible Timeouts:** Allows initiators to define custom timeouts for swaps, with a sensible default.
* **Claim and Refund Mechanisms:** Provides clear pathways for recipients to claim assets with a secret preimage or for initiators to reclaim funds upon expiration.
* **Multi-Asset Swap Capability:** Includes a simplified function for initiating swaps involving multiple distinct assets. (Note: The current implementation focuses on batch identification; full batch processing logic for transfers would be an enhancement).
* **Unique Swap Identification:** Generates unique identifiers for each swap to prevent collisions and ensure traceability.

## How It Works

The `AtomicBridge` contract operates on a simple, yet robust, three-phase HTLC model:

1.  **Initialization (`initialize-swap`):**
    * The **initiator** deposits the agreed-upon amount of SIP-010 tokens into the `AtomicBridge` contract.
    * They provide a `hash-lock` (SHA256 hash of a secret preimage) and specify a `recipient`, `token-contract`, `amount`, and `timeout-block`.
    * The contract stores these details, marking the swap as "active" and generating a unique `swap-id`.

2.  **Claiming (`claim-swap`):**
    * The **recipient** of the swap, who possesses the secret `preimage` corresponding to the `hash-lock`, calls the `claim-swap` function.
    * They provide the `swap-id` and the `preimage`.
    * The contract verifies that:
        * The swap exists and is "active".
        * The swap has not expired.
        * The caller is the designated recipient.
        * The provided `preimage` correctly hashes to the stored `hash-lock`.
        * The provided token contract matches the one in the swap.
    * If all checks pass, the contract transfers the locked tokens to the recipient and updates the swap status to "completed".

3.  **Refunding (`refund-expired-swap`):**
    * If the `timeout-block` is reached and the recipient has *not* claimed the funds, the **initiator** can call the `refund-expired-swap` function.
    * They provide the `swap-id`.
    * The contract verifies that:
        * The swap exists and is "active".
        * The `block-height` is past the `timeout-block`.
        * The caller is the original initiator.
        * The provided token contract matches the one in the swap.
    * If all conditions are met, the contract transfers the locked tokens back to the initiator and updates the swap status to "refunded".

## Constants & Error Codes

I've defined several constants and error codes to manage contract state and provide informative feedback:

* `CONTRACT_OWNER`: The deployer of the contract.
* `DEFAULT_TIMEOUT_BLOCKS`: `u144` (approximately 24 hours assuming 10-minute blocks).
* `ERR_UNAUTHORIZED` (`u100`): Caller is not authorized for the action.
* `ERR_ALREADY_INITIALIZED` (`u101`): Attempted to initialize something that's already set up.
* `ERR_SWAP_NOT_FOUND` (`u102`): No swap found for the given ID.
* `ERR_SWAP_ALREADY_EXISTS` (`u103`): A swap with the generated ID already exists.
* `ERR_SWAP_EXPIRED` (`u104`): The swap's timelock has passed.
* `ERR_INVALID_PREIMAGE` (`u105`): The provided preimage does not match the hash lock.
* `ERR_SWAP_ALREADY_COMPLETED` (`u106`): The swap has already been claimed.
* `ERR_SWAP_ALREADY_REFUNDED` (`u107`): The swap has already been refunded.
* `ERR_INSUFFICIENT_FUNDS` (`u108`): Sender does not have enough tokens.
* `ERR_TOO_EARLY` (`u109`): Attempted to refund before the timeout.
* `ERR_INVALID_TOKEN_LIST` (`u110`): Invalid token list provided for multi-asset swap.
* `ERR_MISMATCHED_LISTS` (`u111`): Token contracts and amounts lists have different lengths.
* `ERR_INVALID_RECIPIENT` (`u112`): Recipient cannot be the sender for multi-asset swap.

## Data Structures

### `swaps` Map

This map stores the details for each individual hash-time locked swap.

```clarity
(define-map swaps
  { swap-id: (buff 32) }
  {
    initiator: principal,         ;; The address that initiated the swap (locked funds)
    recipient: principal,         ;; The intended recipient of the locked funds
    token-contract: principal,    ;; The SIP-010 token contract principal
    amount: uint,                 ;; The amount of tokens locked
    hash-lock: (buff 32),         ;; The SHA256 hash of the secret preimage
    timeout-block: uint,          ;; The block height after which the swap can be refunded
    status: (string-ascii 20),    ;; Current status: "active", "completed", "refunded"
    preimage: (optional (buff 32));; Stores the preimage once the swap is completed
  }
)
```

### `swap-counter` Data Variable

A `define-data-var` that I use to track the total number of swaps created, which helps in generating unique swap IDs.

## Public Functions

I've designed these functions for external interaction with the `AtomicBridge` contract.

### `initialize-swap`

Initiates a new hash-time locked swap by depositing tokens into the contract.

* **Parameters:**
    * `recipient`: The principal address intended to receive the tokens.
    * `token-contract`: A SIP-010 token trait reference (e.g., `'SP133T006M3V2XN5D749B55K5C70G678P.my-token`).
    * `amount`: The amount of tokens to lock.
    * `hash-lock`: A 32-byte buffer representing the SHA256 hash of the secret preimage.
    * `timeout-blocks`: An optional unsigned integer specifying the number of blocks until the swap expires. If `none`, `DEFAULT_TIMEOUT_BLOCKS` is used.
* **Returns:** `(response (buff 32) uint)` - Returns the unique `swap-id` on success, or an error code on failure.

### `claim-swap`

Allows the designated recipient to claim the locked tokens by providing the correct preimage.

* **Parameters:**
    * `swap-id`: The 32-byte buffer identifying the swap.
    * `preimage`: The 32-byte buffer secret that hashes to the `hash-lock`.
    * `token-contract`: A SIP-010 token trait reference, which must match the one stored in the swap.
* **Returns:** `(response bool uint)` - Returns `(ok true)` on successful claim, or an error code on failure.

### `refund-expired-swap`

Enables the initiator to reclaim their tokens if the swap has not been claimed and has expired.

* **Parameters:**
    * `swap-id`: The 32-byte buffer identifying the swap.
    * `token-contract`: A SIP-010 token trait reference, which must match the one stored in the swap.
* **Returns:** `(response bool uint)` - Returns `(ok true)` on successful refund, or an error code on failure.

### `get-swap-details`

A read-only function to retrieve the current details of a specific swap.

* **Parameters:**
    * `swap-id`: The 32-byte buffer identifying the swap.
* **Returns:** `(response (optional { ... }) uint)` - Returns an optional dictionary containing the swap details if found, otherwise `none`.

### `create-multi-asset-swap`

A simplified public function for initiating a batch of swaps involving multiple tokens.

* **Parameters:**
    * `recipient`: The principal address intended to receive all tokens in the batch.
    * `token-contracts`: A list of SIP-010 token trait references (max 10).
    * `token-amounts`: A list of unsigned integers, corresponding to the amounts for each token contract (max 10).
    * `hash-lock`: A 32-byte buffer representing the SHA256 hash of the secret preimage for the entire batch.
    * `timeout-blocks`: An optional unsigned integer specifying the number of blocks until the batch swap expires.
* **Returns:** `(response { batch-id: (buff 32), expiration: uint, token-count: uint } uint)` - Returns a dictionary with `batch-id`, `expiration` block, and `token-count` on success, or an error code on failure.
    * **Note:** This function currently generates a batch ID and validates inputs. For a complete multi-asset HTLC, individual `initialize-swap` calls or a more complex internal batching mechanism would be required within this function. My design here provides a framework for future expansion.

## Usage Example (Conceptual)

### Initiator (Alice) sets up a swap

```clarity
(contract-call? 'SP2J6ZX1982CMZ97T1K277977J7T850B5.atomic-bridge initialize-swap
  'SP3D9J9T677K7C3W8G89Q790F3B84G00C.some-other-contract
  'SP3D9J9T677K7C3W8G89Q790F3B84G00C.my-token
  u1000
  0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
  (some u200)
)
;; This will return a swap-id if successful. Alice shares the hash-lock
;; and swap-id with the recipient (Bob) out-of-band.
```

### Recipient (Bob) claims the swap

Assuming Bob received the `swap-id` and the secret `preimage` (which hashes to `0x123...ef`).

```clarity
(contract-call? 'SP2J6ZX1982CMZ97T1K277977J7T850B5.atomic-bridge claim-swap
  0xabcde... (the actual swap-id)
  0xfedcba... (the actual preimage)
  'SP3D9J9T677K7C3W8G89Q790F3B84G00C.my-token
)
;; If successful, Bob receives the tokens.
```

### Initiator (Alice) refunds an expired swap

If Bob doesn't claim and the timeout passes.

```clarity
(contract-call? 'SP2J6ZX1982CMZ97T1K277977J7T850B5.atomic-bridge refund-expired-swap
  0xabcde... (the actual swap-id)
  'SP3D9J9T677K7C3W8G89Q790F3B84G00C.my-token
)
;; If successful and expired, Alice receives her tokens back.
```

## Deployment

The `AtomicBridge` contract is written in Clarity and can be deployed to the Stacks blockchain. You will need a Stacks development environment and a wallet with sufficient STX to cover gas fees.

## License

This project is licensed under the MIT License - see the `LICENSE` file for details (if applicable, otherwise assume standard open-source intent).

## Contributing

I welcome contributions to enhance the `AtomicBridge` protocol. If you have suggestions, bug reports, or want to contribute code, please follow these steps:

1.  Fork the repository.
2.  Create a new branch for your feature or bug fix.
3.  Write clear, concise code and adhere to Clarity best practices.
4.  Add or update tests to cover your changes.
5.  Submit a pull request with a detailed description of your changes.

## Security

I've made every effort to ensure the security and robustness of this contract. However, smart contracts are complex and can be vulnerable to undiscovered issues. I highly recommend thorough auditing by security professionals before using this contract in a production environment with significant assets.
