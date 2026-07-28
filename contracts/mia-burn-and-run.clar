(define-constant ERR_ABOVE_CAP (err u9100))

(define-constant CCD013 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia)
(define-constant MACHINE 'SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.stx-to-stx-mia-faktory-v2)

(define-constant MICRO_CITYCOINS (pow u10 u6))
(define-constant MAX_RUN_USTX u17100000000)

(define-private (maybe-burn (umia uint))
  (if (> umia u0)
    (begin
      (try! (contract-call? CCD013 redeem-mia umia))
      (ok true)
    )
    (ok false)
  )
)

(define-public (burn-and-run
    (umia uint)
    (ustx uint)
    (cycles uint)
  )
  (begin
    (asserts! (<= ustx MAX_RUN_USTX) ERR_ABOVE_CAP)
    (try! (maybe-burn umia))
    (contract-call? MACHINE run-loops ustx cycles)
  )
)

(define-read-only (get-plan (who principal))
  (let (
      (umia (unwrap-panic (contract-call?
        'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
        get-balance who
      )))
      (treasury (contract-call?
        'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia
        get-redemption-current-balance
      ))
      (needed (/ (+ treasury (- MAX_RUN_USTX u1)) MAX_RUN_USTX))
    )
    {
      umia: umia,
      ustx: MAX_RUN_USTX,
      cycles: (if (> needed u5) u5 needed),
      treasury: treasury,
      redeems-first: (if (> (* umia u1710) (* treasury MICRO_CITYCOINS))
        treasury
        (/ (* umia u1710) MICRO_CITYCOINS)
      ),
    }
  )
)
