defmodule OmnigateControl.Payments.Provider do
  @moduledoc """
  What a payment provider is to `OmnigateControl.Payments`: something that
  can say what it accepts, tell a payer where to send how much so that a
  given amount of the settle asset reaches the operator, and say later what
  became of it.

  A provider never holds the operator's funds on the gateway's behalf and the
  gateway never signs or sends anything: the payer pays the provider's
  deposit address, and the provider delivers to the operator's own account.

  `config` is the normalized `"payments"` section (`Payments.normalize!/1`).
  Adding a provider is one module with these callbacks and a line in
  `Payments.provider/1`.
  """

  @typedoc "An asset a payer may pay with."
  @type asset :: %{String.t() => term}

  @typedoc """
  A quote: where to send how much. String keys, stored with the payment:
  `deposit_address`, `deposit_memo` (nil unless the chain needs one),
  `amount_in` (smallest unit, a string), `amount_in_formatted`,
  `min_amount_in`, `amount_in_usd`, `deadline` (ISO 8601), `time_estimate_s`,
  and `proof` (whatever the provider signs a quote with, kept for disputes).
  """
  @type quoted :: %{String.t() => term}

  @typedoc """
  What became of a payment: `state` is `:awaiting_deposit`, `:processing`,
  `:settled`, `:refunded` or `:failed`; `delivered_usd` is what reached the
  operator (for `:settled`); `detail` a few words for the payer; `raw` the
  provider's own status word; `tx` transaction hashes, for looking it up.
  """
  @type outcome :: %{state: atom, delivered_usd: float | nil, detail: String.t() | nil, raw: String.t() | nil, tx: [String.t()]}

  @typedoc "A refusal, in the shape the gateway answers with: HTTP status, code, message."
  @type refusal :: {:error, pos_integer, String.t(), String.t()}

  @doc "The provider's settings with their defaults, validated. Raises `ArgumentError`."
  @callback normalize!(raw :: map) :: map

  @doc "Every asset a payer may pay with: `[%{\"asset\", \"symbol\", \"chain\", \"decimals\", \"price_usd\"}]`."
  @callback assets(config :: map) :: {:ok, [asset]} | refusal

  @doc """
  A quote for delivering `amount_usd` of the settle asset to the operator,
  paid with `asset`, refunded to `refund_to` if it fails, valid until
  `deadline` (unix seconds). With `dry: true` nothing is created and there
  is no deposit address.
  """
  @callback quote(config :: map, request :: %{amount_usd: float, asset: String.t(), refund_to: String.t(), deadline: integer, dry: boolean}) ::
              {:ok, quoted} | refusal

  @doc "What became of the payment made on a quote (the stored payment record)."
  @callback status(config :: map, payment :: map) :: {:ok, outcome} | {:error, term}

  @doc "Tell the provider which transaction carries the deposit (optional; only speeds it up)."
  @callback submit_tx(config :: map, payment :: map, tx_hash :: String.t()) :: :ok | refusal
end
