defmodule OmnigateControl.LedgerTest do
  # Not async: the ledger is a single named process.
  use ExUnit.Case

  alias OmnigateControl.Ledger

  defp event(key, id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "key_sha256" => key,
        "route_model" => "demo-chat",
        "upstream" => "mock-ok",
        "target_model" => "ok-1",
        "status" => 200,
        "input_tokens" => 1_000,
        "output_tokens" => 1_000
      },
      overrides
    )
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "a batch is recorded and priced from the route config" do
    key = unique("key")

    assert {:ok, %{accepted: 2, duplicates: 0, invalid: 0}} =
             Ledger.record_batch([event(key, unique("e")), event(key, unique("e"))])

    totals = Ledger.totals(key)
    assert totals.requests == 2
    assert totals.input_tokens == 2_000
    # dev config: $100 in / $300 out per 1M tokens -> $0.40 per event
    assert_in_delta totals.cost_usd, 0.8, 1.0e-9
  end

  test "a resent batch is not billed twice" do
    key = unique("key")
    batch = [event(key, unique("e")), event(key, unique("e"))]

    assert {:ok, %{accepted: 2}} = Ledger.record_batch(batch)
    assert {:ok, %{accepted: 0, duplicates: 2}} = Ledger.record_batch(batch)
    assert Ledger.totals(key).requests == 2
  end

  test "the same id twice inside one batch counts once" do
    key = unique("key")
    id = unique("e")

    assert {:ok, %{accepted: 1, duplicates: 1}} =
             Ledger.record_batch([event(key, id), event(key, id)])

    assert Ledger.totals(key).requests == 1
  end

  test "malformed events are rejected without failing the batch" do
    key = unique("key")

    bad = [
      "not a map",
      %{"id" => unique("e")},
      event(key, unique("e"), %{"status" => "200"}),
      event(key, unique("e"), %{"input_tokens" => -5})
    ]

    assert {:ok, %{accepted: 1, invalid: 4}} = Ledger.record_batch(bad ++ [event(key, unique("e"))])
    assert Ledger.totals(key).requests == 1
  end

  test "event time comes from the data plane, not arrival time" do
    key = unique("key")
    id = unique("e")
    {:ok, _} = Ledger.record_batch([event(key, id, %{"ts_ms" => 1_700_000_000_000})])

    recorded = Enum.find(Ledger.recent(), &(&1["id"] == id))
    assert recorded["ts"] == "2023-11-14T22:13:20.000Z"
  end
end
