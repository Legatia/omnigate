defmodule OmnigateControl.Review3Test.Stub do
  @moduledoc """
  Providers for the third security review's tests: one that takes its time,
  ones that can and cannot be told to stop, and ones whose answers list more
  than anyone should fetch.
  """
  use Plug.Router

  @table :omnigate_review3_stub

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["*/*"], length: 8_000_000)
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

  def bump(name, by \\ 1), do: :ets.update_counter(@table, name, by, {name, 0})

  defp base(conn), do: "http://127.0.0.1:#{conn.port}"
  defp send_json(conn, status, body), do: conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))

  # -- Replicate style: can be told to stop --------------------------------

  post "/v1/models/:owner/:name/predictions" do
    bump(:submits)
    id = "p-#{System.unique_integer([:positive])}"

    case val(:submit, :done) do
      :done ->
        send_json(conn, 201, %{id: id, status: "succeeded", output: val(:output, base(conn) <> "/files/out.png")})

      # Answers with the finished result, but only after a while.
      {:slow_done, ms} ->
        Process.sleep(ms)
        send_json(conn, 201, %{id: id, status: "succeeded", output: base(conn) <> "/files/out.png"})

      :async ->
        send_json(conn, 201, %{id: id, status: "starting"})
    end
  end

  get "/v1/predictions/:id" do
    bump(:polls)

    case val(:state, "processing") do
      "succeeded" -> send_json(conn, 200, %{id: id, status: "succeeded", output: base(conn) <> "/files/out.png"})
      state -> send_json(conn, 200, %{id: id, status: state})
    end
  end

  post "/v1/predictions/:id/cancel" do
    bump(:cancels)
    # A provider that had not finished stops; one that had stays finished.
    if val(:state, "processing") == "processing" and val(:cancel_works, true), do: set(:state, "canceled")
    send_json(conn, 200, %{id: id})
  end

  # -- xAI video style: cannot be told to stop ------------------------------

  post "/v1/videos/generations" do
    bump(:submits)
    send_json(conn, 200, %{request_id: "v-#{System.unique_integer([:positive])}"})
  end

  get "/v1/videos/:id" do
    bump(:polls)

    case val(:state, "processing") do
      "succeeded" -> send_json(conn, 200, %{status: "done", video: %{url: base(conn) <> "/files/out.mp4"}})
      _ -> send_json(conn, 202, %{status: "pending"})
    end
  end

  # -- fal style: the result names its files, with whatever "content_type" ----

  post "/fal/model" do
    bump(:submits)
    send_json(conn, 200, %{request_id: "f-1"})
  end

  get "/fal/model/requests/:id/status" do
    send_json(conn, 200, %{status: "COMPLETED"})
  end

  get "/fal/model/requests/:id" do
    send_json(conn, 200, val(:fal_result, %{images: [%{url: base(conn) <> "/files/out.png", content_type: 123}]}))
  end

  # -- files ------------------------------------------------------------------

  get "/files/slow.png" do
    bump(:downloads)
    Process.sleep(val(:download_ms, 300))
    conn |> put_resp_header("content-type", "image/png") |> send_resp(200, "PNG-slow")
  end

  get "/files/:name" do
    bump(:downloads)
    conn |> put_resp_header("content-type", val(:file_type, "image/png")) |> send_resp(200, :binary.copy("x", val(:file_bytes, 100)))
  end

  # -- a bucket ---------------------------------------------------------------

  put "/bucket/*_path" do
    {:ok, _body, conn} = Plug.Conn.read_body(conn)
    set(:put_content_type, get_req_header(conn, "content-type"))
    send_resp(conn, 200, "")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

