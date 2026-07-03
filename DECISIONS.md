# Design decisions

Short records of non-obvious design choices. Newest first.

---

## D4 — All three contracts on Clarity 6 / epoch 4.0

**Contracts:** all; **notably** `mia-pool-faktory.clar`.

Clarity 6 removes plain `as-contract`, so the pool could not stay a verbatim
copy of the Clarity-3 `flatearth-faktory-pool-v2` template. The port replaces
the `CONTRACT` constant with the `current-contract` keyword and wraps every
outbound transfer in `as-contract?` with a `with-ft` allowance for exactly the
amount sent (one allowance covers both legs of the sBTC payout in
`swap-b-to-a`: trader + faktory fee = `dy`). Behaviour is pinned by the unit
suite (exact-value AMM math) and the rendezvous properties (product
non-decreasing, quote == execution), so the "battle-tested template" assurance
is now carried by tests instead of byte-level diffing.

---

## D3 — settle-offers always keeps the caller's own offer

**Contract:** `mia-fair-faktory.clar`, `settle-step`.

`stx-transfer?` to oneself fails (`err u2`), and the fold used `unwrap-panic`,
so a whitehat who also had a resting offer got a hard runtime abort as soon as
their own offer became affordable. The fold now skips entries owned by
`tx-sender`: the settler's budget flows past their own offer to the next
fillable one, and they can `cancel-offer` if they want their escrow back.
(AUDIT.md F-2; unit test "a settler's own offer is kept, not filled".)

---

## D2 — The swap gate blocks direct wallet calls too

**Contract:** `mia-pool-faktory.clar`, `is-approved-caller`.

The template's check `(or (is-eq tx-sender contract-caller) …)` passes for
every direct (non-contract-mediated) call, so "gated" only kept **routers**
out — any wallet could still swap directly and move the pool ratio during the
single-sided entry window, defeating the whole point of the gating amendment
(deposits pairing at the seeded price). The escape hatch is removed: while
`gated` is true, only principals explicitly approved via `approve-caller` may
swap. `set-gated false` opens the pool for everyone after the entry window.
(AUDIT.md F-1; unit tests under "swap gating".)

---

## D1 — Offer book breaks price ties first-come-first-serve (strict `<`)

**Contract:** `mia-fair-faktory.clar`, `insert-step` (the sorted-insert fold).

**Decision:** the sorted insert uses a **strict** comparison
```clarity
(if (and (not (get placed acc)) (< (* nask eumia) (* eask numia)))   ;; new < entry
  (merge acc { out: (push-rec (push-rec (get out acc) nrec) entry), placed: true })
  (merge acc { out: (push-rec (get out acc) entry) }))
```
not `<=`.

**Context.** The book is a list kept sorted **ascending by price** (`ustx /
amount`), and settle consumes cheapest-first from the head. Two offers can have
the exact same price, so we need a tie-break rule. The fold walks the existing
entries in order and inserts the newcomer `nrec` in front of the first entry it
is *not* strictly cheaper than.

**Why strict `<` (and not `<=`).**
- With `<=`, on a price tie the condition is **true**, so the newcomer is
  inserted **before** the equal-priced existing offer → **LIFO** (last-in jumps
  ahead). That favors whoever posts latest — i.e. bots that can spam/replace
  offers at the marginal price right before distribution — over community
  members who committed earlier.
- With `<`, on a tie the condition is **false**, so the newcomer falls through
  past all equal-priced entries and lands **after** them → **FIFO**
  (first-come-first-serve). The earliest committer at a given price is settled
  first. This is what Friedger asked for and it rewards early commitment instead
  of last-second bot placement.

**Consistency check.** The full-book eviction guard in `place-offer` already
uses strict `<`:
```clarity
(asserts! (< (* ask-ustx (get amount worst)) (* (get ustx worst) umia)) ERR_BOOK_FULL)
```
i.e. a newcomer only evicts the worst offer if it is **strictly** cheaper — a
tie does not displace an already-resting offer. Same FIFO principle: existing
(earlier) offers keep their slot on a tie.

**Origin.** CityCoins Discord (DerekS.btc proposed the below-par burn auction;
Rapha reframed it so the most-in-pain exit at a lower rate is prioritized;
Friedger asked for first-come-first-serve on equal prices).
