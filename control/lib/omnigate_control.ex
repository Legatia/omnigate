defmodule OmnigateControl do
  @moduledoc """
  omnigate control plane.

  Source of truth for gateway keys, budgets, routes and the usage ledger.
  Zig data-plane nodes pull `GET /internal/config` and push
  `POST /internal/usage/batch`; this node computes spend and flips keys to
  `blocked` when they exceed their budget.
  """

  @doc "Lowercase hex SHA-256, matching the data plane's `sha256Hex`."
  def sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