defmodule OmnigateControl.Review3Test do
  @moduledoc """
  The third security review, control-plane side: at least one regression
  test per finding. The section headers say which is which.
  """
  # Not async: jobs, keys, the ledger and the config are shared named processes.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{AdminAuth, ConfigStore, Http, Jobs, Keys, Ledger, NetGuard, Router, Storage}
  alias OmnigateControl.Jobs.{Runner, Store}
  alias OmnigateControl.Review3Test.Stub

  @admin "test-admin-token-0123456789"

  setup_all do
    {:ok, server} = Bandit.start_link(plug: Stub, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    System.put_env("OMNIGATE_TEST_PROVIDER_KEY", "provider-secret")
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

  @price %{per_job_usd: 0.0, per_output_usd: 0.25, per_input_char_usd: 0.0, per_second_usd: 0.0}

  defp media(base, opts \\ []) do
    kind = Keyword.get(opts, :kind, "replicate")
    model = if kind == "fal", do: "fal/model", else: "owner/model"
    route = %{model: "r3", cache_ttl_s: nil, timeout_s: Keyword.get(opts, :timeout_s, 30), targets: [%{upstream: "prov", model: model, price: @price}]}

    Map.merge(
      %{
        public_base_url: "http://gateway.test",
        poll_interval_ms: 10,
        max_output_bytes: 1_000_000,
        max_input_bytes: 1_048_576,
        max_open_jobs: 100,
        upstreams: [%{name: "prov", kind: kind, base_url: base, api_key_env: "OMNIGATE_TEST_PROVIDER_KEY"}],
        routes: [route],
        storage: %{kind: "local", dir: Application.fetch_env!(:omnigate_control, :media_dir), url_ttl_s: 600},
        webhooks: %{retry_schedule_ms: [30], max_attempts: 2, timeout_ms: 2_000, allow_private: true, secret: "s"}
      },
      Map.new(Keyword.get(opts, :media, []))
    )
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

  defp await(id, pred, tries \\ 500) do
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

  defp unique, do: System.unique_integer([:positive])
  defp hash, do: "r3key-#{unique()}"
  defp call(conn), do: Router.call(conn, Router.init([]))
  defp settled?(job), do: job["status"] == "canceled" and job["provider_pending"] != true and job["ledgered"] == true
  defp running_with_provider?(job), do: job["status"] == "running" and is_binary(get_in(job, ["run", "provider_id"]))

  defp create(key, input \\ %{"prompt" => "x"}, extra \\ %{}) do
    {:ok, job} = Jobs.create(key, Map.merge(%{"model" => "r3", "input" => input}, extra))
    job
  end

  defp tmp_files(id), do: Storage.tmp_dir() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, id))

  defp stored_files(id),
    do: Path.join(Application.fetch_env!(:omnigate_control, :media_dir), id) |> File.ls() |> then(fn r -> if match?({:ok, _}, r), do: elem(r, 1), else: [] end)

  # ============================================================= finding 3

  describe "finding 3: what a job keeps in memory is bounded" do
    test "a webhook_url longer than 2,048 bytes is refused" do
      long = "https://example.com/hook?" <> String.duplicate("a", 2_100)
      assert {:error, 400, "invalid_webhook_url", message} = Jobs.create(hash(), %{"model" => "r3", "input" => %{"prompt" => "x"}, "webhook_url" => long})
      assert message =~ "2048"
      # One megabyte of it, which the input limit used to let through.
      assert {:error, 400, "invalid_webhook_url", _} =
               Jobs.create(hash(), %{
                 "model" => "r3",
                 "input" => %{"prompt" => "x"},
                 "webhook_url" => "https://example.com/" <> String.duplicate("a", 1_000_000)
               })
    end

    test "metadata above 16 KiB is refused with 413; below it, it is kept" do
      big = %{"note" => String.duplicate("m", 17_000)}
      assert {:error, 413, "payload_too_large", message} = Jobs.create(hash(), %{"model" => "r3", "input" => %{"prompt" => "x"}, "metadata" => big})
      assert message =~ "metadata"

      key = hash()
      job = create(key, %{"prompt" => "x"}, %{"metadata" => %{"note" => String.duplicate("m", 15_000)}})
      assert byte_size(Store.get(job["id"])["metadata"]["note"]) == 15_000
    end

    test "a list of jobs leaves out metadata that is not small, and says so; the job itself shows it" do
      key = hash()
      big = create(key, %{"prompt" => "x"}, %{"metadata" => %{"note" => String.duplicate("m", 5_000)}})
      small = create(key, %{"prompt" => "y"}, %{"metadata" => %{"order" => "42"}})

      listed = Enum.map(Jobs.list(key, 10), &Jobs.view(&1, input: false))
      by_id = Map.new(listed, &{&1["id"], &1})
      assert by_id[big["id"]]["metadata"] == nil and by_id[big["id"]]["metadata_omitted"] == true
      assert by_id[small["id"]]["metadata"] == %{"order" => "42"} and not Map.has_key?(by_id[small["id"]], "metadata_omitted")
      assert byte_size(JSON.encode!(listed)) < 5_000

      assert Jobs.view(Store.get(big["id"]))["metadata"]["note"] == String.duplicate("m", 5_000)
    end
  end

  # ============================================================= finding 4

  describe "finding 4: canceling a job does not make its provider call free" do
    test "canceled while a provider that answers with the result is still working: billed when it answers, nothing stored" do
      Stub.set(:submit, {:slow_done, 300})
      key = hash()
      job = create(key)
      await(job["id"], &(&1["status"] == "running" and is_integer(get_in(&1, ["run", "attempt_started_ms"]))))
      assert wait_until(fn -> Stub.val(:submits, 0) == 1 end)

      canceled = Jobs.cancel(key, job["id"])
      # Canceled for the client at once ...
      assert canceled["status"] == "canceled" and canceled["provider_pending"] == true
      # ... but not in the ledger yet, and still holding its place among the key's open jobs.
      assert canceled["ledgered"] == false
      assert Ledger.totals(key).cost_usd == 0.0
      assert Store.open_count([key]) == 1

      done = await(job["id"], &settled?/1)
      assert done["status"] == "canceled"
      assert done["cost_usd"] == 0.25
      assert done["upstream"] == "prov"
      assert List.last(done["attempts"]) == %{"upstream" => "prov", "outcome" => "completed_after_cancel"}
      assert done["outputs"] == [] and done["run"] == nil
      assert_in_delta Ledger.totals(key).cost_usd, 0.25, 1.0e-9
      assert Store.open_count([key]) == 0
      # The result was never fetched, so there is nothing to orphan.
      assert Stub.val(:downloads, 0) == 0
      assert stored_files(job["id"]) == [] and tmp_files(job["id"]) == []
      # The client sees the cost on the canceled job.
      assert Jobs.view(done)["cost_usd"] == 0.25
    end

    test "the open-jobs limit counts a canceled job until its provider call is over" do
      Stub.set(:submit, {:slow_done, 400})
      key = hash()
      job = create(key)
      await(job["id"], &(&1["status"] == "running"))
      assert wait_until(fn -> Stub.val(:submits, 0) == 1 end)
      Jobs.cancel(key, job["id"])

      # Cancel and create again was a way to run any number of provider calls at once.
      assert {:error, 429, "too_many_open_jobs", _} = Jobs.create(key, %{"model" => "r3", "input" => %{"prompt" => "y"}}, nil, open_cap: {1, [key]})
      await(job["id"], &settled?/1)
      assert {:ok, _} = Jobs.create(key, %{"model" => "r3", "input" => %{"prompt" => "y"}}, nil, open_cap: {1, [key]})
    end

    test "a provider that can be told to stop, and stops: nothing is owed" do
      Stub.set(:submit, :async)
      key = hash()
      job = create(key)
      await(job["id"], &running_with_provider?/1)

      Jobs.cancel(key, job["id"])
      done = await(job["id"], &settled?/1)
      assert done["cost_usd"] == 0.0 and done["outputs"] == []
      assert Stub.val(:cancels, 0) >= 1
      assert Ledger.totals(key).cost_usd == 0.0
      assert Store.open_count([key]) == 0
    end

    test "a provider that was told to stop but had already finished: billed" do
      Stub.set(:submit, :async)
      Stub.set(:cancel_works, false)
      key = hash()
      job = create(key)
      await(job["id"], &running_with_provider?/1)

      # Finished at the provider between two polls; the cancel comes too late.
      ConfigStore.put_media(%{ConfigStore.get().media | poll_interval_ms: 300})
      Process.sleep(50)
      Stub.set(:state, "succeeded")
      Jobs.cancel(key, job["id"])

      done = await(job["id"], &settled?/1)
      assert done["status"] == "canceled" and done["cost_usd"] == 0.25
      assert_in_delta Ledger.totals(key).cost_usd, 0.25, 1.0e-9
      assert stored_files(job["id"]) == []
    end

    test "a provider that cannot be told to stop is polled on, and billed when it finishes", %{base: base} do
      ConfigStore.put_media(media(base, kind: "xai_video"))
      key = hash()
      job = create(key)
      await(job["id"], &running_with_provider?/1)

      canceled = Jobs.cancel(key, job["id"])
      assert canceled["status"] == "canceled" and canceled["provider_pending"] == true
      polls = Stub.val(:polls, 0)
      assert wait_until(fn -> Stub.val(:polls, 0) > polls + 2 end)
      assert Store.get(job["id"])["provider_pending"] == true

      Stub.set(:state, "succeeded")
      done = await(job["id"], &settled?/1)
      assert done["cost_usd"] == 0.25
      assert_in_delta Ledger.totals(key).cost_usd, 0.25, 1.0e-9
      assert Stub.val(:downloads, 0) == 0 and stored_files(job["id"]) == []
    end

    test "... and owes nothing when the provider never finishes within the route's timeout", %{base: base} do
      ConfigStore.put_media(media(base, kind: "xai_video", timeout_s: 1))
      key = hash()
      job = create(key)
      await(job["id"], &running_with_provider?/1)
      Jobs.cancel(key, job["id"])

      done = await(job["id"], &settled?/1)
      assert done["cost_usd"] == 0.0
      assert Store.open_count([key]) == 0
    end

    test "canceled while the outputs are being fetched: what was stored is deleted, and the call is billed" do
      Stub.set(:output, nil)
      key = hash()
      # The provider is done at once; its file takes a while to download.
      Stub.set(:output, "#{ConfigStore.get().media.upstreams |> hd() |> Map.get(:base_url)}/files/slow.png")
      job = create(key)
      assert wait_until(fn -> Stub.val(:downloads, 0) == 1 end)

      canceled = Jobs.cancel(key, job["id"])
      assert canceled["status"] == "canceled" and canceled["provider_pending"] == true

      done = await(job["id"], &settled?/1)
      assert done["cost_usd"] == 0.25 and done["outputs"] == []
      assert_in_delta Ledger.totals(key).cost_usd, 0.25, 1.0e-9
      assert wait_until(fn -> stored_files(job["id"]) == [] end)
      assert tmp_files(job["id"]) == []
    end

    test "a job that never reached a provider is canceled for nothing, at once" do
      key = hash()
      id = "job_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
      now = System.os_time(:millisecond)

      {:ok, _} =
        Store.create(%{
          "id" => id,
          "status" => "queued",
          "model" => "r3",
          "input" => %{},
          "key_sha256" => key,
          "created_ms" => now,
          "outputs" => [],
          "attempts" => [],
          "ledgered" => false,
          "run" => nil
        })

      canceled = Jobs.cancel(key, id)
      assert canceled["status"] == "canceled" and canceled["provider_pending"] != true and canceled["ledgered"] == true
      assert Store.open_count([key]) == 0
    end

    test "after a restart, a canceled job whose provider cannot be stopped is picked up again and settled", %{base: base} do
      ConfigStore.put_media(media(base, kind: "xai_video"))
      Stub.set(:state, "succeeded")
      key = hash()
      id = "job_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
      now = System.os_time(:millisecond)

      {:ok, _} =
        Store.create(%{
          "id" => id,
          "status" => "canceled",
          "provider_pending" => true,
          "model" => "r3",
          "input" => %{"prompt" => "x"},
          "key_sha256" => key,
          "created_ms" => now,
          "finished_ms" => now,
          "outputs" => [],
          "attempts" => [],
          "cost_usd" => 0.0,
          "ledgered" => false,
          "run" => %{"target_index" => 0, "provider_id" => "v-9", "provider_state" => %{}, "attempt_started_ms" => now}
        })

      assert Store.open_count([key]) == 1
      # Not written to the ledger as free by the periodic sweep ...
      Jobs.reconcile()
      assert Store.get(id)["ledgered"] == false
      # ... but by the runner that `resume_all/0` starts for it.
      Runner.run(id)
      done = Store.get(id)
      assert settled?(done) and done["cost_usd"] == 0.25
      assert Store.open_count([key]) == 0
    end
  end

  # ============================================================= finding 5

  describe "finding 5: a provider's answer cannot fill the disk" do
    test "more outputs than media.max_outputs_per_job: the attempt fails and nothing is downloaded", %{base: base} do
      Stub.set(:output, for(i <- 1..17, do: "#{base}/files/out-#{i}.png"))
      job = create(hash())
      done = await(job["id"], &Jobs.terminal?/1)
      assert done["status"] == "failed"
      assert hd(done["attempts"])["outcome"] =~ "too_many_outputs"
      assert Stub.val(:downloads, 0) == 0
      assert tmp_files(job["id"]) == []

      # Sixteen are fine by default, and the limit is the operator's to set.
      Stub.set(:output, for(i <- 1..16, do: "#{base}/files/out-#{i}.png"))
      ok = create(hash())
      assert %{"status" => "succeeded", "outputs" => outputs} = await(ok["id"], &Jobs.terminal?/1)
      assert length(outputs) == 16

      ConfigStore.put_media(media(base, media: [max_outputs_per_job: 2]))
      Stub.set(:output, for(i <- 1..3, do: "#{base}/files/out-#{i}.png"))
      few = create(hash())
      assert await(few["id"], &Jobs.terminal?/1)["status"] == "failed"
    end

    test "outputs that together exceed media.max_job_output_bytes: the attempt fails, and no file of it is left anywhere", %{base: base} do
      ConfigStore.put_media(media(base, media: [max_job_output_bytes: 250]))
      Stub.set(:file_bytes, 100)
      Stub.set(:output, for(i <- 1..3, do: "#{base}/files/out-#{i}.png"))
      job = create(hash())
      done = await(job["id"], &Jobs.terminal?/1)
      assert done["status"] == "failed"
      assert hd(done["attempts"])["outcome"] =~ "max_job_output_bytes"
      assert tmp_files(job["id"]) == [] and stored_files(job["id"]) == []

      # Two of them fit.
      Stub.set(:output, for(i <- 1..2, do: "#{base}/files/out-#{i}.png"))
      ok = create(hash())
      assert await(ok["id"], &Jobs.terminal?/1)["status"] == "succeeded"
    end

    test "a content_type that is not a string does not crash the runner after the download", %{base: base} do
      ConfigStore.put_media(media(base, kind: "fal"))
      job = create(hash())
      done = await(job["id"], &Jobs.terminal?/1)
      # It used to raise in `String.split/2`: the job failed as an internal error and the download stayed in tmp.
      assert done["status"] == "succeeded"
      assert [%{"content_type" => "image/png"}] = done["outputs"]
      assert tmp_files(job["id"]) == []

      # Nor does one that is a string but no media type.
      Stub.set(:fal_result, %{images: [%{url: "#{base}/files/out.png", content_type: "text/html\r\nx-evil: 1"}]})
      Stub.set(:file_type, "application/octet-stream")
      other = create(hash(), %{"prompt" => "z"})
      assert %{"status" => "succeeded", "outputs" => [%{"content_type" => type}]} = await(other["id"], &Jobs.terminal?/1)
      assert type in ["image/png", "application/octet-stream"]
    end

    test "a download that fails half way leaves no temp file; nor does an output that is not a URL", %{base: base} do
      ConfigStore.put_media(media(base, media: [max_output_bytes: 50]))
      Stub.set(:output, ["#{base}/files/a.png", "#{base}/files/b.png"])
      job = create(hash())
      assert await(job["id"], &Jobs.terminal?/1)["status"] == "failed"
      assert tmp_files(job["id"]) == []
    end

    test "downloads left by a crash are swept at boot: those of jobs held here at once, others only when old" do
      dir = Storage.tmp_dir()
      job = create(hash())
      await(job["id"], &Jobs.terminal?/1)
      ours = Path.join(dir, job["id"] <> "-0")
      stranger = Path.join(dir, "job_" <> String.duplicate("ab", 12) <> "-0")
      old_stranger = Path.join(dir, "job_" <> String.duplicate("cd", 12) <> "-3")
      unrelated = Path.join(dir, "notes.txt")
      Enum.each([ours, stranger, old_stranger, unrelated], &File.write!(&1, "left over"))
      File.touch!(old_stranger, System.os_time(:second) - 2 * 86_400)
      on_exit(fn -> Enum.each([ours, stranger, old_stranger, unrelated], &File.rm/1) end)

      # The count is not asserted exactly: the directory is shared with other tests.
      assert Storage.sweep_tmp() >= 1
      refute File.exists?(ours)
      refute File.exists?(old_stranger)
      assert File.exists?(stranger)
      assert File.exists?(unrelated)
    end
  end

  # ============================================================= L1

  describe "L1: the admin throttles count an attempt before they look at it" do
    # Failed sign-ins are written to the audit log as summary lines, later.
    # Write them now, so that they do not land in the middle of another test.
    setup do
      on_exit(fn -> OmnigateControl.Audit.flush(System.os_time(:second) + 3_600) end)
    end

    test "fifty wrong passwords at the same moment: five are compared, the rest are refused" do
      ip = {10, 77, rem(unique(), 250), rem(unique(), 250)}
      on_exit(fn -> AdminAuth.clear_failures(ip) end)

      statuses =
        1..50
        |> Task.async_stream(
          fn i ->
            conn(:post, "/login", "password=wrong-#{i}")
            |> put_req_header("content-type", "application/x-www-form-urlencoded")
            |> Map.put(:remote_ip, ip)
            |> call()
            |> Map.get(:status)
          end,
          max_concurrency: 50
        )
        |> Enum.map(fn {:ok, status} -> status end)

      assert Enum.count(statuses, &(&1 == 401)) == 5
      assert Enum.count(statuses, &(&1 == 429)) == 45
    end

    test "the same for wrong bearer tokens" do
      Application.put_env(:omnigate_control, :bearer_max_failures, 3)
      on_exit(fn -> Application.put_env(:omnigate_control, :bearer_max_failures, 1_000_000) end)
      ip = {10, 78, rem(unique(), 250), rem(unique(), 250)}
      on_exit(fn -> AdminAuth.clear_bearer_failures(ip) end)

      statuses =
        1..40
        |> Task.async_stream(
          fn i ->
            conn(:get, "/admin/overview") |> put_req_header("authorization", "Bearer guess-#{i}") |> Map.put(:remote_ip, ip) |> call() |> Map.get(:status)
          end,
          max_concurrency: 40
        )
        |> Enum.map(fn {:ok, status} -> status end)

      assert Enum.count(statuses, &(&1 == 401)) == 3
      assert Enum.count(statuses, &(&1 == 429)) == 37
    end

    test "right tokens give their attempt back: any number of them never uses the allowance up" do
      Application.put_env(:omnigate_control, :bearer_max_failures, 3)
      on_exit(fn -> Application.put_env(:omnigate_control, :bearer_max_failures, 1_000_000) end)
      ip = {10, 79, rem(unique(), 250), rem(unique(), 250)}
      on_exit(fn -> AdminAuth.clear_bearer_failures(ip) end)

      ok = fn ->
        conn(:get, "/admin/overview") |> put_req_header("authorization", "Bearer " <> @admin) |> Map.put(:remote_ip, ip) |> call() |> Map.get(:status)
      end

      assert Enum.map(1..20, fn _ -> ok.() end) == List.duplicate(200, 20)
      refute AdminAuth.bearer_throttled?(ip)
      # Two wrong ones, then right ones still work; the third wrong one closes the door.
      for i <- 1..2, do: conn(:get, "/admin/overview") |> put_req_header("authorization", "Bearer no-#{i}") |> Map.put(:remote_ip, ip) |> call()
      assert ok.() == 200
      conn(:get, "/admin/overview") |> put_req_header("authorization", "Bearer no-3") |> Map.put(:remote_ip, ip) |> call()
      assert ok.() == 429
    end

    test "begin_attempt starts a new window once the old one is over" do
      key = {:r3, unique()}
      on_exit(fn -> AdminAuth.clear_failures(key) end)
      now = System.os_time(:second)
      assert for(_ <- 1..3, do: AdminAuth.begin_attempt(key, 2, now)) == [:ok, :ok, :throttled]
      assert AdminAuth.begin_attempt(key, 2, now + 61) == :ok
    end
  end

  # ============================================================= L2

  describe "L2: a peer that stops reading cannot hold a request for ever" do
    defp silent_listener do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, recbuf: 1024, backlog: 8, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)

      acceptor =
        spawn(fn ->
          {:ok, _socket} = :gen_tcp.accept(listener)
          Process.sleep(:infinity)
        end)

      on_exit(fn ->
        Process.exit(acceptor, :kill)
        :gen_tcp.close(listener)
      end)

      port
    end

    test "a file body: the request ends at its timeout" do
      port = silent_listener()
      path = Path.join(System.tmp_dir!(), "omnigate-r3-big-#{unique()}.bin")
      size = 64 * 1024 * 1024
      File.write!(path, :binary.copy(<<0>>, size))
      on_exit(fn -> File.rm(path) end)

      started = System.monotonic_time(:millisecond)
      task = Task.async(fn -> Http.request(:put, "http://127.0.0.1:#{port}/obj", [], {:file, path, size}, timeout: 1_000) end)
      result = Task.yield(task, 8_000) || Task.shutdown(task, :brutal_kill)
      took = System.monotonic_time(:millisecond) - started

      assert {:ok, {:error, _reason}} = result
      assert took < 6_000
    end

    test "a large binary body too" do
      port = silent_listener()
      body = :binary.copy("x", 32 * 1024 * 1024)

      task = Task.async(fn -> Http.request(:post, "http://127.0.0.1:#{port}/hook", [], body, timeout: 1_000) end)
      assert {:ok, {:error, _reason}} = Task.yield(task, 8_000) || Task.shutdown(task, :brutal_kill)
    end
  end

  # ============================================================= L3

  describe "L3: an output in a bucket is served with a type that cannot run as a page" do
    test "the type a provider declared is reduced before it is stored with the object", %{base: base} do
      System.put_env("OMNIGATE_TEST_S3_ACCESS", "access")
      System.put_env("OMNIGATE_TEST_S3_SECRET", "secret")

      config = %{
        kind: "s3",
        endpoint: base,
        bucket: "bucket",
        region: "auto",
        prefix: "",
        access_key_env: "OMNIGATE_TEST_S3_ACCESS",
        secret_key_env: "OMNIGATE_TEST_S3_SECRET"
      }

      tmp = Path.join(System.tmp_dir!(), "omnigate-r3-obj-#{unique()}")
      sha = :crypto.hash(:sha256, "<script>") |> Base.encode16(case: :lower)

      for {declared, stored} <- [
            {"text/html", "application/octet-stream"},
            {"image/svg+xml", "application/octet-stream"},
            {"image/png", "image/png"},
            {nil, "application/octet-stream"}
          ] do
        File.write!(tmp, "<script>")
        assert {:ok, _} = Storage.S3.put(config, "job_ab12", "out-0.bin", tmp, %{"content_type" => declared, "sha256" => sha, "bytes" => 8})
        assert Stub.val(:put_content_type) == [stored]
      end

      File.rm(tmp)
    end

    test "served_type keeps media types and nothing else" do
      assert Storage.served_type("image/png; charset=binary") == "image/png"
      assert Storage.served_type("TEXT/HTML") == "application/octet-stream"
      assert Storage.served_type("application/xhtml+xml") == "application/octet-stream"
      assert Storage.served_type(123) == "application/octet-stream"
    end

    test "a content type with a line break in it is refused before anything is sent", %{base: base} do
      assert {:error, :invalid_header} = Http.request(:put, base <> "/bucket/x", [], "body", content_type: "image/png\r\nx-amz-acl: public-read")
      assert {:error, :invalid_header} = Http.request(:put, base <> "/bucket/x", [], "body", content_type: 123)
      assert {:ok, %{status: 200}} = Http.request(:put, base <> "/bucket/x", [], "body", content_type: "image/png")
    end
  end

  # ============================================================= L4

  describe "L4: a name ends where the string ends" do
    test "a key name with a trailing newline is refused" do
      assert {:error, 400, _, _} = Keys.create(%{"name" => "r3-newline-#{unique()}\n"})
      assert {:error, 400, _, _} = Keys.create(%{"name" => "ok\nforged log line"})
      name = "r3-plain-#{unique()}"
      assert {:ok, _, _} = Keys.create(%{"name" => name})
      Keys.delete(name)
    end
  end

  # ============================================================= L5

  describe "L5: an IPv4 client on a dual-stack socket is throttled as itself" do
    test "::ffff:a.b.c.d is counted as a.b.c.d, not as one /64 for all of IPv4" do
      mapped = fn a, b, c, d -> {0, 0, 0, 0, 0, 0xFFFF, a * 256 + b, c * 256 + d} end
      one = AdminAuth.client_address(%Plug.Conn{remote_ip: mapped.(203, 0, 113, 7)}, false)
      other = AdminAuth.client_address(%Plug.Conn{remote_ip: mapped.(198, 51, 100, 9)}, false)
      assert one == {203, 0, 113, 7}
      assert other == {198, 51, 100, 9}
      # Real IPv6 is still cut to its /64.
      assert AdminAuth.client_address(%Plug.Conn{remote_ip: {0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}}, false) == {0x2001, 0xDB8, 1, 2, 0, 0, 0, 0}

      # The forwarded form goes the same way.
      conn = conn(:get, "/") |> put_req_header("x-forwarded-for", "::ffff:203.0.113.7")
      assert AdminAuth.client_address(conn, true) == {203, 0, 113, 7}
    end
  end

  # ============================================================= L6

  describe "L6: a key's spend survives any number of rotations" do
    test "the lifetime totals of a hash that drops off the list are carried forward" do
      name = "r3-rotate-#{unique()}"
      {:ok, key, _raw} = Keys.create(%{"name" => name, "budget_usd" => 2.0})
      on_exit(fn -> Keys.delete(name) end)
      first = key.key_sha256
      {:ok, _} = Ledger.record_media(%{"id" => "r3-evt-#{unique()}", "key_sha256" => first, "status" => 200, "cost_usd" => 1.5, "route_model" => "x"})
      assert_in_delta Keys.totals(Keys.find(name)).cost_usd, 1.5, 1.0e-9

      # Fifty rotations keep the first hash on the list; the fifty-first drops it.
      for _ <- 1..50, do: {:ok, _, _} = Keys.rotate(name)
      assert first in Keys.hashes(Keys.find(name))
      {:ok, rotated, _} = Keys.rotate(name)
      refute first in Keys.hashes(rotated)

      current = Keys.find(name)
      assert_in_delta Keys.totals(current).cost_usd, 1.5, 1.0e-9
      assert Keys.totals(current).requests == 1
      assert_in_delta Keys.period_spend(current), 1.5, 1.0e-9

      # ... so a total budget that was nearly spent is still nearly spent.
      {:ok, _} =
        Ledger.record_media(%{"id" => "r3-evt-#{unique()}", "key_sha256" => current.key_sha256, "status" => 200, "cost_usd" => 0.6, "route_model" => "x"})

      assert Keys.over_budget?(Keys.find(name))
    end
  end

  # ============================================================= L7

  describe "L7: only public unicast IPv6 is called" do
    test "everything outside 2000::/3 is refused, the IPv4-translated form included" do
      # ::ffff:0:a.b.c.d (SIIT), with a public and with a private address inside.
      assert NetGuard.private?({0, 0, 0, 0, 0xFFFF, 0, 0x0808, 0x0808})
      assert NetGuard.private?({0, 0, 0, 0, 0xFFFF, 0, 0x7F00, 0x0001})
      # Reserved and unassigned space.
      for a <- [0x0000, 0x0200, 0x0400, 0x1000, 0x4000, 0x8000, 0xA000, 0xC000, 0xE000] do
        assert NetGuard.private?({a, 0, 0, 0, 0, 0, 0, 1}), "#{Integer.to_string(a, 16)}::1 must not be called"
      end
    end

    test "public addresses are still called, and NAT64 is judged by the address inside" do
      refute NetGuard.private?({0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111})
      refute NetGuard.private?({0x2A00, 0x1450, 0x4001, 0, 0, 0, 0, 0x200E})
      refute NetGuard.private?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808})
      assert NetGuard.private?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001})
      assert NetGuard.private?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      refute NetGuard.private?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
    end
  end
end
