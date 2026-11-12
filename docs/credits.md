# Prepaid credit

A key with a total budget is a prepaid key: what it holds is credit, bought
in advance and used up by its requests. This page is the rule that credit
follows. It is the same rule whoever paid and however: a top-up through the
admin API, a payment through a [payment provider](payments.md), a bonus.

With nothing configured the rule changes nothing: a prepaid key is billed
what the providers cost, as before, and earns no bonus.

- [The rule](#the-rule)
- [Which keys](#which-keys)
- [The burn multiplier](#the-burn-multiplier)
- [The weekly bonus](#the-weekly-bonus)
- [Settings](#settings)
- [Seeing it](#seeing-it)
- [What it does not do](#what-it-does-not-do)

## The rule

```
1 credit      = 1 US dollar, at the moment a top-up is applied
balance       = top-ups + bonuses − burns
burn          = what the provider cost × the burn multiplier
weekly bonus  = average balance over the week
                × the annual bonus rate ÷ 52
```

A key at or below zero is blocked: its requests are answered
`402 budget_exceeded` until it is credited again. The request that crosses
zero is completed and paid for; the balance then stands a little below
zero, and the next credit pays that off first.

All credit is the same. Whatever a prepaid key holds earns the bonus,
wherever it came from: the budget the key was created with, a top-up, a
payment, an earlier bonus (which therefore compounds).

**Credit cannot be withdrawn or refunded.** There is no call that pays any
out, to anyone. It can only be spent on requests through this gateway. An
operator can lower a key's budget by hand (`PATCH /admin/keys/{name}`), which
takes credit away; nothing sends it anywhere.

Amounts are IEEE-754 doubles in US dollars, like every cost in the ledger.
Nothing is rounded when it is stored or compared; listings round to six
decimals. A bonus of less than a millionth of a dollar is not credited.

## Which keys

A key is prepaid when it has `budget_usd` and its `budget_period` is
`total` (the default period). Everything on this page applies to such keys
and to no others:

| Key | Burn multiplier | Bonus | Top-ups |
|---|---|---|---|
| `budget_usd` set, period `total` | applies | applies, to managed keys | managed keys only |
| `budget_usd` set, period `monthly` or `daily` | no: billed the provider cost | no | refused (`409 not_prepaid`) |
| no `budget_usd` | no | no | refused (`409 not_prepaid`) |

A key in the config file can be prepaid (its budget is then fixed in the
file, and the burn multiplier applies to it), but it cannot be topped up or
earn a bonus: both change a key's budget, and the gateway does not write the
config file.

## The burn multiplier

`credits.burn_multiplier` says how much credit one dollar of provider cost
uses up. At the default of 1, credit is used up at the provider's price.

- The setting is global; a key may carry its own `burn_multiplier`, which
  wins (`"burn_multiplier": 1.5` in a `keys[]` entry, or in a create or
  `PATCH` call for a managed key; `null` goes back to the setting).
- The multiplier that applies is the one in force when the usage event
  reaches the control plane. What was burned stays burned: changing the
  multiplier does not re-price the past.
- The provider cost is never changed by it. Every usage record carries both
  figures: `cost_usd` (what the provider cost) and `credits_usd` (what was
  burned), so the margin is `credits_usd − cost_usd`, per request and per
  key.

## The weekly bonus

With `credits.bonus_annual_rate` above zero, every prepaid managed key earns
a bonus on its credit once a week:

```
bonus = average balance over the week × rate ÷ 52
```

At 5% a year, $100 of credit held all week earns
`100 × 0.05 ÷ 52 = $0.0962`.

- **Weeks** are ISO weeks in UTC: Monday 00:00 to the next Monday 00:00.
- **The average is over the whole week.** A key that held $100 for half the
  week earns half of that; a key credited on Tuesday earns six sevenths.
  Topping up just before the week ends earns almost nothing for that week.
- **The rate is the one in force when the week is closed.** It is a setting
  an operator can change at any time, not a promise; say so to your
  customers.
- **How the average is measured.** The balance is sampled at every
  top-up and every `credits.sample_interval_s` (15 minutes unless set).
  Between two samples it is taken to have moved in a straight line. Samples
  are kept with the key, so the measure survives restarts.
- **It is credited as a top-up of its own**: source `bonus`, reference
  `bonus:<key>:<ISO week>` (for example `bonus:acme:2026-W46`), in the audit
  log as `key.bonus`, in the top-up history and in the usage feed. A
  reference is only ever credited once, so a week cannot be paid twice:
  not after a restart, not if the clock is set back, not if the reference is
  sent by hand (that is a `409`).
- **Weeks that ended while the control plane was not running** are closed
  when it starts again, one by one, each credited once and each on top of
  the one before. What the balance did during the gap is not known sample by
  sample: it is taken to have moved in a straight line from the last sample
  to the first one after the start.
- **A key created during a week** earns for the part of the week it held
  credit, counted from the first sample after it was created (or from its
  first top-up, if that comes sooner). **A deleted key** earns nothing
  more; its state goes with it. **A balance at or below zero** earns
  nothing, and one that crosses zero between two samples earns for the part
  of the line above zero.
- **A budget changed by hand** (`PATCH` of `budget_usd`) changes the balance
  by as much, from that moment.
- A key that holds no credit is not sampled, and with a rate of 0 nothing is
  sampled at all: the key store is not written for it.

Worked example at 5% (0.0962% a week):

| When | What | Balance |
|---|---|---|
| Monday | $100 is added | 100.00 |
| Wednesday | Requests burn $24 of credit | 76.00 |
| Next Monday 00:00 | Average was `(100×2 + 76×5) ÷ 7 = 82.86`; bonus `82.86 × 0.05 ÷ 52 = 0.0797` | 76.0797 |

## Settings

In the config file, all optional:

```json
"credits": {
  "bonus_annual_rate": 0.05,
  "sample_interval_s": 900
}
```

| Field | Default | Meaning |
|---|---|---|
| `burn_multiplier` | `1` | Credit burned per dollar of provider cost, for prepaid keys. 0.01 to 100. |
| `bonus_annual_rate` | `0` | The weekly bonus's rate per year, as a fraction: `0.05` is 5%. 0 to 10. `0` switches the bonus off. |
| `sample_interval_s` | `900` | How often balances are sampled while a bonus rate is set. 1 to 86,400. |

An unknown field in `credits` is refused when the config is loaded. Per key:
`burn_multiplier` (see above).

The config file is re-read when it changes, so a new multiplier or rate
takes effect without a restart: the multiplier for the usage that arrives
from then on, the rate for the weeks closed from then on.

## Seeing it

- **`GET /admin/keys`**: every key has `cost_usd` (provider cost) and
  `credits_burned_usd`; a prepaid key also has
  `"credits": {"balance_usd", "burned_usd", "burn_multiplier", "bonus_annual_rate", "last_bonus"}`
  (null for any other key). `period_spend_usd` of a prepaid key is its
  credit burned.
- **`GET /admin/events`** (the usage feed): every usage event has `cost_usd`
  and `credits_usd`; credit added to a key is an event of its own,
  `"kind": "credit"`, with `amount_usd`, `source`, `reference` and the
  `budget_usd` after it. Read in order, the feed is
  a complete statement of a key.
- **`GET /admin/topups?key=<name>&limit=<n>`**: applied top-ups and bonuses,
  newest first, each with its `source`.
- **`GET /metrics`**: `omnigate_key_cost_usd_total` (provider cost) and
  `omnigate_key_credits_burned_usd_total`; `omnigate_key_period_cost_usd`
  of a prepaid key is its credit burned.
- **The audit log**: `key.topup` (with `source`) and
  `key.bonus` (written by the gateway itself, `"auth": "system"`).

## What it does not do

- **It does not hold or move money.** Credit is a number in the key store.
  What an operator does with what customers paid is outside the gateway.
- **No cash-out, no refunds, no transfers between keys.**
- **No bonus for keys in the config file**, and none for monthly or daily
  budgets.
- **The margin is not reported as revenue anywhere**; it is the difference
  of two figures in each record.
- **Enforcement is after the fact**, as for every budget: the request that
  crosses zero completes, and the data plane learns of the block with its
  next config poll.
