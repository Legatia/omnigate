defmodule OmnigateControl.SumeTest.Stub do
  @moduledoc """
  A stand-in for Sume's model API, following its public documentation
  (envelopes in `data` / `error`, 202 on submit, status, result, cancel).
  What it answers is set per test.
  """
  use Plug.Router

  @table :omnigate_sume_stub

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["*/*"], length: 1_000_000)
  plug(:dispatch)

  def setup do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, [:named_table, :public, :set])
    :ets.delete_all_objects(@table)
  end

  def set(key, value), do: :ets.insert(@table, {key, value})

  def val(key, default \\ nil) do
    case :ets.lookup(@table, key) do
      [{_, v}] -> v
      [] -> default
    end
  end

  def bump(name), do: :ets.update_counter(@table, name, 1, {name, 0})
  def record(name, value), do: set(name, val(name, []) ++ [value])

  defp base(conn), do: "http://127.0.0.1:#{conn.port}"

  defp send_json(conn, status, body, headers \\ []),
    do:
      headers
      |> Enum.reduce(conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
      |> put_resp_content_type("application/json")
      |> send_resp(status, JSON.encode!(body))

  defp error(conn, status, code, opts \\ []) do
    retry = opts[:retry_after]

    body = %{
      error: %{
        code: code,
        message: opts[:message] || "the provider's own words about #{code}",
        request_id: "req_1",
        retryable: retry != nil,
        retry_after_seconds: retry,
        public_reason: opts[:public_reason] || code
      }
    }

    send_json(conn, status, body, if(retry, do: [{"retry-after", to_string(retry)}], else: []))
  end

  for router <- ~w(image video) do
    post "/v1/#{router}-router/generate" do
      bump(:submits)

      record(:requests, %{
        router: unquote(router),
        body: conn.body_params,
        key: get_req_header(conn, "idempotency-key"),
        auth: get_req_header(conn, "authorization")
      })

      case val(:submit, :ok) do
        :ok ->
          accepted(conn)

        {:refuse_once, status, code, retry} ->
          set(:submit, :ok)
          error(conn, status, code, retry_after: retry)

        {:refuse, status, code, retry} ->
          error(conn, status, code, retry_after: retry)
      end
    end
  end

  defp accepted(conn) do
    id = "job_#{System.unique_integer([:positive])}"
    send_json(conn, 202, %{data: %{request_id: id, job: %{id: id, status: "queued"}, cancelable: true, terminal: false, next_poll_after_seconds: 0}})
  end

  get "/v1/jobs/:id/status" do
    bump(:polls)

    case val(:status_error) do
      {status, code, retry} ->
        set(:status_error, nil)
        error(conn, status, code, retry_after: retry)

      nil ->
        state = val(:state, "processing")

        data = %{
          job_id: id,
          sume_status: state,
          terminal: state in ~w(completed failed canceled),
          cancelable: state == "queued",
          next_poll_after_seconds: val(:poll_after, 0)
        }

        send_json(conn, 200, %{data: data})
    end
  end

  get "/v1/jobs/:id/result" do
    bump(:results)

    case val(:state, "processing") do
      "completed" ->
        send_json(conn, 200, %{
          data: %{job_id: id, status: "COMPLETED", result: %{artifacts: val(:artifacts) || [artifact(conn, "image.png", "image/png", nil)]}}
        })

      "failed" ->
        error(conn, 409, "job_failed", public_reason: val(:public_reason, "content_policy_rejected"), message: "the prompt said SECRET-WORDS")

      "canceled" ->
        error(conn, 409, "job_canceled")

      _ ->
        error(conn, 409, "job_not_completed", retry_after: 2)
    end
  end

  post "/v1/jobs/:id/cancel" do
    bump(:cancels)

    case val(:state, "processing") do
      "queued" ->
        set(:state, "canceled")
        send_json(conn, 200, %{data: %{job_id: id, sume_status: "canceled", terminal: true}})

      "processing" ->
        error(conn, 409, "job_generation_already_started")

      _ ->
        error(conn, 409, "job_not_cancelable")
    end
  end

  def artifact(conn_or_base, name, type, duration_ms) do
    base = if is_binary(conn_or_base), do: conn_or_base, else: base(conn_or_base)
    %{id: "artf_#{name}", type: "file", url: "#{base}/artifacts/#{name}", content_type: type, size_bytes: 9, duration_ms: duration_ms}
  end

  get "/artifacts/:name" do
    bump(:downloads)
    conn |> put_resp_header("content-type", "application/octet-stream") |> send_resp(200, "artifact:" <> name)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

defmodule OmnigateControl.SumeTest do
  @moduledoc """
  The Sume adapter, against a stand-in written from Sume's documentation,
  and the request-dependent prices (`price.variants`) that came with it.
  Nothing here has met the real service.
  """
  # Not async: jobs, the ledger and the config are shared named processes.
  use ExUnit.Case, async: false

  alias OmnigateControl.{ConfigStore, Jobs, Ledger}
  alias OmnigateControl.Jobs.Adapters.Sume
  alias OmnigateControl.Jobs.Store
  alias OmnigateControl.SumeTest.Stub

  setup_all do
    {:ok, server} = Bandit.start_link(plug: Stub, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    System.put_env("OMNIGATE_TEST_SUME_KEY", "sume-secret")
    Stub.setup()
    original = ConfigStore.get().media
    on_exit(fn -> ConfigStore.put_media(original) end)
    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  setup %{base: base} do
    wait_idle()
    Stub.setup()
    ConfigStore.put_media(media(base))
    :ok
  end

  # -- helpers ---------------------------------------------------------------

  defp price(rates \\ %{}, variants \\ []) do
    Map.merge(%{per_job_usd: 0.0, per_output_usd: 0.0, per_input_char_usd: 0.0, per_second_usd: 0.0, variants: variants}, rates)
  end

  @video_variants [
    %{when: %{"resolution" => "720p", "generate_audio" => false}, rates: %{per_second_usd: 0.08}},
    %{when: %{"resolution" => "720p", "generate_audio" => true}, rates: %{per_second_usd: 0.10}},
    %{when: %{"resolution" => "720p", "generate_audio" => nil}, rates: %{per_second_usd: 0.10}}
  ]

  defp media(base, opts \\ []) do
    sume = %{name: "sume", kind: "sume", base_url: base, api_key_env: "OMNIGATE_TEST_SUME_KEY"}
    other = %{name: "other", kind: "replicate", base_url: base <> "/nowhere", api_key_env: "OMNIGATE_TEST_SUME_KEY"}

    routes = [
      %{
        model: "s-image",
        cache_ttl_s: nil,
        timeout_s: Keyword.get(opts, :timeout_s, 30),
        targets: [%{upstream: "sume", model: "mock-image", router: "image", price: price(%{per_output_usd: 0.04})}] ++ Keyword.get(opts, :more_targets, [])
      },
      %{
        model: "s-video",
        cache_ttl_s: nil,
        timeout_s: Keyword.get(opts, :timeout_s, 30),
        targets: [%{upstream: "sume", model: "mock-video", router: "video", price: price(%{}, @video_variants)}]
      }
    ]

    %{
      public_base_url: "http://gateway.test",
      poll_interval_ms: 10,
      max_output_bytes: 1_000_000,
      max_input_bytes: 1_048_576,
      max_open_jobs: 100,
      upstreams: [sume, other],
      routes: routes,
      storage: %{kind: "local", dir: Application.fetch_env!(:omnigate_control, :media_dir), url_ttl_s: 600},
      webhooks: %{retry_schedule_ms: [30], max_attempts: 2, timeout_ms: 2_000, allow_private: true, secret: "s"}
    }
  end

  defp wait_idle(tries \\ 500) do
    busy = Enum.filter(Store.all(), &(not Jobs.terminal?(&1) or Jobs.provider_pending?(&1)))

    cond do
      busy == [] ->
        :ok

      tries == 0 ->
        Enum.each(busy, fn job ->
          Jobs.finish(job["id"], "canceled", %{})
          Jobs.settle_canceled(job["id"], %{})
        end)

      true ->
        Process.sleep(10) && wait_idle(tries - 1)
    end
  end

  defp await(id, pred, tries \\ 800) do
    job = Store.get(id)

    cond do
      pred.(job) -> job
      tries == 0 -> flunk("timed out waiting for job #{id}: #{inspect(job)}")
      true -> Process.sleep(10) && await(id, pred, tries - 1)
    end
  end

  defp wait_until(fun, tries \\ 500) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp hash, do: "sumekey-#{System.unique_integer([:positive])}"
  defp settled?(job), do: job["status"] == "canceled" and job["provider_pending"] != true and job["ledgered"] == true
  defp with_provider?(job), do: job["status"] == "running" and is_binary(get_in(job, ["run", "provider_id"]))

  defp create(key, model, input, extra \\ %{}, opts \\ []) do
    {:ok, job} = Jobs.create(key, Map.merge(%{"model" => model, "input" => input}, extra), nil, opts)
    job
  end

  defp raw(target, upstream \\ %{}) do
    %{
      "media" => %{
        "upstreams" => [Map.merge(%{"name" => "u", "kind" => "sume", "api_key_env" => "K"}, upstream)],
        "routes" => [%{"model" => "m", "targets" => [Map.merge(%{"upstream" => "u", "model" => "veo-3.1-fast"}, target)]}]
      }
    }
  end

  defp target(config), do: config |> ConfigStore.normalize() |> then(&hd(hd(&1.media.routes).targets))

  # ============================================================ configuration

  describe "configuration" do
    test "a sume target says which router it is on; the base URL has a default" do
      t = target(raw(%{"router" => "video"}))
      assert t.router == "video"
      assert hd(ConfigStore.normalize(raw(%{"router" => "image"})).media.upstreams).base_url == "https://api.sume.com"

      assert hd(ConfigStore.normalize(raw(%{"router" => "image"}, %{"base_url" => "https://proxy.example/"})).media.upstreams).base_url ==
               "https://proxy.example"

      assert_raise ArgumentError, ~r/sume upstream needs "router": "image" or "video"/, fn -> ConfigStore.normalize(raw(%{})) end
      assert_raise ArgumentError, ~r/sume upstream needs "router"/, fn -> ConfigStore.normalize(raw(%{"router" => "audio"})) end

      # No other kind has a router, or a default address.
      assert_raise ArgumentError, ~r/"router" is a setting of sume targets/, fn ->
        ConfigStore.normalize(raw(%{"router" => "video"}, %{"kind" => "fal", "base_url" => "http://x"}))
      end

      assert_raise KeyError, fn -> ConfigStore.normalize(raw(%{}, %{"kind" => "fal"})) end
    end

    test "price variants are read strictly" do
      variants = fn list -> raw(%{"router" => "video", "price" => %{"variants" => list}}) end

      t =
        target(
          variants.([%{"when" => %{"resolution" => "720p", "generate_audio" => true}, "per_second_usd" => 0.1}, %{"when" => %{}, "per_second_usd" => 0.2}])
        )

      assert [%{when: %{"resolution" => "720p", "generate_audio" => true}, rates: %{per_second_usd: 0.1}}, %{when: %{}, rates: %{per_second_usd: 0.2}}] =
               t.price.variants

      for bad <- [
            "720p",
            [%{"per_second_usd" => 0.1}],
            [%{"when" => %{"resolution" => "720p"}}],
            [%{"when" => %{"resolution" => ["720p"]}, "per_second_usd" => 0.1}],
            [%{"when" => %{"resolution" => "720p"}, "per_minute_usd" => 6}],
            [%{"when" => %{"resolution" => "720p"}, "per_second_usd" => -1}],
            [%{"when" => %{"resolution" => "720p"}, "per_second_usd" => "0.1"}],
            [%{"when" => Map.new(1..9, &{"f#{&1}", 1}), "per_second_usd" => 0.1}],
            [%{"when" => %{"a" => 1}, "per_job_usd" => 1}, %{"when" => %{"a" => 1}, "per_job_usd" => 2}]
          ] do
        assert_raise ArgumentError, fn -> ConfigStore.normalize(variants.(bad)) end
      end
    end

    test "a per-second variant on a kind that is never sent a duration needs default_seconds, like a per-second base price" do
      config =
        raw(%{"price" => %{"variants" => [%{"when" => %{"quality" => "hd"}, "per_second_usd" => 0.1}]}}, %{"kind" => "openai_images", "base_url" => "http://x"})

      assert_raise ArgumentError, ~r/"default_seconds"/, fn -> ConfigStore.normalize(config) end
    end
  end

  # ================================================================== prices

  describe "price variants" do
    test "the first variant whose every field equals the request applies; its rates replace the base ones" do
      t = %{
        price:
          price(%{per_job_usd: 0.01, per_second_usd: 0.5}, [
            %{when: %{"resolution" => "720p", "generate_audio" => false}, rates: %{per_second_usd: 0.08}},
            %{when: %{"resolution" => "720p"}, rates: %{per_second_usd: 0.10}},
            %{when: %{"resolution" => nil}, rates: %{per_second_usd: 0.03, per_job_usd: 0.0}},
            %{when: %{"fps" => 24}, rates: %{per_output_usd: 1.0}}
          ])
      }

      assert {:ok, %{per_second_usd: 0.08, per_job_usd: 0.01}} = Jobs.price_for(t, %{"resolution" => "720p", "generate_audio" => false})
      assert {:ok, %{per_second_usd: 0.10}} = Jobs.price_for(t, %{"resolution" => "720p", "generate_audio" => true})
      assert {:ok, %{per_second_usd: 0.10}} = Jobs.price_for(t, %{"resolution" => "720p"})
      # A field the request does not send equals null.
      assert {:ok, %{per_second_usd: 0.03, per_job_usd: free}} = Jobs.price_for(t, %{"prompt" => "x"})
      assert free == 0
      # JSON values: 24 and 24.0 are one number; "true" is not true.
      assert {:ok, %{per_output_usd: 1.0}} = Jobs.price_for(t, %{"resolution" => "4K", "fps" => 24.0})
      assert :unmatched = Jobs.price_for(t, %{"resolution" => "4K"})
      assert :unmatched = Jobs.price_for(%{price: price(%{}, [%{when: %{"a" => true}, rates: %{per_job_usd: 1.0}}])}, %{"a" => "true"})
      # No variants: the price as it always was (a config built without the field, too).
      assert {:ok, %{per_output_usd: 0.25}} =
               Jobs.price_for(%{price: %{per_job_usd: 0.0, per_output_usd: 0.25, per_input_char_usd: 0.0, per_second_usd: 0.0}}, %{})
    end

    test "the cost of a job follows its variant; one that has none any more is charged at the dearest" do
      route = %{price_multipliers: %{}}
      t = %{price: price(%{}, @video_variants)}
      bill = %{chars: 0, seconds: 5}

      assert_in_delta Jobs.job_cost(route, t, bill, %{"resolution" => "720p", "generate_audio" => false}, 1), 0.40, 1.0e-9
      assert_in_delta Jobs.job_cost(route, t, bill, %{"resolution" => "720p"}, 1), 0.50, 1.0e-9
      assert_in_delta Jobs.job_cost(route, t, bill, %{"resolution" => "8K"}, 1), 0.50, 1.0e-9
      assert Jobs.priced?(t.price) and Jobs.per_second?(t.price)
      refute Jobs.priced?(price()) or Jobs.per_second?(price(%{per_output_usd: 1.0}))
    end

    test "a request with no priced variant is refused when the job is created" do
      assert {:error, 400, "invalid_request", message} =
               Jobs.create(hash(), %{"model" => "s-video", "input" => %{"prompt" => "x", "duration" => 5, "resolution" => "1080p"}})

      assert message =~ "no price for this combination" and message =~ "input.resolution" and message =~ "resolution=\"720p\""
      assert Stub.val(:submits, 0) == 0

      # A per-second variant needs a duration to price, like a per-second price.
      assert {:error, 400, "invalid_request", message} = Jobs.create(hash(), %{"model" => "s-video", "input" => %{"prompt" => "x", "resolution" => "720p"}})
      assert message =~ "priced per second"
    end

    test "a target whose price lost its variant for a job is skipped before anything is sent", %{base: base} do
      Stub.set(:state, "queued")
      key = hash()
      # Accepted under one price list...
      job = create(key, "s-video", %{"prompt" => "x", "duration" => 5, "resolution" => "720p"})
      await(job["id"], &with_provider?/1)
      before = Stub.val(:submits, 0)
      # ... and still being tried after the operator dropped 720p.
      media = media(base)
      [image, video] = media.routes
      only_1080 = [%{when: %{"resolution" => "1080p"}, rates: %{per_second_usd: 0.3}}]
      video = %{video | targets: [%{hd(video.targets) | price: price(%{}, only_1080)}, %{hd(video.targets) | price: price(%{}, only_1080)}]}
      ConfigStore.put_media(%{media | routes: [image, video]})
      Stub.set(:state, "failed")

      done = await(job["id"], &Jobs.terminal?/1)
      assert done["status"] == "failed"
      assert Enum.at(done["attempts"], 1)["outcome"] =~ "unpriced_variant"
      assert Stub.val(:submits, 0) == before
    end
  end

  # ================================================================= adapter

  describe "the request" do
    test "the input is the body, with the model filled in, always async, without the caller's webhook or metadata" do
      body =
        Sume.request_body(
          %{"prompt" => "p", "model" => "theirs", "mode" => "sync", "webhook_url" => "https://x", "metadata" => %{"a" => 1}, "wait_timeout_seconds" => 30},
          "veo"
        )

      assert body == %{"prompt" => "p", "model" => "veo", "mode" => "async"}
    end

    test "the idempotency key is stable for a job and attempt, and differs between them" do
      a = Sume.idempotency_key(%{job_id: "job_1", attempt: 0})
      assert a == Sume.idempotency_key(%{job_id: "job_1", attempt: 0})
      assert a != Sume.idempotency_key(%{job_id: "job_1", attempt: 1}) and a != Sume.idempotency_key(%{job_id: "job_2", attempt: 0})
      assert a =~ ~r/\Aog-[0-9a-f]{48}\z/ and not String.contains?(a, "job_1")
    end

    test "what the provider measured replaces the requested seconds" do
      assert Sume.measured([%{"duration_ms" => 3000}, %{"duration_ms" => 1500}, %{"duration_ms" => nil}]) == %{seconds: 4.5}
      assert Sume.measured([%{"duration_ms" => nil}, %{}]) == %{}
      assert Sume.measured([%{"duration_ms" => "5000"}, %{"duration_ms" => -1}]) == %{}
      assert Sume.billable(%{"prompt" => "abc", "duration" => "6s", "seconds" => 99}) == %{chars: 3, seconds: 6.0}
    end
  end

  describe "an image job" do
    test "goes to the image router, is polled, read and stored; billed per image" do
      Stub.set(:state, "completed")
      key = hash()
      job = create(key, "s-image", %{"prompt" => "a cup", "num_images" => 2, "webhook_url" => "https://ignored.example", "metadata" => %{"x" => 1}})
      Stub.set(:artifacts, nil)

      done = await(job["id"], &Jobs.terminal?/1)
      assert done["status"] == "succeeded" and done["upstream"] == "sume" and done["target_model"] == "mock-image"
      assert [%{"content_type" => "image/png", "bytes" => 18}] = done["outputs"]
      assert_in_delta done["cost_usd"], 0.04, 1.0e-9

      assert [%{router: "image", body: body, key: [idem], auth: ["Bearer sume-secret"]}] = Stub.val(:requests)
      assert body == %{"prompt" => "a cup", "num_images" => 2, "model" => "mock-image", "mode" => "async"}
      assert idem == Sume.idempotency_key(%{job_id: job["id"], attempt: 0})
      assert Stub.val(:results) == 1 and Stub.val(:downloads) == 1
    end

    test "several artifacts are several outputs, each billed", %{base: base} do
      Stub.set(:state, "completed")
      Stub.set(:artifacts, for(i <- 1..3, do: Stub.artifact(base, "image-#{i}.png", "image/png", nil)))
      done = create(hash(), "s-image", %{"prompt" => "x", "num_images" => 3}) |> Map.get("id") |> await(&Jobs.terminal?/1)
      assert length(done["outputs"]) == 3
      assert_in_delta done["cost_usd"], 0.12, 1.0e-9
    end
  end

  describe "a video job" do
    test "goes to the video router and is billed for the seconds the provider reports, at the request's variant", %{base: base} do
      Stub.set(:state, "completed")
      # Asked for 8 seconds; the provider made 5.
      Stub.set(:artifacts, [Stub.artifact(base, "video.mp4", "video/mp4", 5000)])
      key = hash()

      done =
        create(key, "s-video", %{"prompt" => "x", "duration" => 8, "resolution" => "720p", "generate_audio" => false})
        |> Map.get("id")
        |> await(&Jobs.terminal?/1)

      assert done["status"] == "succeeded"
      assert [%{"content_type" => "video/mp4"}] = done["outputs"]
      assert_in_delta done["cost_usd"], 5 * 0.08, 1.0e-9
      assert wait_until(fn -> Store.get(done["id"])["ledgered"] == true end)
      assert_in_delta Ledger.totals(key).cost_usd, 0.40, 1.0e-9
      assert [%{router: "video"}] = Stub.val(:requests)
    end

    test "without a reported duration, the requested one is billed; audio changes the rate", %{base: base} do
      Stub.set(:state, "completed")
      Stub.set(:artifacts, [Stub.artifact(base, "video.mp4", "video/mp4", nil)])

      done =
        create(hash(), "s-video", %{"prompt" => "x", "duration" => 8, "resolution" => "720p", "generate_audio" => true})
        |> Map.get("id")
        |> await(&Jobs.terminal?/1)

      assert_in_delta done["cost_usd"], 8 * 0.10, 1.0e-9
    end
  end

  describe "refused submits" do
    test "a retryable refusal with a short wait is sent once more, with the same key" do
      Stub.set(:submit, {:refuse_once, 503, "provider_capacity_exceeded", 0})
      Stub.set(:state, "completed")
      done = create(hash(), "s-image", %{"prompt" => "x"}) |> Map.get("id") |> await(&Jobs.terminal?/1)
      assert done["status"] == "succeeded"
      assert [%{key: [key]}, %{key: [key]}] = Stub.val(:requests)
    end

    test "a refusal that asks for a long wait, or is final, moves the job to the next target", %{base: base} do
      next = %{upstream: "other", model: "o/m", price: price(%{per_output_usd: 1.0})}
      ConfigStore.put_media(media(base, more_targets: [next]))

      for {refusal, outcome} <- [
            {{:refuse, 429, "rate_limited", 30}, "sume_rate_limited"},
            {{:refuse, 402, "insufficient_funds", nil}, "sume_insufficient_funds"},
            {{:refuse, 401, "unauthorized", nil}, "sume_unauthorized"}
          ] do
        Stub.setup()
        Stub.set(:submit, refusal)
        done = create(hash(), "s-image", %{"prompt" => "x"}) |> Map.get("id") |> await(&Jobs.terminal?/1)
        assert Stub.val(:submits) == 1
        assert [%{"upstream" => "sume", "outcome" => first}, %{"upstream" => "other"} | _] = done["attempts"]
        assert first =~ outcome
        assert done["cost_usd"] in [nil, 0, 0.0]
      end
    end
  end

  describe "a job that fails at the provider" do
    test "is reported with Sume's reason; a private job keeps the reason and not the provider's words" do
      Stub.set(:state, "failed")
      done = create(hash(), "s-image", %{"prompt" => "x"}) |> Map.get("id") |> await(&Jobs.terminal?/1)
      assert done["status"] == "failed"
      assert [%{"outcome" => "sume_content_policy_rejected: the prompt said SECRET-WORDS"}] = done["attempts"]

      done = create(hash(), "s-image", %{"prompt" => "x"}, %{}, privacy: %{no_store: true, encrypt_to: nil}) |> Map.get("id") |> await(&Jobs.terminal?/1)
      assert [%{"outcome" => "sume_content_policy_rejected"}] = done["attempts"]
      refute inspect(done) =~ "SECRET-WORDS"
    end
  end

  describe "polling" do
    test "a 429 on a poll is a request to wait, not a failed poll" do
      Stub.set(:status_error, {429, "rate_limited", 1})
      Stub.set(:state, "completed")
      started = System.monotonic_time(:millisecond)
      done = create(hash(), "s-image", %{"prompt" => "x"}) |> Map.get("id") |> await(&Jobs.terminal?/1)
      assert done["status"] == "succeeded"
      # Waited the second it was asked to, asking nothing in between.
      assert System.monotonic_time(:millisecond) - started >= 800
      assert Stub.val(:polls) == 2
    end

    test "the wait Sume asks for between polls is kept" do
      Stub.set(:poll_after, 1)
      job = create(hash(), "s-image", %{"prompt" => "x"})
      await(job["id"], &with_provider?/1)
      Process.sleep(600)
      # At 10 ms between the runner's polls, 60 would have gone out.
      assert Stub.val(:polls) <= 2
      Stub.set(:state, "completed")
      assert await(job["id"], &Jobs.terminal?/1)["status"] == "succeeded"
    end

    test "repeated 5xx answers give the job up to the next target" do
      Stub.set(:state, "processing")
      job = create(hash(), "s-image", %{"prompt" => "x"})
      await(job["id"], &with_provider?/1)
      :ets.insert(:omnigate_sume_stub, {:status_error, {500, "internal_error", nil}})
      # (The stub clears the error after one answer; keep it failing.)
      spawn_link(fn -> for _ <- 1..200, do: Process.sleep(5) && :ets.insert(:omnigate_sume_stub, {:status_error, {500, "internal_error", nil}}) end)
      done = await(job["id"], &Jobs.terminal?/1)
      assert done["status"] == "failed"
      assert [%{"outcome" => "sume_internal_error" <> _}] = done["attempts"]
    end
  end

  describe "cancel" do
    test "while Sume can still stop the job: it is stopped, and nothing is owed" do
      Stub.set(:state, "queued")
      key = hash()
      job = create(key, "s-image", %{"prompt" => "x"})
      await(job["id"], &with_provider?/1)

      Jobs.cancel(key, job["id"])
      done = await(job["id"], &settled?/1)
      assert done["cost_usd"] in [nil, 0, 0.0]
      assert Stub.val(:cancels) >= 1 and Stub.val(:state) == "canceled"
      assert Ledger.totals(key).cost_usd == 0.0
    end

    test "after generation started: Sume is not asked to cancel, the job is polled on and billed when it completes" do
      Stub.set(:state, "processing")
      key = hash()
      job = create(key, "s-image", %{"prompt" => "x"})
      await(job["id"], &with_provider?/1)

      canceled = Jobs.cancel(key, job["id"])
      assert canceled["status"] == "canceled" and canceled["provider_pending"] == true
      polls = Stub.val(:polls, 0)
      assert wait_until(fn -> Stub.val(:polls, 0) > polls + 3 end)
      assert Store.get(job["id"])["provider_pending"] == true
      # "cancelable" was false every time it was asked: no cancel call went out.
      assert Stub.val(:cancels, 0) == 0

      Stub.set(:state, "completed")
      done = await(job["id"], &settled?/1)
      assert_in_delta done["cost_usd"], 0.04, 1.0e-9
      assert_in_delta Ledger.totals(key).cost_usd, 0.04, 1.0e-9
      assert Stub.val(:downloads, 0) == 0
      assert List.last(done["attempts"])["outcome"] == "completed_after_cancel"
    end

    test "a job that had completed at Sume when the cancel came is billed, even inside a poll wait Sume asked for" do
      Stub.set(:state, "processing")
      Stub.set(:poll_after, 30)
      key = hash()
      job = create(key, "s-image", %{"prompt" => "x"})
      await(job["id"], &with_provider?/1)
      assert wait_until(fn -> Stub.val(:polls, 0) >= 1 end)
      # Finished at the provider while the gateway waits its 30 seconds.
      Stub.set(:state, "completed")
      Jobs.cancel(key, job["id"])
      done = await(job["id"], &settled?/1)
      assert_in_delta done["cost_usd"], 0.04, 1.0e-9
      assert Stub.val(:downloads, 0) == 0
    end

    test "... and owes nothing when the job then fails at the provider" do
      Stub.set(:state, "processing")
      key = hash()
      job = create(key, "s-image", %{"prompt" => "x"})
      await(job["id"], &with_provider?/1)
      Jobs.cancel(key, job["id"])
      Stub.set(:state, "failed")
      done = await(job["id"], &settled?/1)
      assert done["cost_usd"] in [nil, 0, 0.0]
    end
  end
end
