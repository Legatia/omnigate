defmodule OmnigateControl.CreditsTest do
  # Prepaid credit: the burn multiplier, the two kinds of credit, and the
  # weekly bonus. The second half changes the shared key store and config and
  # moves the key store's clock, so not alongside other tests.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{Audit, ConfigStore, Credits, Keys, Ledger, Router}

  @admin "test-admin-token-0123456789"
  @moduletag :capture_log

  @week 604_800
  @day 86_400
  # Monday 9 November 2026, 00:00 UTC: the start of ISO week 2026-W46.
  @monday DateTime.to_unix(~U[2026-11-09 00:00:00Z])

  # ============================================================ the rule itself

  describe "settings" do
    test "nothing configured is the behaviour without credit" do
      assert Credits.normalize!(nil) == %{burn_multiplier: 1.0, bonus_annual_rate: 0.0, sample_interval_s: 900, admin_topups_eligible: false}
      assert Credits.normalize!(%{}) == Credits.defaults()
      assert %{credits: %{burn_multiplier: 1.0, bonus_annual_rate: +0.0}, payments: nil} = ConfigStore.normalize(%{})
    end

    test "what is set is taken; what is not understood is refused" do
      assert %{burn_multiplier: 1.2, bonus_annual_rate: 0.05, sample_interval_s: 60, admin_topups_eligible: true} =
               Credits.normalize!(%{"burn_multiplier" => 1.2, "bonus_annual_rate" => 0.05, "sample_interval_s" => 60, "admin_topups_eligible" => true})

      for bad <- [
            %{"burn_multiplier" => 0},
            %{"burn_multiplier" => "1.2"},
            %{"burn_multiplier" => 101},
            %{"bonus_annual_rate" => -0.01},
            %{"bonus_annual_rate" => 11},
            %{"sample_interval_s" => 0},
            %{"sample_interval_s" => 1.5},
            %{"admin_topups_eligible" => "yes"},
            %{"burn_multipler" => 1.2},
            "1.2"
          ] do
        assert_raise ArgumentError, fn -> Credits.normalize!(bad) end
      end

      assert_raise ArgumentError, ~r/burn_multiplier/, fn ->
        ConfigStore.normalize(%{"keys" => [%{"name" => "a", "key" => "k", "budget_usd" => 1, "burn_multiplier" => -1}]})
      end
    end
  end

  describe "weeks" do
    test "ISO weeks in UTC, Monday to Monday" do
      assert Credits.week_start(@monday) == @monday
      assert Credits.week_start(@monday + 3 * @day + 17) == @monday
      assert Credits.week_start(@monday - 1) == @monday - @week
      assert Credits.week_id(@monday) == "2026-W46"
      assert Credits.week_id(@monday - 1) == "2026-W45"
      # The last days of 2026 belong to week 53, the first Monday of 2027 opens week 1.
      assert Credits.week_id(DateTime.to_unix(~U[2026-12-31 12:00:00Z])) == "2026-W53"
      assert Credits.week_id(DateTime.to_unix(~U[2027-01-04 00:00:00Z])) == "2027-W01"
      assert Credits.bonus_reference("acme", "2026-W46") == "bonus:acme:2026-W46"
    end
  end

  describe "spending" do
    test "draws on plain credit first, then on eligible credit" do
      assert Credits.draw(10.0, 10.0, 4.0) == {6.0, 10.0}
      assert Credits.draw(10.0, 10.0, 15.0) == {0.0, 5.0}
      assert Credits.draw(10.0, 10.0, 20.0) == {0.0, 0.0}
      # The request that crosses zero is still paid for: it leaves plain below zero.
      assert Credits.draw(10.0, 10.0, 25.0) == {-5.0, 0.0}
      assert Credits.draw(0.0, 3.0, 1.0) == {0.0, 2.0}
    end

    test "eligible credit first pays off a balance below zero" do
      state = %{Credits.new(-5.0, 30.0, @monday) | "eligible" => 0.0}
      assert %{"plain" => plain, "eligible" => eligible} = Credits.credit(state, 10.0, true)
      assert {plain, eligible} == {0.0, 5.0}
      assert %{"plain" => 5.0, "eligible" => +0.0} = Credits.credit(state, 10.0, false)
      # An operator lowering the budget takes plain credit first, then eligible.
      held = %{Credits.new(4.0, 0.0, @monday) | "eligible" => 10.0}
      assert %{"plain" => plain, "eligible" => eligible} = Credits.adjust(held, -6.0)
      assert {plain, eligible} == {0.0, 8.0}
    end

    test "a state brought up to date draws the burn since it was last looked at" do
      state = %{Credits.new(10.0, 100.0, @monday) | "eligible" => 10.0}
      {now, bonuses} = Credits.advance(state, @monday + 3600, 115.0, 0.0)
      assert bonuses == []
      assert {now["plain"], now["eligible"], now["burned"], now["at"]} == {0.0, 5.0, 115.0, @monday + 3600}
      assert Credits.balance(now) == 5.0
      # Looking twice changes nothing more, and a clock that went back moves nothing back.
      assert {^now, []} = Credits.advance(now, @monday + 3600, 115.0, 0.0)
      assert {%{"at" => at, "eligible" => 5.0}, []} = Credits.advance(now, @monday, 115.0, 0.0)
      assert at == @monday + 3600
    end
  end

  describe "the weekly bonus" do
    # 5.2% a year is exactly 0.1% a week.
    @rate 0.052

    defp eligible(amount, at), do: %{Credits.new(0.0, 0.0, at) | "eligible" => amount * 1.0}

    test "a balance held all week earns the weekly rate on it" do
      {state, [{week, bonus, at}]} = Credits.advance(eligible(100, @monday), @monday + @week, 0.0, @rate)
      assert week == "2026-W46"
      assert at == @monday + @week
      assert_in_delta bonus, 0.1, 1.0e-12
      # The bonus is eligible credit itself, and the new week starts empty.
      assert_in_delta state["eligible"], 100.1, 1.0e-12
      assert state["integral"] == 0.0
      assert state["last_bonus"] == %{"week" => "2026-W46", "amount_usd" => bonus, "at" => @monday + @week}
    end

    test "a balance held for part of the week earns that part" do
      # Credited on Thursday noon: three and a half days of seven.
      {_, [{_, bonus, _}]} = Credits.advance(eligible(100, @monday + div(@week, 2)), @monday + @week, 0.0, @rate)
      assert_in_delta bonus, 0.05, 1.0e-12
    end

    test "the average follows top-ups and spending inside the week" do
      # 100 for two days, 40 more from Wednesday (140 for two days), then 80
      # of it spent on Friday at midnight (60 for three days).
      s = eligible(100, @monday)
      {s, []} = Credits.advance(s, @monday + 2 * @day, 0.0, @rate)
      s = Credits.credit(s, 40.0, true)
      {s, []} = Credits.advance(s, @monday + 4 * @day, 0.0, @rate)
      # Spent in one second, so that the straight line between samples is short.
      {s, []} = Credits.advance(s, @monday + 4 * @day + 1, 80.0, @rate)
      assert s["eligible"] == 60.0
      {_, [{_, bonus, _}]} = Credits.advance(s, @monday + @week, 80.0, @rate)
      average = (100 * 2 + 140 * 2 + 60 * 3) / 7
      assert_in_delta bonus, average * 0.001, 1.0e-6
    end

    test "between two samples the balance is taken to have moved in a straight line" do
      # One look at the start, the next at the end: 100 went down to 0.
      {state, [{_, bonus, _}]} = Credits.advance(eligible(100, @monday), @monday + @week, 100.0, @rate)
      assert_in_delta bonus, 50 * 0.001, 1.0e-12
      # The bonus is what the key now holds.
      assert_in_delta state["eligible"], bonus, 1.0e-12
    end

    test "plain credit earns nothing, and shields eligible credit from spending" do
      state = %{Credits.new(50.0, 0.0, @monday) | "eligible" => 100.0}
      # 50 spent over the week: all of it plain.
      {state, [{_, bonus, _}]} = Credits.advance(state, @monday + @week, 50.0, @rate)
      assert_in_delta bonus, 0.1, 1.0e-12
      assert state["plain"] == 0.0
      assert {_, []} = Credits.advance(Credits.new(500.0, 0.0, @monday), @monday + @week, 0.0, @rate)
    end

    test "weeks missed are closed one by one, each once, and the bonus compounds" do
      {state, bonuses} = Credits.advance(eligible(100, @monday), @monday + 3 * @week + 5 * @day, 0.0, @rate)
      assert Enum.map(bonuses, &elem(&1, 0)) == ["2026-W46", "2026-W47", "2026-W48"]
      [b1, b2, b3] = Enum.map(bonuses, &elem(&1, 1))
      assert_in_delta b1, 100 * 0.001, 1.0e-12
      assert_in_delta b2, (100 + b1) * 0.001, 1.0e-12
      assert_in_delta b3, (100 + b1 + b2) * 0.001, 1.0e-12
      assert_in_delta state["eligible"], 100 + b1 + b2 + b3, 1.0e-12
      # Five days into the fourth week are in its integral, not paid yet.
      assert_in_delta state["integral"], state["eligible"] * 5 * @day, 1.0e-3
      assert {_, []} = Credits.advance(state, @monday + 3 * @week + 6 * @day, 0.0, @rate)
    end

    test "a week whose bonus exists already is not credited again" do
      credited? = fn week -> week == "2026-W46" end
      {state, bonuses} = Credits.advance(eligible(100, @monday), @monday + 2 * @week, 0.0, @rate, credited?)
      assert [{"2026-W47", _, _}] = bonuses
      assert_in_delta state["eligible"], 100.1, 1.0e-12
    end

    test "no rate, no bonus; and less than a millionth of a dollar is not credited" do
      assert {%{"eligible" => 100.0, "integral" => +0.0}, []} = Credits.advance(eligible(100, @monday), @monday + @week, 0.0, 0.0)
      assert {%{"eligible" => 0.0005}, []} = Credits.advance(eligible(0.0005, @monday), @monday + @week, 0.0, @rate)
    end
  end

  # ====================================================== keys, ledger, admin API

  setup do
    original = :persistent_term.get({ConfigStore, :config})

    on_exit(fn ->
      Application.delete_env(:omnigate_control, :credits_clock)
      for k <- Keys.managed(), do: Keys.delete(k.name)
      :persistent_term.put({ConfigStore, :config}, original)
    end)

    {:ok, original: original}
  end

  defp settings(original, changes), do: :persistent_term.put({ConfigStore, :config}, Map.put(original, :credits, Map.merge(Credits.defaults(), changes)))
  defp clock(unix), do: Application.put_env(:omnigate_control, :credits_clock, fn -> unix end)
  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp admin(method, path, body \\ nil) do
    conn =
      case body do
        nil -> conn(method, path)
        _ -> conn(method, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json")
      end

    conn = conn |> put_req_header("authorization", "Bearer " <> @admin) |> Router.call(Router.init([]))

    json =
      case JSON.decode(conn.resp_body || "") do
        {:ok, value} -> value
        _ -> nil
      end

    {conn.status, json}
  end

  defp create(attrs) do
    name = unique("credit")
    {201, %{"key" => raw}} = admin(:post, "/admin/keys", Map.put(attrs, "name", name))
    {name, OmnigateControl.sha256_hex(raw)}
  end

  defp key(name), do: Enum.find(Keys.managed(), &(&1.name == name))
  defp view(name), do: admin(:get, "/admin/keys") |> elem(1) |> Map.fetch!("keys") |> Enum.find(&(&1["name"] == name))

  # A media job that cost the provider `usd`.
  defp spend(hash, usd) do
    {:ok, %{accepted: 1}} = Ledger.record_media(%{"id" => unique("job"), "key_sha256" => hash, "status" => 200, "cost_usd" => usd, "route_model" => "m"})
  end

  defp topup(name, amount, extra \\ %{}) do
    admin(:post, "/admin/keys/#{name}/topup", Map.merge(%{"amount_usd" => amount, "reference" => unique("pay")}, extra))
  end

  defp stored(name) do
    path = :sys.get_state(Keys).path
    path |> File.read!() |> JSON.decode!() |> Map.fetch!("keys") |> Enum.find(&(&1["name"] == name))
  end

  defp events(name) do
    {200, %{"events" => events}} = admin(:get, "/admin/events?limit=1000&key=#{name}")
    events
  end

  # Stopped and started by its supervisor (not killed: a kill counts towards
  # the supervisor's restart limit, which other tests use up too).
  defp restart_keys do
    :ok = Supervisor.terminate_child(OmnigateControl.Supervisor, Keys)
    {:ok, _} = Supervisor.restart_child(OmnigateControl.Supervisor, Keys)
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  describe "the burn multiplier" do
    test "a prepaid key burns cost times the multiplier, and is blocked when that reaches its credit", %{original: original} do
      settings(original, %{burn_multiplier: 1.2})
      {name, hash} = create(%{"budget_usd" => 1.2})

      spend(hash, 0.5)
      assert_in_delta Keys.credits_burned(key(name)), 0.6, 1.0e-12
      refute Keys.over_budget?(key(name))
      assert %{"state" => "active", "cost_usd" => 0.5, "credits_burned_usd" => burned, "period_spend_usd" => burned} = view(name)
      assert_in_delta burned, 0.6, 1.0e-12

      # One dollar of provider cost is all of 1.20 of credit.
      spend(hash, 0.5)
      assert Keys.over_budget?(key(name))
      assert %{"state" => "blocked", "cost_usd" => 1.0, "credits" => %{"balance_usd" => balance, "burned_usd" => 1.2, "burn_multiplier" => 1.2}} = view(name)
      assert_in_delta balance, 0.0, 1.0e-9

      # Both figures are in the usage feed, per event.
      assert [%{"cost_usd" => 0.5, "credits_usd" => 0.6, "kind" => "media"}, %{"cost_usd" => 0.5, "credits_usd" => 0.6}] = events(name)

      # ... and in the metrics.
      metrics = admin_text("/metrics")
      assert metrics =~ ~s(omnigate_key_cost_usd_total{key="#{name}"} 1.0)
      assert metrics =~ ~s(omnigate_key_credits_burned_usd_total{key="#{name}"} 1.2)
    end

    test "a key's own multiplier wins; a key that is not prepaid is billed the cost", %{original: original} do
      settings(original, %{burn_multiplier: 1.2})
      {own, own_hash} = create(%{"budget_usd" => 10, "burn_multiplier" => 2})
      {monthly, monthly_hash} = create(%{"budget_usd" => 10, "budget_period" => "monthly", "burn_multiplier" => 2})
      {open, open_hash} = create(%{})

      for hash <- [own_hash, monthly_hash, open_hash], do: spend(hash, 1.0)

      assert Keys.credits_burned(key(own)) == 2.0
      assert %{"credits" => %{"burn_multiplier" => 2.0, "balance_usd" => 8.0}} = view(own)
      assert Keys.credits_burned(key(monthly)) == 1.0
      assert Keys.period_spend(key(monthly)) == 1.0
      assert %{"credits" => nil, "credits_burned_usd" => 1.0} = view(monthly)
      assert Keys.credits_burned(key(open)) == 1.0
      assert [%{"cost_usd" => 1.0, "credits_usd" => 1.0}] = events(open)

      # Back to the configured one with null; what was burned stays burned.
      assert {200, %{"credits" => %{"burn_multiplier" => 1.2}}} = admin(:patch, "/admin/keys/#{own}", %{"burn_multiplier" => nil})
      spend(own_hash, 1.0)
      assert_in_delta Keys.credits_burned(key(own)), 3.2, 1.0e-12

      for bad <- [0, -1, 101, "2"] do
        assert {400, _} = admin(:patch, "/admin/keys/#{own}", %{"burn_multiplier" => bad})
      end
    end

    test "at the default nothing changes: no second figure is written, and the key store is the file it was" do
      {name, hash} = create(%{"budget_usd" => 5})
      spend(hash, 1.0)
      assert Keys.credits_burned(key(name)) == 1.0
      assert Ledger.credits_extra(hash) == 0.0
      # The event on disk has no `credits_usd`; the feed shows the cost for it.
      refute Enum.any?(Ledger.recent(), &(&1["key_sha256"] == hash and Map.has_key?(&1, "credits_usd")))
      assert [%{"cost_usd" => 1.0, "credits_usd" => 1.0}] = events(name)

      assert {200, _} = admin(:patch, "/admin/keys/#{name}", %{"rpm" => 10})
      refute Map.has_key?(stored(name), "credits")
      refute Map.has_key?(stored(name), "burn_multiplier")
    end

    test "a data plane cannot say what an event burns", %{original: original} do
      settings(original, %{burn_multiplier: 1.2})
      {name, hash} = create(%{"budget_usd" => 5})
      {:ok, %{accepted: 1}} = Ledger.record_batch([%{"id" => unique("req"), "key_sha256" => hash, "status" => 200, "credits_usd" => -1000.0}])
      assert Keys.credits_burned(key(name)) == 0.0
    end
  end

  describe "two kinds of credit" do
    test "a top-up says whether it earns the bonus; spending takes the rest first", %{original: original} do
      settings(original, %{bonus_annual_rate: 0.052})
      clock(@monday + @day)
      {name, hash} = create(%{"budget_usd" => 0})

      assert {200, %{"topup" => %{"source" => "admin", "eligible" => false}}} = topup(name, 10)
      assert {200, %{"topup" => %{"source" => "near_intents", "eligible" => true}}} = topup(name, 10, %{"source" => "near_intents", "bonus_eligible" => true})
      assert %{"credits" => %{"balance_usd" => 20.0, "eligible_usd" => 10.0, "plain_usd" => 10.0}} = view(name)

      spend(hash, 4.0)
      assert %{"credits" => %{"balance_usd" => 16.0, "eligible_usd" => 10.0, "plain_usd" => 6.0}} = view(name)
      spend(hash, 11.0)
      assert %{"credits" => %{"balance_usd" => 5.0, "eligible_usd" => 5.0, "plain_usd" => +0.0}} = view(name)

      # Plain credit added later does not give back eligible credit that was spent.
      assert {200, _} = topup(name, 3)
      assert %{"credits" => %{"balance_usd" => 8.0, "eligible_usd" => 5.0, "plain_usd" => 3.0}} = view(name)

      # The history: newest first, with where each came from.
      assert {200, %{"topups" => [%{"amount_usd" => 3.0, "source" => "admin"}, %{"source" => "near_intents", "eligible" => true}, %{"amount_usd" => 10.0}]}} =
               admin(:get, "/admin/topups?key=#{name}")

      # ... and each is a line of the usage feed, in order with the usage.
      assert [
               %{"kind" => "credit", "amount_usd" => 10.0, "bonus_eligible" => false, "source" => "admin"},
               %{"kind" => "credit", "amount_usd" => 10.0, "bonus_eligible" => true, "source" => "near_intents", "budget_usd" => 20.0},
               %{"kind" => "media"},
               %{"kind" => "media"},
               %{"kind" => "credit", "amount_usd" => 3.0}
             ] = events(name)

      # Credit is not a request: the key's request count is its two jobs.
      assert %{"requests" => 2, "jobs" => 2} = view(name)
    end

    test "what a manual top-up is, when the call does not say, is the setting", %{original: original} do
      clock(@monday)
      {name, _} = create(%{"budget_usd" => 0})
      settings(original, %{admin_topups_eligible: true})
      assert {200, %{"topup" => %{"eligible" => true}}} = topup(name, 1)
      assert {200, %{"topup" => %{"eligible" => false}}} = topup(name, 1, %{"bonus_eligible" => false})

      for bad <- [%{"bonus_eligible" => "yes"}, %{"source" => "Bad Source"}, %{"source" => "bonus"}, %{"source" => 5}, %{"source" => String.duplicate("a", 41)}] do
        assert {400, _} = topup(name, 1, bad)
      end
    end

    test "a budget changed by hand moves plain credit; eligible credit covers what is taken beyond it", %{original: original} do
      settings(original, %{bonus_annual_rate: 0.052})
      clock(@monday)
      {name, _} = create(%{"budget_usd" => 4})
      assert {200, _} = topup(name, 10, %{"bonus_eligible" => true})
      assert %{"credits" => %{"eligible_usd" => 10.0, "plain_usd" => 4.0}} = view(name)
      assert {200, _} = admin(:patch, "/admin/keys/#{name}", %{"budget_usd" => 8})
      assert %{"credits" => %{"balance_usd" => 8.0, "eligible_usd" => 8.0, "plain_usd" => +0.0}} = view(name)
      # A key that stops being prepaid holds no credit.
      assert {200, %{"credits" => nil}} = admin(:patch, "/admin/keys/#{name}", %{"budget_period" => "monthly"})
      refute Map.has_key?(stored(name), "credits")
    end
  end

  describe "the weekly bonus, through the key store" do
    setup %{original: original} do
      settings(original, %{bonus_annual_rate: 0.052})
      :ok
    end

    test "is credited once when the week has ended, as a top-up of its own" do
      # Credited on Tuesday 00:00: six days of the week.
      clock(@monday + @day)
      {name, hash} = create(%{"budget_usd" => 0})
      assert {200, _} = topup(name, 100, %{"source" => "near_intents", "bonus_eligible" => true})

      # Nothing during the week.
      clock(@monday + 5 * @day)
      assert {:ok, []} = Keys.checkpoint()
      assert key(name).budget_usd == 100.0

      # The next Monday, an hour in.
      clock(@monday + @week + 3600)

      assert {:ok, [%{"reference" => reference, "key" => ^name, "amount_usd" => bonus, "source" => "bonus", "eligible" => true, "budget_usd" => budget}]} =
               Keys.checkpoint()

      assert reference == "bonus:#{name}:2026-W46"
      assert_in_delta bonus, 100 * 6 / 7 * 0.001, 1.0e-9
      assert budget == 100.0 + bonus
      assert key(name).budget_usd == budget
      assert %{"credits" => %{"balance_usd" => balance, "eligible_usd" => balance, "last_bonus" => %{"week" => "2026-W46"}}} = view(name)
      assert_in_delta balance, 100 + bonus, 1.0e-6

      # Again, at once and later in the same week: nothing more.
      assert {:ok, []} = Keys.checkpoint()
      clock(@monday + @week + 2 * @day)
      assert {:ok, []} = Keys.checkpoint()

      # After a restart of the key store: the same budget, and still nothing more.
      restart_keys()
      assert key(name).budget_usd == budget
      assert {:ok, []} = Keys.checkpoint()

      # It is in the top-up history, the usage feed and the audit log.
      assert {200, %{"topups" => [%{"reference" => ^reference, "source" => "bonus"}, %{"source" => "near_intents"}]}} = admin(:get, "/admin/topups?key=#{name}")

      assert [
               %{"kind" => "credit", "source" => "near_intents"},
               %{"kind" => "credit", "source" => "bonus", "reference" => ^reference, "bonus_eligible" => true}
             ] = events(name)

      wait_until(fn -> Enum.any?(Audit.recent(100), &(&1["action"] == "key.bonus" and &1["target"] == name)) end)

      assert %{"auth" => "system", "topup" => %{"reference" => ^reference}} =
               Enum.find(Audit.recent(100), &(&1["action"] == "key.bonus" and &1["target"] == name))

      # The reference cannot be used to credit the week by hand either.
      assert {409, _} = admin(:post, "/admin/keys/#{name}/topup", %{"amount_usd" => 1, "reference" => reference})
      _ = hash
    end

    test "weeks that ended while nothing was running are caught up, once each" do
      clock(@monday)
      {name, _} = create(%{"budget_usd" => 0})
      assert {200, _} = topup(name, 1000, %{"bonus_eligible" => true})

      # Down for three weeks and two days.
      restart_keys()
      clock(@monday + 3 * @week + 2 * @day)
      assert {:ok, bonuses} = Keys.checkpoint()
      assert Enum.map(bonuses, & &1["reference"]) == for(w <- 46..48, do: "bonus:#{name}:2026-W#{w}")
      [b1, b2, b3] = Enum.map(bonuses, & &1["amount_usd"])
      assert_in_delta b1, 1.0, 1.0e-9
      assert_in_delta b2, 1000 * 1.001 * 0.001, 1.0e-9
      assert_in_delta b3, 1000 * 1.001 * 1.001 * 0.001, 1.0e-9
      assert_in_delta key(name).budget_usd, 1000 + b1 + b2 + b3, 1.0e-9
      assert {:ok, []} = Keys.checkpoint()
    end

    test "a top-up that arrives after the week ended closes the week first" do
      clock(@monday)
      {name, _} = create(%{"budget_usd" => 0})
      assert {200, _} = topup(name, 100, %{"bonus_eligible" => true})
      # No sample in between: the next thing that happens is a top-up, in the next week.
      clock(@monday + @week + @day)
      assert {200, %{"topup" => %{"budget_usd" => budget}}} = topup(name, 50, %{"bonus_eligible" => true})
      assert_in_delta budget, 150.1, 1.0e-9

      assert {200, %{"topups" => [%{"amount_usd" => 50.0}, %{"source" => "bonus", "reference" => reference}, %{"amount_usd" => 100.0}]}} =
               admin(:get, "/admin/topups?key=#{name}")

      assert reference == "bonus:#{name}:2026-W46"
      assert {:ok, []} = Keys.checkpoint()
    end

    test "spending during the week lowers the average; plain credit and other keys earn nothing" do
      clock(@monday)
      {name, hash} = create(%{"budget_usd" => 0})
      {plain, _} = create(%{"budget_usd" => 500})
      {monthly, _} = create(%{"budget_usd" => 500, "budget_period" => "monthly"})
      assert {200, _} = topup(name, 100, %{"bonus_eligible" => true})

      # Sampled just before and just after half of it is spent, mid-week.
      clock(@monday + div(@week, 2) - 1)
      assert {:ok, []} = Keys.checkpoint()
      spend(hash, 50.0)
      clock(@monday + div(@week, 2))
      assert {:ok, []} = Keys.checkpoint()

      clock(@monday + @week)
      assert {:ok, [%{"key" => ^name, "amount_usd" => bonus}]} = Keys.checkpoint()
      assert_in_delta bonus, 75 * 0.001, 1.0e-6
      assert key(plain).budget_usd == 500.0
      assert key(monthly).budget_usd == 500.0
    end

    test "without a rate nothing is sampled and the key store is left alone", %{original: original} do
      settings(original, %{})
      clock(@monday)
      {name, _} = create(%{"budget_usd" => 0})
      assert {200, _} = topup(name, 100, %{"bonus_eligible" => true})
      before = File.stat!(:sys.get_state(Keys).path).mtime
      clock(@monday + 2 * @week)
      assert Credits.Sampler.run() == []
      assert File.stat!(:sys.get_state(Keys).path).mtime == before
      assert key(name).budget_usd == 100.0
    end
  end

  defp admin_text(path) do
    conn(:get, path) |> put_req_header("authorization", "Bearer " <> @admin) |> Router.call(Router.init([])) |> Map.fetch!(:resp_body)
  end
end
