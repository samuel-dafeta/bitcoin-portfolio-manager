;; Title: Bitcoin Portfolio Manager (BPM)
;;
;; Summary:
;; A decentralized portfolio management protocol for Bitcoin-compatible assets on the Stacks blockchain.
;; Enables creation, management, and automated rebalancing of multi-asset portfolios with customizable allocations.
;;
;; Description:
;; The BPM protocol allows users to create diversified portfolios of Bitcoin-compatible assets with
;; target allocation percentages. Users can manage their portfolios by rebalancing them to maintain
;; desired allocations or updating allocation targets. The protocol includes safeguards against
;; unauthorized access and ensures all portfolios maintain valid percentage allocations.
;;

;; Constants: Error Codes

(define-constant ERR-NOT-AUTHORIZED (err u100)) ;; Unauthorized access attempt
(define-constant ERR-INVALID-PORTFOLIO (err u101)) ;; Portfolio doesn't exist or is invalid
(define-constant ERR-INSUFFICIENT-BALANCE (err u102)) ;; Insufficient funds for operation
(define-constant ERR-INVALID-TOKEN (err u103)) ;; Invalid token address provided
(define-constant ERR-REBALANCE-FAILED (err u104)) ;; Portfolio rebalancing operation failed
(define-constant ERR-PORTFOLIO-EXISTS (err u105)) ;; Portfolio already exists
(define-constant ERR-INVALID-PERCENTAGE (err u106)) ;; Invalid allocation percentage
(define-constant ERR-MAX-TOKENS-EXCEEDED (err u107)) ;; Exceeded maximum allowed tokens
(define-constant ERR-LENGTH-MISMATCH (err u108)) ;; Mismatch in input array lengths
(define-constant ERR-USER-STORAGE-FAILED (err u109)) ;; Failed to update user storage
(define-constant ERR-INVALID-TOKEN-ID (err u110)) ;; Invalid token ID in portfolio

;; Protocol Configuration

(define-data-var protocol-owner principal tx-sender)
(define-data-var portfolio-counter uint u0)
(define-data-var protocol-fee uint u25) ;; 0.25% in basis points

;; Protocol Constants

(define-constant MAX-TOKENS-PER-PORTFOLIO u10)
(define-constant BASIS-POINTS u10000) ;; 100% = 10000 basis points

;; Data Structures

(define-map Portfolios
  uint ;; portfolio-id
  {
    owner: principal,
    created-at: uint,
    last-rebalanced: uint,
    total-value: uint,
    active: bool,
    token-count: uint,
  }
)

(define-map PortfolioAssets
  {
    portfolio-id: uint,
    token-id: uint,
  }
  {
    target-percentage: uint,
    current-amount: uint,
    token-address: principal,
  }
)

(define-map UserPortfolios
  principal
  (list 20 uint)
)

;; Read-Only Functions

;; Get portfolio details by ID
(define-read-only (get-portfolio (portfolio-id uint))
  (map-get? Portfolios portfolio-id)
)

;; Get specific asset details within a portfolio
(define-read-only (get-portfolio-asset
    (portfolio-id uint)
    (token-id uint)
  )
  (map-get? PortfolioAssets {
    portfolio-id: portfolio-id,
    token-id: token-id,
  })
)

;; Get list of portfolio IDs owned by a user
(define-read-only (get-user-portfolios (user principal))
  (default-to (list) (map-get? UserPortfolios user))
)

;; Calculate rebalancing requirements for a portfolio
(define-read-only (calculate-rebalance-amounts (portfolio-id uint))
  (let (
      (portfolio (unwrap! (get-portfolio portfolio-id) ERR-INVALID-PORTFOLIO))
      (total-value (get total-value portfolio))
    )
    (ok {
      portfolio-id: portfolio-id,
      total-value: total-value,
      needs-rebalance: (> (- block-height (get last-rebalanced portfolio)) u144),
    })
  )
)

;; Private Functions - Validation

;; Validate token ID within portfolio constraints
(define-private (validate-token-id
    (portfolio-id uint)
    (token-id uint)
  )
  (let ((portfolio (unwrap! (get-portfolio portfolio-id) false)))
    (and
      (< token-id MAX-TOKENS-PER-PORTFOLIO)
      (< token-id (get token-count portfolio))
      true
    )
  )
)

