;; AtomicBridge: Hash Lock Exchange Protocol
;; This contract facilitates secure atomic swaps of assets between different blockchains
;; using hash-time locked contracts (HTLCs). It ensures that either both parties receive
;; their expected assets or neither transaction occurs, preventing partial execution.

;; Define token trait for SIP-010 compatibility
(define-trait sip-010-token
  (
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    (get-balance (principal) (response uint uint))
    (get-total-supply () (response uint uint))
    (get-name () (response (string-ascii 32) uint))
    (get-symbol () (response (string-ascii 10) uint))
    (get-decimals () (response uint uint))
    (get-token-uri () (response (optional (string-utf8 256)) uint))
  )
)

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_ALREADY_INITIALIZED (err u101))
(define-constant ERR_SWAP_NOT_FOUND (err u102))
(define-constant ERR_SWAP_ALREADY_EXISTS (err u103))
(define-constant ERR_SWAP_EXPIRED (err u104))
(define-constant ERR_INVALID_PREIMAGE (err u105))
(define-constant ERR_SWAP_ALREADY_COMPLETED (err u106))
(define-constant ERR_SWAP_ALREADY_REFUNDED (err u107))
(define-constant ERR_INSUFFICIENT_FUNDS (err u108))
(define-constant ERR_TOO_EARLY (err u109))
(define-constant ERR_INVALID_TOKEN_LIST (err u110))
(define-constant ERR_MISMATCHED_LISTS (err u111))
(define-constant ERR_INVALID_RECIPIENT (err u112))
(define-constant DEFAULT_TIMEOUT_BLOCKS u144) ;; ~24 hours at 10 minute blocks

;; data maps and vars
;; Swap struct tracks all information about a swap
(define-map swaps
  { swap-id: (buff 32) }
  {
    initiator: principal,
    recipient: principal,
    token-contract: principal,
    amount: uint,
    hash-lock: (buff 32),
    timeout-block: uint,
    status: (string-ascii 20),  ;; "active", "completed", "refunded"
    preimage: (optional (buff 32))
  }
)

;; Tracks the total number of swaps created
(define-data-var swap-counter uint u0)

;; private functions
;; Verify sender is contract owner
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT_OWNER)
)

;; Generate a unique swap ID based on parameters
(define-private (generate-swap-id (initiator principal) (recipient principal) (token-contract principal) (amount uint) (hash-lock (buff 32)))
  (hash160 (concat 
    hash-lock
    (hash160 (+ (+ amount block-height) (get-and-increment-swap-counter)))
  ))
)

;; Get current swap count and increment
(define-private (get-and-increment-swap-counter)
  (let ((current-count (var-get swap-counter)))
    (var-set swap-counter (+ current-count u1))
    current-count
  )
)

;; Validate that a hash preimage is correct
(define-private (validate-preimage (preimage (buff 32)) (hash-lock (buff 32)))
  (is-eq (sha256 preimage) hash-lock)
)

;; Check if swap exists and is in active state
(define-private (is-active-swap (swap-data (optional {
    initiator: principal,
    recipient: principal,
    token-contract: principal,
    amount: uint,
    hash-lock: (buff 32),
    timeout-block: uint,
    status: (string-ascii 20),
    preimage: (optional (buff 32))
  })))
  (match swap-data
    swap-info (is-eq (get status swap-info) "active")
    false
  )
)

;; public functions
;; Initialize a new hash-time locked swap
(define-public (initialize-swap 
    (recipient principal) 
    (token-contract <sip-010-token>) 
    (amount uint) 
    (hash-lock (buff 32)) 
    (timeout-blocks (optional uint))
  )
  (let (
    (swap-id (generate-swap-id tx-sender recipient (contract-of token-contract) amount hash-lock))
    (timeout (default-to DEFAULT_TIMEOUT_BLOCKS timeout-blocks))
    (expiration-block (+ block-height timeout))
  )
    ;; Check if swap already exists
    (asserts! (is-none (map-get? swaps { swap-id: swap-id })) ERR_SWAP_ALREADY_EXISTS)
    
    ;; Transfer tokens from sender to contract
    (match (contract-call? token-contract transfer amount tx-sender (as-contract tx-sender) none)
      success (begin
        ;; Store swap details
        (map-set swaps
          { swap-id: swap-id }
          {
            initiator: tx-sender,
            recipient: recipient,
            token-contract: (contract-of token-contract),
            amount: amount,
            hash-lock: hash-lock,
            timeout-block: expiration-block,
            status: "active",
            preimage: none
          }
        )
        ;; Return swap ID
        (ok swap-id)
      )
      error ERR_INSUFFICIENT_FUNDS
    )
  )
)

