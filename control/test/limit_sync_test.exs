defmodule OmnigateControl.LimitSyncTest do
  # What data planes tell each other about rate limits, through the control plane.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{LimitSync, Metrics, Router}

  @internal "test-internal-token"

  setup do
    previous_token = System.get_env("OMNIGATE_INTERNAL_TOKEN")
    System.put_env("OMNIGATE_INTERNAL_TOKEN", @internal)
    on_exit(fn -> if previous_token, do: System.put_env("OMNIGATE_INTERNAL_TOKEN", previous_token), else: System.delete_env("OMNIGATE_INTERNAL_TOKEN") end)
    server = :"limit_sync_#{System.unique_integer([:positive])}"
    start_supervised!({LimitSync, name: server})
    {:ok, server: server}
  end

  defp key(char), do: String.duplicate(char, 64)
  defp took(char, n, rpm), do: %{"key" => key(char), "n" => n, "rpm" => rpm}
  defp sorted(others), do: Enum.sort_by(others, & &1.key)

  describe "LimitSync" do
    test "a data plane hears what the others allowed, once, and never its own", %{server: s} do
      # Alone, there is nobody to hear from or to tell.
      assert {:ok, [], 1} = LimitSync.sync("a", [took("1", 3, 60)], 0, s)
      assert {:ok, [], 1} = LimitSync.sync("a", [took("1", 2, 60)], 1000, s)

      # A second one appears: it was not there when that was reported.
      assert {:ok, [], 2} = LimitSync.sync("b", [took("1", 4, 60), took("2", 1, 5)], 1500, s)
      assert {:ok, others, 2} = LimitSync.sync("a", [took("1", 1, 60)], 2000, s)
      assert sorted(others) == [%{key: key("1"), n: 4, rpm: 60}, %{key: key("2"), n: 1, rpm: 5}]
      # Told once.
      assert {:ok, [], 2} = LimitSync.sync("a", [], 3000, s)

      # What "a" allowed since "b" appeared adds up until "b" asks.
      assert {:ok, [], 2} = LimitSync.sync("a", [took("1", 2, 60)], 3500, s)
      assert {:ok, [%{key: k, n: 3, rpm: 60}], 2} = LimitSync.sync("b", [], 4000, s)
      assert k == key("1")
    end

    test "with three data planes each hears the sum of the other two", %{server: s} do
      for id <- ["a", "b", "c"], do: assert({:ok, [], _} = LimitSync.sync(id, [], 0, s))
      assert {:ok, [], 3} = LimitSync.sync("a", [took("1", 5, 60)], 100, s)
      assert {:ok, [%{n: 5}], 3} = LimitSync.sync("b", [took("1", 7, 60)], 200, s)
      assert {:ok, [%{n: 12}], 3} = LimitSync.sync("c", [], 300, s)
      assert {:ok, [%{n: 7}], 3} = LimitSync.sync("a", [], 400, s)
    end

    test "a changed limit starts the count again", %{server: s} do
      for id <- ["a", "b"], do: LimitSync.sync(id, [], 0, s)
      LimitSync.sync("a", [took("1", 50, 60)], 100, s)
      LimitSync.sync("a", [took("1", 2, 120)], 200, s)
      assert {:ok, [%{n: 2, rpm: 120}], 2} = LimitSync.sync("b", [], 300, s)
    end

    test "a data plane that stops reporting is forgotten, with what waited for it", %{server: s} do
      for id <- ["a", "b"], do: LimitSync.sync(id, [], 0, s)
      assert LimitSync.instances(0, s) == 2
      assert {:ok, [], 2} = LimitSync.sync("a", [took("1", 9, 60)], 20_000, s)
      # "b" was last heard of at 0: thirty seconds later it is gone ...
      assert {:ok, [], 1} = LimitSync.sync("a", [], 31_000, s)
      assert LimitSync.instances(31_000, s) == 1
      # ... and when a "b" comes back it is new, and hears nothing old.
      assert {:ok, [], 2} = LimitSync.sync("b", [], 32_000, s)
      assert LimitSync.instances(100_000, s) == 0
    end

    test "entries that make no sense are dropped, and a report that makes none is refused", %{server: s} do
      LimitSync.sync("b", [], 0, s)

      odd = [
        took("1", 2, 60),
        %{"key" => "short", "n" => 1, "rpm" => 60},
        %{"key" => String.duplicate("Z", 64), "n" => 1, "rpm" => 60},
        %{"key" => key("2"), "n" => 0, "rpm" => 60},
        %{"key" => key("2"), "n" => -4, "rpm" => 60},
        %{"key" => key("2"), "n" => 1, "rpm" => 0},
        %{"key" => key("2"), "n" => "1", "rpm" => 60},
        %{"key" => key("2"), "n" => 1.5, "rpm" => 60},
        %{"key" => key("2"), "n" => 1},
        "not a map",
        nil
      ]

      assert {:ok, [], 2} = LimitSync.sync("a", odd, 100, s)
      assert {:ok, [%{key: k, n: 2, rpm: 60}], 2} = LimitSync.sync("b", [], 200, s)
      assert k == key("1")

      # A count beyond any real one is capped, not kept as sent.
      LimitSync.sync("a", [took("3", 10 ** 30, 60)], 300, s)
      assert {:ok, [%{n: 1_000_000_000}], 2} = LimitSync.sync("b", [], 400, s)

      assert {:error, _} = LimitSync.sync("", [], 0, s)
      assert {:error, _} = LimitSync.sync(String.duplicate("a", 65), [], 0, s)
      assert {:error, _} = LimitSync.sync("has space", [], 0, s)
      assert {:error, _} = LimitSync.sync(42, [], 0, s)
      assert {:error, _} = LimitSync.sync("a", %{"key" => "x"}, 0, s)
    end

    test "the number of data planes and of waiting keys is bounded", %{server: s} do
      for i <- 1..64, do: assert({:ok, [], ^i} = LimitSync.sync("dp-#{i}", [], 0, s))
      assert {:error, "too many data planes"} = LimitSync.sync("one-more", [], 0, s)
      # One that is known keeps working.
      assert {:ok, [], 64} = LimitSync.sync("dp-1", [], 1, s)

      # Far more keys than one report may carry: the rest is not read.
      many = for i <- 1..12_000, do: %{"key" => i |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"), "n" => 1, "rpm" => 60}
      LimitSync.sync("dp-1", many, 2, s)
      assert {:ok, others, 64} = LimitSync.sync("dp-2", [], 3, s)
      assert length(others) == 10_000
    end
  end

  describe "POST /internal/limits/sync" do
    defp post(body, headers \\ [{"x-omnigate-internal", @internal}]) do
      conn = conn(:post, "/internal/limits/sync", JSON.encode!(body)) |> put_req_header("content-type", "application/json")
      conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
      conn = Router.call(conn, Router.init([]))
      {conn.status, JSON.decode!(conn.resp_body)}
    end

    test "needs the internal token, and passes reports between data planes" do
      a = "test-a-#{System.unique_integer([:positive])}"
      b = "test-b-#{System.unique_integer([:positive])}"
      assert {401, _} = post(%{"instance" => a, "taken" => []}, [])

      assert {200, %{"others" => [], "instances" => n}} = post(%{"instance" => a, "taken" => []})
      assert {200, %{"others" => [], "instances" => m}} = post(%{"instance" => b, "taken" => [took("9", 3, 60)]})
      assert m == n + 1
      assert {200, %{"others" => others}} = post(%{"instance" => a, "taken" => []})
      assert %{"key" => key("9"), "n" => 3, "rpm" => 60} in others

      assert Metrics.render() =~ ~r/^omnigate_data_planes #{m}$/m

      assert {400, %{"error" => %{"code" => "invalid_request"}}} = post(%{"instance" => a})
      assert {400, %{"error" => %{"code" => "invalid_request"}}} = post(%{"instance" => "no spaces allowed", "taken" => []})
      assert {400, %{"error" => %{"code" => "invalid_request"}}} = post(%{"instance" => a, "taken" => "many"})
    end
  end
end