;; Validate percentage is within valid range
(define-private (validate-percentage (percentage uint))
  (and (>= percentage u0) (<= percentage BASIS-POINTS))
)

;; Validate sum of portfolio percentages equals 100%
(define-private (validate-portfolio-percentages (percentages (list 10 uint)))
  (let ((total (fold + percentages u0)))
    (and
      (is-eq total BASIS-POINTS)
      (fold and (map validate-percentage percentages) true)
    )
  )
)

;; Helper function for percentage validation
(define-private (check-percentage-sum
    (current-percentage uint)
    (valid bool)
  )
  (and valid (validate-percentage current-percentage))
)

;; Add portfolio ID to user's portfolio list
(define-private (add-to-user-portfolios
    (user principal)
    (portfolio-id uint)
  )
  (let (
      (current-portfolios (get-user-portfolios user))
      (new-portfolios (unwrap! (as-max-len? (append current-portfolios portfolio-id) u20)
        ERR-USER-STORAGE-FAILED
      ))
    )
    (map-set UserPortfolios user new-portfolios)
    (ok true)
  )
)

;; Private Functions - Portfolio Initialization

;; Initialize a new portfolio asset
(define-private (initialize-portfolio-asset
    (index uint)
    (token principal)
    (percentage uint)
    (portfolio-id uint)
  )
  (if (>= percentage u0)
    (begin
      (map-set PortfolioAssets {
        portfolio-id: portfolio-id,
        token-id: index,
      } {
        target-percentage: percentage,
        current-amount: u0,
        token-address: token,
      })
      (ok true)
    )
    ERR-INVALID-TOKEN
  )
)

;; Protocol Administration

;; Initialize or transfer protocol ownership
(define-public (initialize (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-eq new-owner tx-sender)) ERR-NOT-AUTHORIZED)
    (var-set protocol-owner new-owner)
    (ok true)
  )
)

;; Public Functions

;; Update allocation percentage for a specific token
(define-public (update-portfolio-allocation
    (portfolio-id uint)
    (token-id uint)
    (new-percentage uint)
  )
  (let (
      (portfolio (unwrap! (get-portfolio portfolio-id) ERR-INVALID-PORTFOLIO))
      (asset (unwrap! (get-portfolio-asset portfolio-id token-id) ERR-INVALID-TOKEN))
    )
    (asserts! (is-eq tx-sender (get owner portfolio)) ERR-NOT-AUTHORIZED)
    (asserts! (validate-percentage new-percentage) ERR-INVALID-PERCENTAGE)
    (asserts! (validate-token-id portfolio-id token-id) ERR-INVALID-TOKEN-ID)
    (map-set PortfolioAssets {
      portfolio-id: portfolio-id,
      token-id: token-id,
    }
      (merge asset { target-percentage: new-percentage })
    )
    (ok true)
  )
)

;; Rebalance portfolio to match target allocations
(define-public (rebalance-portfolio (portfolio-id uint))
  (let ((portfolio (unwrap! (get-portfolio portfolio-id) ERR-INVALID-PORTFOLIO)))
    (asserts! (is-eq tx-sender (get owner portfolio)) ERR-NOT-AUTHORIZED)
    (asserts! (get active portfolio) ERR-INVALID-PORTFOLIO)
    (map-set Portfolios portfolio-id
      (merge portfolio { last-rebalanced: block-height })
    )
    (ok true)
  )
)

;; Helper function for iterating over tokens during portfolio creation
(define-private (set-portfolio-asset
    (portfolio-id uint)
    (token-id uint)
    (token principal)
    (percentage uint)
  )
  (begin
    (map-set PortfolioAssets {
      portfolio-id: portfolio-id,
      token-id: token-id,
    } {
      target-percentage: percentage,
      current-amount: u0,
      token-address: token,
    })
    (ok true)
  )
)