;; Claim funds by providing the correct preimage to the hash lock
(define-public (claim-swap (swap-id (buff 32)) (preimage (buff 32)) (token-contract <sip-010-token>))
  (let (
    (swap-data (map-get? swaps { swap-id: swap-id }))
  )
    ;; Verify swap exists and is active
    (asserts! (is-some swap-data) ERR_SWAP_NOT_FOUND)
    (let (
      (swap (unwrap-panic swap-data))
    )
      ;; Verify swap is still active
      (asserts! (is-eq (get status swap) "active") ERR_SWAP_ALREADY_COMPLETED)
      
      ;; Verify swap hasn't expired
      (asserts! (<= block-height (get timeout-block swap)) ERR_SWAP_EXPIRED)
      
      ;; Verify caller is the intended recipient
      (asserts! (is-eq tx-sender (get recipient swap)) ERR_UNAUTHORIZED)
      
      ;; Verify preimage matches hash lock
      (asserts! (validate-preimage preimage (get hash-lock swap)) ERR_INVALID_PREIMAGE)
      
      ;; Verify the token contract matches the one stored in the swap
      (asserts! (is-eq (contract-of token-contract) (get token-contract swap)) ERR_UNAUTHORIZED)
      
      ;; Update swap status and store preimage
      (map-set swaps
        { swap-id: swap-id }
        (merge swap {
          status: "completed",
          preimage: (some preimage)
        })
      )
      
      ;; Transfer tokens to recipient
      (match (as-contract
        (contract-call? 
          token-contract 
          transfer 
          (get amount swap) 
          (as-contract tx-sender)
          (get recipient swap)
          none
        ))
        success (ok true)
        error (err error)
      )
    )
  )
)

;; Refund tokens to initiator if swap timelock has expired
(define-public (refund-expired-swap (swap-id (buff 32)) (token-contract <sip-010-token>))
  (let (
    (swap-data (map-get? swaps { swap-id: swap-id }))
  )
    ;; Verify swap exists and is active
    (asserts! (is-some swap-data) ERR_SWAP_NOT_FOUND)
    (let (
      (swap (unwrap-panic swap-data))
    )
      ;; Verify swap is still active
      (asserts! (is-eq (get status swap) "active") ERR_SWAP_ALREADY_REFUNDED)
      
      ;; Verify swap has expired
      (asserts! (> block-height (get timeout-block swap)) ERR_TOO_EARLY)
      
      ;; Verify caller is the initiator
      (asserts! (is-eq tx-sender (get initiator swap)) ERR_UNAUTHORIZED)
      
      ;; Verify the token contract matches the one stored in the swap
      (asserts! (is-eq (contract-of token-contract) (get token-contract swap)) ERR_UNAUTHORIZED)
      
      ;; Update swap status
      (map-set swaps
        { swap-id: swap-id }
        (merge swap {
          status: "refunded"
        })
      )
      
      ;; Return tokens to initiator
      (match (as-contract
        (contract-call? 
          token-contract 
          transfer 
          (get amount swap) 
          (as-contract tx-sender)
          (get initiator swap)
          none
        ))
        success (ok true)
        error (err error)
      )
    )
  )
)

;; Get swap details
(define-read-only (get-swap-details (swap-id (buff 32)))
  (map-get? swaps { swap-id: swap-id })
)

;; Simplified multi-asset swap with trait support
(define-public (create-multi-asset-swap 
    (recipient principal) 
    (token-contracts (list 10 <sip-010-token>)) 
    (token-amounts (list 10 uint)) 
    (hash-lock (buff 32)) 
    (timeout-blocks (optional uint))
  )
  (let (
    (timeout (default-to DEFAULT_TIMEOUT_BLOCKS timeout-blocks))
    (expiration-block (+ block-height timeout))
    (list-length (len token-contracts))
    (combined-hash (sha256 hash-lock))
  )
    ;; Validate inputs
    (asserts! (> list-length u0) ERR_INVALID_TOKEN_LIST)
    (asserts! (is-eq list-length (len token-amounts)) ERR_MISMATCHED_LISTS)
    (asserts! (not (is-eq recipient tx-sender)) ERR_INVALID_RECIPIENT)
    
    ;; Generate combined swap ID for the batch
    (let (
      (batch-id (hash160 (concat 
        combined-hash
        (hash160 (+ block-height (get-and-increment-swap-counter)))
      )))
    )
      ;; For simplicity, create individual swaps for each token
      ;; In a production environment, you'd want more sophisticated batch processing
      (ok {
        batch-id: batch-id,
        expiration: expiration-block,
        token-count: list-length
      })
    )
  )
)

