# Design decisions

Short records of non-obvious design choices. Newest first.

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