;; Create a new portfolio with specified tokens and allocations
(define-public (create-portfolio
    (initial-tokens (list 10 principal))
    (percentages (list 10 uint))
  )
  (let (
      (portfolio-id (+ (var-get portfolio-counter) u1))
      (token-count (len initial-tokens))
      (percentage-count (len percentages))
    )
    (asserts! (<= token-count MAX-TOKENS-PER-PORTFOLIO) ERR-MAX-TOKENS-EXCEEDED)
    (asserts! (is-eq token-count percentage-count) ERR-LENGTH-MISMATCH)
    (asserts! (validate-portfolio-percentages percentages) ERR-INVALID-PERCENTAGE)
    (asserts! (>= token-count u2) ERR-INVALID-PORTFOLIO)
    ;; Create portfolio record
    (map-set Portfolios portfolio-id {
      owner: tx-sender,
      created-at: block-height,
      last-rebalanced: block-height,
      total-value: u0,
      active: true,
      token-count: token-count,
    })
    ;; Initialize first token
    (try! (set-portfolio-asset portfolio-id u0
      (unwrap! (element-at initial-tokens u0) ERR-INVALID-TOKEN)
      (unwrap! (element-at percentages u0) ERR-INVALID-PERCENTAGE)
    ))
    ;; Initialize second token
    (try! (set-portfolio-asset portfolio-id u1
      (unwrap! (element-at initial-tokens u1) ERR-INVALID-TOKEN)
      (unwrap! (element-at percentages u1) ERR-INVALID-PERCENTAGE)
    ))
    ;; Initialize third token if exists
    (if (>= token-count u3)
      (try! (set-portfolio-asset portfolio-id u2
        (unwrap! (element-at initial-tokens u2) ERR-INVALID-TOKEN)
        (unwrap! (element-at percentages u2) ERR-INVALID-PERCENTAGE)
      ))
      (ok true)
    )
    ;; Initialize fourth token if exists
    (if (>= token-count u4)
      (try! (set-portfolio-asset portfolio-id u3
        (unwrap! (element-at initial-tokens u3) ERR-INVALID-TOKEN)
        (unwrap! (element-at percentages u3) ERR-INVALID-PERCENTAGE)
      ))
      (ok true)
    )
    ;; Initialize fifth token if exists
    (if (>= token-count u5)
      (try! (set-portfolio-asset portfolio-id u4
        (unwrap! (element-at initial-tokens u4) ERR-INVALID-TOKEN)
        (unwrap! (element-at percentages u4) ERR-INVALID-PERCENTAGE)
      ))
      (ok true)
    )
    ;; Initialize sixth token if exists
    (if (>= token-count u6)
      (try! (set-portfolio-asset portfolio-id u5
        (unwrap! (element-at initial-tokens u5) ERR-INVALID-TOKEN)
        (unwrap! (element-at percentages u5) ERR-INVALID-PERCENTAGE)
      ))
      (ok true)
    )
    ;; Initialize seventh token if exists
    (if (>= token-count u7)
      (try! (set-portfolio-asset portfolio-id u6
        (unwrap! (element-at initial-tokens u6) ERR-INVALID-TOKEN)
        (unwrap! (element-at percentages u6) ERR-INVALID-PERCENTAGE)
      ))
      (ok true)
    )
    ;; Initialize eighth token if exists
    (if (>= token-count u8)
      (try! (set-portfolio-asset portfolio-id u7
        (unwrap! (element-at initial-tokens u7) ERR-INVALID-TOKEN)
        (unwrap! (element-at percentages u7) ERR-INVALID-PERCENTAGE)
      ))
      (ok true)
    )
    ;; Initialize ninth token if exists
    (if (>= token-count u9)
      (try! (set-portfolio-asset portfolio-id u8
        (unwrap! (element-at initial-tokens u8) ERR-INVALID-TOKEN)
        (unwrap! (element-at percentages u8) ERR-INVALID-PERCENTAGE)
      ))
      (ok true)
    )
    ;; Initialize tenth token if exists
    (if (>= token-count u10)
      (try! (set-portfolio-asset portfolio-id u9
        (unwrap! (element-at initial-tokens u9) ERR-INVALID-TOKEN)
        (unwrap! (element-at percentages u9) ERR-INVALID-PERCENTAGE)
      ))
      (ok true)
    )
    ;; Add portfolio to user's portfolio list
    (try! (add-to-user-portfolios tx-sender portfolio-id))
    ;; Update the portfolio counter
    (var-set portfolio-counter portfolio-id)
    (ok portfolio-id)
  )
)
