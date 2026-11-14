# Payments

omnigate can take payments for [prepaid credit](credits.md) by itself: the
holder of a prepaid key asks for a payment, pays it with a crypto asset of
their choice, and the key is credited when the payment has settled. An agent
whose credit is spent can do this without a person.

**This is opt-in.** Without a `"payments"` section in the config there are
no payment endpoints (they answer 404), nothing is asked of any provider,
and nothing on this page applies. omnigate stays a model gateway.

There are two payment providers, and the config names one:

- **`near_intents`**: NEAR Intents, through its 1Click API. The payer pays
  with any of a few hundred assets on a few dozen chains; the provider swaps
  it and delivers a stablecoin to the operator's NEAR account. Most of this
  page describes it.
- **`solana`**: a stablecoin (USDC) on Solana, straight from the payer to
  the operator's own wallet, with nobody in between. One asset, no swap, no
  fee beyond the chain's; see [The solana provider](#the-solana-provider)
  for what differs.

Payments are built as a provider interface, the way media providers are.
Other ways of
taking money still work as before, from outside: anything that can call
[`POST /admin/keys/{name}/topup`](building-on-omnigate.md#taking-payments-prepaid-keys-and-top-ups)
can credit a key.

- [What the gateway does and does not do](#what-the-gateway-does-and-does-not-do)
- [The flow](#the-flow)
- [Switching it on](#switching-it-on)
- [The solana provider](#the-solana-provider)
- [The API](#the-api)
- [States of a payment](#states-of-a-payment)
- [What is credited, and when](#what-is-credited-and-when)
- [What is checked, and what is trusted](#what-is-checked-and-what-is-trusted)
- [Fees, limits and refunds](#fees-limits-and-refunds)
- [For operators](#for-operators)
- [What has been tested](#what-has-been-tested)
- [Trying it with real funds](#trying-it-with-real-funds)

## What the gateway does and does not do

- **It holds no keys, signs nothing and moves no funds.** It asks the
  provider for a quote and, later, for the status of that quote. Both are
  reads.
- **Funds never pass through the gateway.** The payer sends them to a
  deposit address the provider gives; the provider swaps them and delivers
  the settle asset straight to the operator's own account.
- **It credits a key**: a number in the key store, under the rule in
  [Prepaid credit](credits.md). Credit cannot be withdrawn or refunded.
- What the operator does with what arrives in their account is outside the
  gateway.

## The flow

```
payer (a person or an agent)         omnigate                    NEAR Intents (1Click)        operator's account
        |  POST /v1/payments            |                               |                            |
        |  {amount_usd, asset,          |  quote: "exactly N USDC to    |                            |
        |   refund_to}  --------------> |  the operator; how much of    |                            |
        |                               |  this asset, sent where?" --> |                            |
        |                               | <-- deposit address, amount,  |                            |
        | <-- deposit address, amount,  |     deadline (signed)         |                            |
        |     deadline                  |                               |                            |
        |  sends the funds  ------------------------------------------> |  swaps, delivers  -------> |
        |                               |  status? (every few seconds)->|                            |
        |                               | <-- SUCCESS, amount delivered |                            |
        |                               |  credits the key, once        |                            |
        |  GET /v1/payments/{id} -----> |                               |                            |
        | <-- settled, credited_usd     |                               |                            |
```

Whatever the payer pays with (the provider lists a few hundred assets on a
few dozen chains), the operator receives one asset: the settle asset, native
USDC on NEAR unless configured otherwise.

## Switching it on

```json
"payments": {
  "provider": "near_intents",
  "recipient": "your-account.near",
  "min_usd": 1,
  "max_usd": 1000
}
```

[`config/omnigate.payments.json`](../config/omnigate.payments.json) is a
complete example (a text route, a bonus rate, payments).

| Field | Default | Meaning |
|---|---|---|
| `provider` | required | `"near_intents"` (this table) or `"solana"` ([its own fields](#the-solana-provider)). |
| `recipient` | required | The operator's account at the provider: for `near_intents`, the NEAR account that receives the settle asset. **Check it twice**: it is where the money goes. It must be able to receive the settle asset (for a NEAR token: registered with the token's contract, which holding the token once takes care of). |
| `min_usd`, `max_usd` | `1`, `10000` | Bounds on one payment. |
| `quote_ttl_s` | `1800` | How long a payer is asked to be given to send the deposit. 60 to 86,400. The provider sets the deadline and may give longer: for ETH on Ethereum it gave three days. The payment's `deadline` is always the provider's. |
| `poll_interval_s` | `15` | How often an open payment's status is asked for. After twenty polls they are spaced further apart. |
| `settle_asset` | native USDC on NEAR | The asset delivered to the operator, as a 1Click asset id. It should be a dollar stablecoin: what arrives is credited one to one. |
| `settle_decimals` | `6` | That asset's decimals. |
| `slippage_bps` | `100` | Tolerance on the amount the payer is asked to send (1%). What the swap does not need is refunded to the payer by the provider. |
| `jwt_env` | none | Name of an environment variable (of the control plane) holding a 1Click partner token. Without one, 1Click adds 0.25% to every quote. |
| `base_url`, `public_key` | 1Click's | Where the provider is and the key it signs quotes with. Only ever changed to point at a test double. |

An unknown field, or a provider that does not exist, is refused when the
config is loaded. The control plane needs outbound HTTPS to
`1click.chaindefuser.com`. Payments are kept in `OMNIGATE_PAYMENTS`
(default `data/payments.json`; `/data/payments.json` in the image).

Only **prepaid managed keys** can be paid for: keys created through the
admin API with a total budget (`"budget_usd": 0` is the usual start). A key
from the config file, a key without a budget and a key with a monthly or
daily budget are answered `409 not_prepaid`.

## The solana provider

```json
"payments": {
  "provider": "solana",
  "recipient": "<your wallet address>",
  "rpc_url": "https://your-rpc.example",
  "min_usd": 1,
  "max_usd": 1000
}
```

The payer sends USDC on Solana to the operator's wallet and the key is
credited when the transfer is final. The gateway still holds no keys and
moves no funds: it only reads the chain, through a Solana JSON-RPC
endpoint.

| Field | Default | Meaning |
|---|---|---|
| `recipient` | required | The operator's **wallet** address (the owner, not a token account). **Check it twice.** |
| `rpc_url` | `https://api.mainnet-beta.solana.com` | The JSON-RPC endpoint the chain is read through. The default is Solana's public one, which is rate limited and meant for trying things; use your own or a provider's for real traffic. The gateway believes what this endpoint says. |
| `mint` | USDC | The token taken. It should be a dollar stablecoin: what arrives is credited one to one. |
| `decimals`, `symbol` | `6`, `USDC` | The mint's decimals (6 to 12) and its name on the top-up page. |
| `commitment` | `finalized` | When a transfer is believed: `finalized` (about 15 seconds) or `confirmed` (a second or two, and in theory reversible). |
| `min_usd`, `max_usd`, `quote_ttl_s`, `poll_interval_s` | as above | As for the other provider. Here `quote_ttl_s` is exactly how long a payment is watched for. |

**How a transfer is recognized.** Every payment goes to the same wallet, so
each one is told apart in two ways, and either is enough:

- **By a reference.** A payment has a fresh `deposit.reference` (32 random
  bytes written like an address) and a `deposit.url`: a
  [Solana Pay](https://docs.solanapay.com/spec) transfer request,
  `solana:<wallet>?amount=…&spl-token=<mint>&reference=…`. A wallet that
  opens the link or scans it (the top-up page draws it as the QR code)
  adds the reference to the transfer as a read-only account, and the
  gateway finds the transaction by asking the chain for transactions that
  mention the reference. A program does the same by adding the reference
  to its transfer instruction's accounts (non-signer, read-only).
- **By the exact amount.** The amount to send is what was asked for plus a
  fraction of a cent that no other open payment has: `10` becomes, say,
  `10.004217`. A plain transfer of **exactly** that amount, to the last
  digit, made after the payment was started, is that payment. This is for
  payers whose wallet cannot open a Solana Pay link. The gateway looks
  through the 50 latest transactions of the wallet's token account at each
  poll, so a wallet that receives more than that between two polls should
  be paid by reference.

For a transaction found either way, the gateway reads the transaction and
takes the amount from its token balances: how much more of the mint the
wallet owns after it than before. A failed transaction counts for nothing.

**What differs from the rest of this page.**

- `refund_to` is not needed and not asked for (`GET /v1/payments/assets`
  says `"refund_address": false`). **Nothing is refunded automatically**:
  the money is in the operator's wallet the moment it is paid, and giving
  it back is the operator's act. A payment never becomes `refunded` or
  `failed`; it is credited or it expires.
- There is one asset, `solana:<mint>`, and no swap: `processing` means "on
  the chain, not final yet".
- **What arrived is credited**, as everywhere, including the fraction of a
  cent. A transfer with the reference that carries less than was asked is
  credited as what it carried and ends the payment; one that carries more
  is credited up to 5% above what was asked. Only the first transfer of a
  payment is credited.
- **What is not recognized**: a transfer after the payment expired, and a
  transfer by hand whose amount is not exactly the payment's. The money
  has arrived all the same; the operator sees it in the wallet and can add
  the credit by hand
  ([`POST /admin/keys/{name}/topup`](building-on-omnigate.md#taking-payments-prepaid-keys-and-top-ups)).
- A payment is credited under the reference `solana:<deposit.reference>`.
- **What is trusted**: the RPC endpoint. The gateway does not verify the
  chain's own signatures; an endpoint that lies about a transaction can
  make the gateway credit a key for nothing. Nothing an endpoint says can
  move the operator's funds.

**Tested**: against a stand-in for the RPC endpoint
([`tools/mock_solana.py`](../tools/mock_solana.py)) in the unit and
end-to-end suites, and the three calls the gateway makes against the real
public mainnet endpoint, read-only
(`python tools/solana_live.py`, 14 November 2026: the answers have the
fields the gateway reads; it also showed that the chain now carries
version 1 transactions, which the gateway asks for). **No real payment has
been made through this provider.** `python tools/solana_live.py --wallet
<your wallet>` shows what the gateway would see of your wallet.

## The top-up page

For a person rather than a program: **`GET /topup`** on the gateway's port
(`http://127.0.0.1:8080/topup`) is a page that does the same three calls.

1. The holder types the gateway key. The page shows the credit left on it
   and the key's earlier payments.
2. They choose an amount, a network and an asset, give a refund address,
   and ask for a quote. Nothing is started until they press *Start payment*.
3. The page shows what to send where, with the deposit address as a QR
   code and a countdown to the deadline, and follows the payment until the
   credit is added. A payment that is still open can be opened again later
   with the key.

What to know about it:

- **It asks for no sign-in and holds nothing secret.** Anyone who can reach
  the gateway can load it; everything it shows comes from the payments API
  with the key that was typed in.
- **The key stays in the page.** It is not put in a cookie, in browser
  storage or in the address, and it is sent only to this gateway. Reloading
  the page forgets it.
- **Nothing is loaded from elsewhere.** The page is one document with its
  own style and script (a `Content-Security-Policy` with a nonce, no
  third-party request, `Cache-Control: no-store`); the QR code is drawn in
  the page.
- **The QR code holds the deposit address only**, which every wallet reads.
  The amount, and a memo where the network needs one, are typed or copied.
- It exists only while payments are configured: a `404` otherwise.

Serve the gateway over HTTPS before giving this address to anyone: a key
typed into a page that came over plain HTTP can be read on the way.

## The API

On the gateway's port, with a gateway key, like every other endpoint. **A
key whose credit is spent can still use all of these**; that is what they
are for.

| Method and path | Purpose |
|---|---|
| `GET /v1/payments/assets` | What can be paid with. `?chain=` and `?symbol=` narrow the list. The answer also names the `provider` and says whether a payment needs a refund address (`refund_address`). |
| `POST /v1/payments/quote` | What a payment would take, without starting one. |
| `POST /v1/payments` | Start a payment: get a deposit address and the amount to send. |
| `GET /v1/payments/{id}` | The payment and its state. |
| `GET /v1/payments` | The key's payments, newest first (up to 50), and under `"credits"` what is left on the key (`balance_usd`, `burned_usd`; null for a key that is not prepaid). |
| `POST /v1/payments/{id}/tx` | Optional: tell the provider which transaction carries the deposit. |

### Assets

```bash
curl -s "http://127.0.0.1:8080/v1/payments/assets?chain=near" -H "Authorization: Bearer $KEY"
```

```json
{ "assets": [ { "asset": "nep141:wrap.near", "symbol": "wNEAR", "chain": "near", "decimals": 24, "price_usd": 3.7 } ] }
```

The list is the provider's, fetched at most every five minutes. `asset` is
what the other calls take.

### A quote, without starting anything

```bash
curl -s http://127.0.0.1:8080/v1/payments/quote -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"amount_usd": 5, "asset": "nep141:wrap.near", "refund_to": "payer.near"}'
```

```json
{ "amount_usd": 5.0, "asset": "nep141:wrap.near", "symbol": "wNEAR", "chain": "near",
  "amount": "1.3638", "amount_units": "1363800000000000000000000", "min_amount_units": "1350200000000000000000000",
  "deposit_usd": "5.06", "time_estimate_s": 20, "provider": "near_intents" }
```

Nothing is created at the provider and there is no deposit address.

### Starting a payment

```bash
curl -s http://127.0.0.1:8080/v1/payments -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"amount_usd": 5, "asset": "nep141:wrap.near", "refund_to": "payer.near"}'
```

| Field | Meaning |
|---|---|
| `amount_usd` | How much credit to buy, in US dollars, between `min_usd` and `max_usd`. Rounded to whole cents. |
| `asset` | The asset to pay with, from the assets list. |
| `refund_to` | An address **on the chain of that asset** that gets the funds back if the payment fails, and anything the swap did not need. Use the address the payment is sent from. |

The answer is `201`:

```json
{
  "id": "pay_3f9c1e0a5b7d2c4e6f8a0b1c",
  "status": "awaiting_deposit",
  "amount_usd": 5.0,
  "credited_usd": null,
  "provider": "near_intents",
  "deposit": {
    "address": "8f3a…c21e",
    "memo": null,
    "asset": "nep141:wrap.near", "symbol": "wNEAR", "chain": "near",
    "amount": "1.3638", "amount_units": "1363800000000000000000000",
    "min_amount_units": "1350200000000000000000000", "amount_usd": "5.06"
  },
  "refund_to": "payer.near",
  "deadline": "2026-11-11T21:00:00.000Z",
  "time_estimate_s": 20,
  "detail": null, "provider_status": null, "tx": [],
  "created_at": "2026-11-11T20:30:00Z", "updated_at": "2026-11-11T20:30:00Z"
}
```

**Send exactly `deposit.amount` of the asset to `deposit.address` before
`deadline`**, from a wallet of your own. When `deposit.memo` is not null the
chain needs it with the transfer (Stellar, for one): a deposit without it is
not recognized. Sending less than `min_amount_units` is refunded by the
provider when the deadline passes; sending more is swapped and the excess
refunded.

Then ask for the payment until its `status` is an end state. An agent's
loop, with the three calls, is
[`examples/agent_pays.py`](../examples/agent_pays.py).

### Errors

| Status | `code` | When |
|---|---|---|
| 400 | `invalid_request` | `amount_usd` outside the bounds or not a number; `asset` or `refund_to` not well-formed. |
| 400 | `payment_quote_refused` | The provider refused the request. Its own words are in the message: an address that is not one on that chain, an amount below what a bridge takes, a chain's minimum, a pair it does not quote. |
| 404 | `not_found` | Payments are not configured on this gateway. |
| 404 | `payment_not_found` | No such payment, or it is another key's. |
| 409 | `not_prepaid` | The key is not a prepaid managed key. |
| 409 | `payment_closed` | `POST …/tx` on a payment that has ended. |
| 429 | `too_many_open_payments` | The key has five payments waiting for a deposit. |
| 429 | `rate_limited` | More than six quotes or payments a minute for one key (the key's own `rpm` also applies). |
| 502 | `payment_provider_error` | The provider answered something that was not used: an answer that could not be read, or a quote that is not signed by its key or does not repeat what was asked. **No deposit address is shown in that case.** |
| 503 | `payment_provider_unavailable` | The provider could not be reached, or is rate limiting. |

## States of a payment

```
awaiting_deposit → processing → settled      credited_usd is set: the key was credited
                              → refunded     the provider gave the funds back to refund_to
                              → failed       the provider could not complete the swap
awaiting_deposit → expired                   nothing arrived by the deadline (plus 15 minutes)
```

- `provider_status` is the provider's own word (`PENDING_DEPOSIT`,
  `KNOWN_DEPOSIT_TX`, `PROCESSING`, `INCOMPLETE_DEPOSIT`, `SUCCESS`,
  `REFUNDED`, `FAILED`); `detail` says in a few words what a payer should
  know (a deposit that fell short, why something was refunded).
- `tx` lists transaction hashes the provider reported, to look the payment
  up on a chain explorer.
- A payment that is `settled` with `credited_usd` null reached the operator
  but could not be credited (the key was deleted, or is no longer prepaid);
  `detail` says so. Nothing is credited anywhere else. That one is between
  the payer and the operator.

## What is credited, and when

- **What arrived**: the amount of the settle asset the provider reports as
  delivered, as US dollars one to one. For a $5 payment that is $5 (the
  quote is for an exact output); if less arrives, less is credited. An
  amount more than 5% above what was asked for is not believed beyond that.
- **Once**: the credit goes through the same idempotent top-up as every
  other, under the reference `near_intents:<deposit address>` (with
  `:<memo>` where there is one). The provider reporting success a hundred
  times, a restart in the middle, two polls racing: one credit.
- **As credit like any other**, from source `near_intents`; it earns the
  [weekly bonus](credits.md#the-weekly-bonus) where one is set.
- **When**: within one poll interval of the provider reporting success, and
  the data plane unblocks the key with its next config poll (a second or
  two by default).

## What is checked, and what is trusted

Checked by the gateway:

- **A quote is signed by the provider.** 1Click signs each quote with an
  Ed25519 key; the gateway verifies it against that key (pinned in the
  source, taken from 1Click's own SDK) before the deposit address is shown
  to anyone. The signature covers the deposit address, the recipient, the
  amounts and the refund address.
- **The quote repeats what was asked**: the operator's recipient, the settle
  asset, the exact amount, the payer's refund address.
- **A status answer is about our quote**: it carries the quote it refers
  to, which must be the one stored (same signature, same deposit address,
  same recipient). An answer about another quote is not believed and the
  payment stays open.
- **Nothing a client says is trusted**: not an amount, not a status, not a
  transaction hash (which is only passed on to the provider as a hint).

Trusted, and you should know it:

- **That the funds arrived.** `SUCCESS` and the delivered amount are the
  provider's word, received over TLS from the configured host. The status
  itself is not signed, and the gateway does not look at the NEAR chain to
  confirm the transfer. Someone who controls the provider's API, or can
  impersonate it to the control plane, can make the gateway credit keys:
  credit, not money, and never more than the amount of a quote that the
  provider itself signed plus 5%. Reconcile what `GET /admin/payments`
  lists against what your account received.
- **The provider's asset list and prices**, for what a payer is shown.

One oddity of the real service: some assets are listed twice (Bitcoin as
`nep141:btc.omft.near` and as `1cs_v1:btc:native:coin`), and a quote asked
for under the first id is signed as if it had been asked for under the
second. The gateway therefore accepts a signature that names the paying
asset by another id the provider's own list gives the same coin on the same
chain. Everything else in the signature must be exactly what was asked.

## Fees, limits and refunds

All of these are the provider's; the gateway adds nothing of its own to a
payment. (What a request then burns of the credit is the
[burn multiplier](credits.md#the-burn-multiplier), which is the operator's.)

- **Fees** are inside the quote: the payer is asked to send a little more
  than the dollar amount. Without a partner token 1Click adds 0.25% to
  every quote; with one (`jwt_env`), 0.20%, or 0.01% for stablecoin pairs.
  Network fees of the paying chain are the payer's.
- **Minimums**: the provider refuses amounts below what a bridge takes
  (about $6 for Bitcoin when this was written) and has per-chain minimums
  ($1,000 on BNB Chain, $100 from Tron, when this was written). The refusal
  comes back as `400 payment_quote_refused` with the provider's reason.
- **Refunds** go from the provider to `refund_to`, on the paying chain: when
  less than the required amount arrives by the deadline, when the swap
  fails, and for whatever a swap did not need. The gateway never refunds
  anything, and credit that was applied is not taken back.
- **A deposit after the deadline** may not be recognized by the provider.
  Start a new payment instead.

## For operators

- **`GET /admin/payments?limit=<n>`**: every payment, newest first, with the
  key's name, the reference it is credited under and the recipient it was
  quoted for; `"configured": false` when payments are off.
- **Audit log**: `payment.create`, `payment.settle` (outcome `ok`, or
  `uncredited` when the key could not be credited), `payment.refunded`,
  `payment.failed`; all written by the gateway itself (`"auth": "system"`).
  The credit is also a `key.topup`-like line in the top-up history
  (`GET /admin/topups`) and a `credit` event in the usage feed.
- **Metrics**: `omnigate_payments{status}` and
  `omnigate_payments_credited_usd`.
- **Storage**: `OMNIGATE_PAYMENTS`, rewritten atomically on every change.
  At most 5,000 payments are kept; ones that ended more than 90 days ago
  are dropped. Open payments survive a restart and are asked about again.
  Back the file up with the key store: a payment that is forgotten while
  open is never credited by itself (credit it by hand with a top-up under
  the same reference, `near_intents:<deposit address>`, which stays
  idempotent).
- **Changing `recipient`** affects new payments; open ones keep the
  recipient they were quoted for.
- **The dashboard** has a Payments page (`/payments`, linked from the top
  bar while payments are configured): the credit left on every prepaid key,
  a form to add credit by hand (`POST /admin/keys/{name}/topup`), every
  payment with its state, and every top-up and bonus.

## What has been tested

- **Against the real service, without funds** (`tools/near_intents_live.py`,
  11 November 2026): the asset list (229 assets on 39 chains) and dry quotes
  for NEAR, Ether, Bitcoin, SOL and USDC on Base and Arbitrum through a
  running gateway, each with its signature verified; the provider's
  refusals relayed. A dry quote creates nothing.
- **Against a mock** (`tools/mock_intents.py`, in the end-to-end suite and in
  the control plane's tests): everything after a deposit. A blocked key
  paying and being unblocked, settlement seen many times and credited once,
  refunds, failures, short deposits, quotes and statuses that are forged or
  about another quote, a memo chain, a restart in the middle of a payment,
  the agent example.
- **One real payment** (12 November 2026, through the
  [top-up page](#the-top-up-page)): $1 of credit paid with 0.000506 ETH on
  Ethereum mainnet. The payment went `awaiting_deposit` → `processing`
  (`PROCESSING`, with the deposit's transaction hash) → `settled`
  (`SUCCESS`) 31 seconds later, and the key was credited $1.00 once, under
  `near_intents:<deposit address>`. The provider gave that deposit address
  a deadline three days away, not the 30 minutes of `quote_ttl_s`.
- **Not done with real funds:** a refund, a failure, a short deposit, an
  expiry, an asset with a memo, and any amount above a dollar. Those have
  only met the mock. That the operator's account received the USDC was not
  checked by the gateway (it never is: see above) and was not looked up by
  hand either.

## Trying it with real funds

One small payment, by hand. There is no test network for NEAR Intents: this
uses real funds, so use a dollar or two.

1. Put your own NEAR account in `payments.recipient` of
   `config/omnigate.payments.json`, and make sure it can receive USDC (hold
   a little of it once).
2. Start the gateway with that config and a prepaid key:

   ```bash
   python tools/near_intents_live.py --serve
   ```

   It prints the recipient, a key with no credit and the admin token, and
   the commands below with the key filled in. It sends nothing itself.
3. See what $1 would take, without starting anything:

   ```bash
   curl -s http://127.0.0.1:8080/v1/payments/quote -H "authorization: Bearer $KEY" -H "content-type: application/json" -d '{"amount_usd": 1, "asset": "nep141:wrap.near", "refund_to": "<your NEAR account>"}'
   ```

4. Start the payment (this creates a deposit address at NEAR Intents):

   ```bash
   curl -s http://127.0.0.1:8080/v1/payments -H "authorization: Bearer $KEY" -H "content-type: application/json" -d '{"amount_usd": 1, "asset": "nep141:wrap.near", "refund_to": "<your NEAR account>"}'
   ```

5. From your own wallet, send exactly `deposit.amount` of the asset to
   `deposit.address` before `deadline`.
6. Watch it: `GET /v1/payments/<id>` should go from `awaiting_deposit` to
   `settled` with `credited_usd` of 1, and `GET /admin/keys` should show the
   key with a budget of 1 and a balance of one dollar. Your account
   should hold one more USDC.

The same can be done on the [top-up page](#the-top-up-page) instead of
steps 3 to 6: open `http://127.0.0.1:8080/topup` and type the key.

Paying with wrapped NEAR from a NEAR account keeps the fees lowest. If the
payment ends as `refunded` or `expired`, nothing was credited and the
provider returns what it received to `refund_to`.
