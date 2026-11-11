defmodule OmnigateControl.PrivacyTest.AgeReader do
  @moduledoc """
  The reading side of the age format, written from the specification for
  these tests only (the gateway itself never decrypts): a key pair, its
  recipient in text form, and decryption of a file made for it.
  """
  import Bitwise

  @charset ~c"qpzry9x8gf2tvdw0s3jn54khce6mua7l"
  @generators [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]

  def keypair do
    {public, secret} = :crypto.generate_key(:ecdh, :x25519)
    {bech32("age", public), public, secret}
  end

  def bech32(hrp, bytes) do
    padding = rem(5 - rem(bit_size(bytes), 5), 5)
    padded = <<bytes::binary, 0::size(padding)>>
    values = for <<v::5 <- padded>>, do: v
    expanded = Enum.map(String.to_charlist(hrp), &(&1 >>> 5)) ++ [0] ++ Enum.map(String.to_charlist(hrp), &(&1 &&& 31))
    mod = bxor(polymod(expanded ++ values ++ [0, 0, 0, 0, 0, 0]), 1)
    checksum = for i <- 0..5, do: mod >>> (5 * (5 - i)) &&& 31
    hrp <> "1" <> List.to_string(Enum.map(values ++ checksum, &Enum.at(@charset, &1)))
  end

  defp polymod(values) do
    Enum.reduce(values, 1, fn v, chk ->
      top = chk >>> 25
      chk = bxor((chk &&& 0x1FFFFFF) <<< 5, v)
      @generators |> Enum.with_index() |> Enum.reduce(chk, fn {g, i}, chk -> if (top >>> i &&& 1) == 1, do: bxor(chk, g), else: chk end)
    end)
  end

  def decrypt(file, public, secret) do
    [head, rest] = :binary.split(file, "\n--- ")
    ["age-encryption.org/v1", "-> X25519 " <> share64, wrapped64] = String.split(head, "\n")
    [mac64, payload] = :binary.split(rest, "\n")
    share = Base.decode64!(share64, padding: false)
    <<wrapped::binary-size(16), tag::binary-size(16)>> = Base.decode64!(wrapped64, padding: false)

    shared = :crypto.compute_key(:ecdh, share, secret, :x25519)
    wrap_key = hkdf(shared, share <> public, "age-encryption.org/v1/X25519")
    file_key = :crypto.crypto_one_time_aead(:chacha20_poly1305, wrap_key, <<0::96>>, wrapped, "", tag, false)
    true = is_binary(file_key) and byte_size(file_key) == 16
    true = Base.decode64!(mac64, padding: false) == :crypto.mac(:hmac, :sha256, hkdf(file_key, "", "header"), head <> "\n---")

    <<nonce::binary-size(16), stream::binary>> = payload
    chunks(stream, hkdf(file_key, nonce, "payload"), 0, [])
  end

  @sealed 65_536 + 16

  defp chunks(stream, key, counter, acc) when byte_size(stream) > @sealed do
    <<chunk::binary-size(@sealed), rest::binary>> = stream
    chunks(rest, key, counter + 1, [acc, open(chunk, key, counter, 0)])
  end

  defp chunks(stream, key, counter, acc) do
    # The last chunk is empty only when the whole payload is.
    true = byte_size(stream) > 16 or counter == 0
    IO.iodata_to_binary([acc, open(stream, key, counter, 1)])
  end

  defp open(sealed, key, counter, last) do
    size = byte_size(sealed) - 16
    <<ciphertext::binary-size(^size), tag::binary-size(16)>> = sealed
    plain = :crypto.crypto_one_time_aead(:chacha20_poly1305, key, <<counter::88, last::8>>, ciphertext, "", tag, false)
    true = is_binary(plain)
    plain
  end

  defp hkdf(ikm, salt, info) do
    prk = :crypto.mac(:hmac, :sha256, if(salt == "", do: <<0::256>>, else: salt), ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
  end
end

defmodule OmnigateControl.PrivacyTest.Stub do
  @moduledoc "A provider, a file host, a bucket and a webhook receiver for the privacy tests."
  use Plug.Router

  @table :omnigate_privacy_stub

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

  def bump(name), do: :ets.update_counter(@table, name, 1, {name, 0})

  defp base(conn), do: "http://127.0.0.1:#{conn.port}"
  defp send_json(conn, status, body), do: conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))

  # Replicate style.
  post "/v1/models/:owner/:name/predictions" do
    bump(:submits)
    set(:last_input, conn.body_params["input"])

    case val(:submit, :done) do
      :done ->
        send_json(conn, 201, %{id: "p-1", status: "succeeded", output: val(:output, base(conn) <> "/files/out.png")})

      {:slow, ms} ->
        Process.sleep(ms)
        send_json(conn, 201, %{id: "p-1", status: "succeeded", output: base(conn) <> "/files/out.png"})

      # A provider that quotes what it was sent in its refusal.
      :refuse ->
        send_json(conn, 400, %{detail: "cannot draw: " <> to_string(conn.body_params["input"]["prompt"])})
    end
  end

  # OpenAI images style: the picture comes back inline.
  post "/v1/images/generations" do
    send_json(conn, 200, %{data: [%{b64_json: Base.encode64(val(:file_body, "inline-bytes"))}]})
  end

  get "/files/:name" do
    bump(:downloads)
    conn |> put_resp_header("content-type", "image/png") |> send_resp(200, val(:file_body, "PNG-bytes"))
  end

  put "/bucket/*_path" do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 8_000_000)
    set(:put_body, body)
    set(:put_content_type, get_req_header(conn, "content-type"))
    send_resp(conn, 200, "")
  end

  post "/hook" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    set(:hook, if(body == "", do: JSON.encode!(conn.body_params), else: body))
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

defmodule OmnigateControl.PrivacyTest do
  @moduledoc """
  Privacy mode on the control plane: the setting and where it is accepted,
  private media jobs (nothing of the request kept, short-lived outputs),
  outputs encrypted to an age recipient, and the counters of what the data
  plane redacted.
  """
  # Not async: jobs, keys, the ledger and the config are shared named processes.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{Admin, Age, Audit, ConfigStore, Http, Jobs, Keys, Metrics, Privacy, Redactions, Rejections, Retention, Router, Storage}
  alias OmnigateControl.Jobs.Store
  alias OmnigateControl.PrivacyTest.{AgeReader, Stub}

  @admin "test-admin-token-0123456789"
  @canary "CANARY-7f3a-private-prompt"
  @meta_canary "CANARY-9b1c-private-metadata"

  setup_all do
    {:ok, server} = Bandit.start_link(plug: Stub, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    System.put_env("OMNIGATE_TEST_PROVIDER_KEY", "provider-secret")
    System.put_env("OMNIGATE_TEST_S3_KEY", "AKIATEST")
    System.put_env("OMNIGATE_TEST_S3_SECRET", "secret")
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
    route = %{model: "pv", cache_ttl_s: Keyword.get(opts, :cache_ttl_s), timeout_s: 30, targets: [%{upstream: "prov", model: "owner/model", price: @price}]}

    Map.merge(
      %{
        public_base_url: "http://gateway.test",
        poll_interval_ms: 10,
        max_output_bytes: 2_000_000,
        max_input_bytes: 1_048_576,
        max_open_jobs: 100,
        upstreams: [%{name: "prov", kind: kind, base_url: base, api_key_env: "OMNIGATE_TEST_PROVIDER_KEY"}],
        routes: [route],
        storage: %{kind: "local", dir: Application.fetch_env!(:omnigate_control, :media_dir), url_ttl_s: 600},
        webhooks: %{retry_schedule_ms: [30], max_attempts: 2, timeout_ms: 2_000, max_concurrent: 4, max_concurrent_per_key: 4, allow_private: true, secret: "s"}
      },
      Map.new(Keyword.get(opts, :media, []))
    )
  end

  defp wait_idle(tries \\ 500) do
    busy = Enum.filter(Store.all(), &(not Jobs.terminal?(&1) or Jobs.provider_pending?(&1)))

    cond do
      busy == [] -> :ok
      tries == 0 -> Enum.each(busy, &Jobs.finish(&1["id"], "canceled", %{}))
      true -> Process.sleep(10) && wait_idle(tries - 1)
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
  defp hash, do: "pvkey-#{unique()}"
  defp call(conn), do: Router.call(conn, Router.init([]))
  defp json(conn), do: JSON.decode!(conn.resp_body)
  defp bearer(conn), do: put_req_header(conn, "authorization", "Bearer " <> @admin)
  defp settled?(job), do: Jobs.terminal?(job) and job["ledgered"] == true
  defp private, do: [privacy: %{no_store: true, encrypt_to: nil}]

  defp internal(conn, hash \\ nil) do
    conn = put_req_header(conn, "x-omnigate-internal", OmnigateControl.internal_token())
    if hash, do: put_req_header(conn, "x-omnigate-key-sha256", hash), else: conn
  end

  defp admin_json(method, path, body) do
    conn(method, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json") |> bearer() |> call()
  end

  defp params(extra \\ %{}), do: Map.merge(%{"model" => "pv", "input" => %{"prompt" => @canary}, "metadata" => %{"note" => @meta_canary}}, extra)

  defp jobs_log, do: Application.fetch_env!(:omnigate_control, :jobs_path)
  defp media_dir, do: Application.fetch_env!(:omnigate_control, :media_dir)
  defp stored_files(id), do: with({:ok, names} <- File.ls(Path.join(media_dir(), id)), do: names, else: (_ -> []))

  # Every regular file under `dir`, with its bytes.
  defp files_under(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(dir, name)
          if File.dir?(path), do: files_under(path), else: [{path, File.read!(path)}]
        end)

      _ ->
        []
    end
  end

  # ================================================================ setting

  describe "the setting" do
    test "true is no_store, redact and unlink; an object picks parts; nothing on is nil" do
      assert Privacy.normalize(true) == {:ok, %{no_store: true, redact: Privacy.classes(), unlink: true, encrypt_to: nil, attested: false}}
      assert Privacy.normalize(nil) == {:ok, nil}
      assert Privacy.normalize(false) == {:ok, nil}
      assert Privacy.normalize(%{}) == {:ok, nil}
      assert Privacy.normalize(%{"no_store" => false, "redact" => [], "unlink" => false, "encrypt_to" => nil}) == {:ok, nil}

      assert Privacy.normalize(%{"redact" => ["secret", "email"]}) ==
               {:ok, %{no_store: false, redact: ["email", "secret"], unlink: false, encrypt_to: nil, attested: false}}

      assert {:ok, %{redact: all, no_store: true}} = Privacy.normalize(%{"redact" => true, "no_store" => true})
      assert all == ~w(email phone card ip secret)
    end

    test "anything it does not know is refused, with a message that says what is allowed" do
      for bad <- [
            "on",
            1,
            [],
            %{"no_store" => "yes"},
            %{"redact" => ["email", "name"]},
            %{"redact" => "all"},
            %{"unlink" => 1},
            %{"nostore" => true},
            %{"encrypt_to" => 5}
          ] do
        assert {:error, message} = Privacy.normalize(bad), inspect(bad)
        assert message =~ "privacy"
      end

      assert {:error, message} = Privacy.normalize(%{"redact" => ["names"]})
      assert message =~ "email, phone, card, ip, secret"
    end

    test "a recipient must be a real age recipient" do
      {recipient, _public, _secret} = AgeReader.keypair()
      assert {:ok, %{encrypt_to: ^recipient, no_store: false}} = Privacy.normalize(%{"encrypt_to" => recipient, "attested" => false})
      # Upper case is the same address.
      assert {:ok, %{encrypt_to: ^recipient}} = Privacy.normalize(%{"encrypt_to" => String.upcase(recipient)})

      flipped = String.replace_suffix(recipient, String.last(recipient), if(String.last(recipient) == "q", do: "p", else: "q"))

      for bad <- [
            "age1",
            flipped,
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            "AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ",
            "age1" <> String.duplicate("q", 58),
            String.slice(recipient, 0, 30),
            recipient <> "\n",
            String.duplicate("a", 10_000)
          ] do
        assert {:error, message} = Privacy.normalize(%{"encrypt_to" => bad}), inspect(bad)
        assert message =~ "age recipient"
      end
    end

    test "the config file takes it on a key, and refuses a wrong one at load" do
      {recipient, _, _} = AgeReader.keypair()

      config =
        ConfigStore.normalize(%{
          "keys" => [
            %{"name" => "plain", "key" => "k1"},
            %{"name" => "all", "key" => "k2", "privacy" => true},
            %{"name" => "some", "key" => "k3", "privacy" => %{"redact" => ["email"], "encrypt_to" => recipient}}
          ],
          "upstreams" => [
            %{"name" => "a", "kind" => "openai", "base_url" => "https://x", "api_key_env" => "K"},
            %{"name" => "b", "kind" => "openai", "base_url" => "https://y", "api_key_env" => "K", "privacy_store_flag" => true}
          ],
          "retention" => %{"private_outputs_hours" => 2}
        })

      assert [nil, %{no_store: true, unlink: true}, %{redact: ["email"], encrypt_to: ^recipient, no_store: false}] = Enum.map(config.keys, & &1.privacy)
      assert Enum.map(config.upstreams, & &1.privacy_store_flag) == [nil, true]
      assert config.retention.private_outputs_hours == 2
      assert ConfigStore.normalize(%{}).retention.private_outputs_hours == 24

      assert_raise ArgumentError, ~r/key "bad": privacy/, fn ->
        ConfigStore.normalize(%{"keys" => [%{"name" => "bad", "key" => "k", "privacy" => %{"redact" => ["x"]}}]})
      end

      assert_raise ArgumentError, ~r/key "bad": privacy.encrypt_to/, fn ->
        ConfigStore.normalize(%{"keys" => [%{"name" => "bad", "key" => "k", "privacy" => %{"encrypt_to" => "age1nope"}}]})
      end

      assert_raise ArgumentError, ~r/privacy_store_flag/, fn ->
        ConfigStore.normalize(%{"upstreams" => [%{"name" => "a", "kind" => "openai", "base_url" => "x", "api_key_env" => "K", "privacy_store_flag" => "yes"}]})
      end

      assert_raise ArgumentError, ~r/private_outputs_hours/, fn -> ConfigStore.normalize(%{"retention" => %{"private_outputs_hours" => -1}}) end
    end

    test "a managed key: created with it, changed, shown, kept across a reload of the key store, and sent to data planes without the recipient" do
      {recipient, _, _} = AgeReader.keypair()
      name = "pv-managed-#{unique()}"
      on_exit(fn -> Keys.delete(name) end)

      created = admin_json(:post, "/admin/keys", %{"name" => name, "privacy" => true})
      assert created.status == 201
      assert json(created)["privacy"] == %{"no_store" => true, "redact" => Privacy.classes(), "unlink" => true, "encrypt_to" => nil, "attested" => false}
      assert json(created)["privacy_summary"] == "no-store, redact, unlink"

      changed = admin_json(:patch, "/admin/keys/#{name}", %{"privacy" => %{"redact" => ["secret"], "encrypt_to" => recipient}})
      assert changed.status == 200
      assert json(changed)["privacy"] == %{"no_store" => false, "redact" => ["secret"], "unlink" => false, "encrypt_to" => recipient, "attested" => false}

      # What is on disk reads back as the same setting.
      stored = Application.fetch_env!(:omnigate_control, :keys_path) |> File.read!() |> JSON.decode!() |> Map.fetch!("keys") |> Enum.find(&(&1["name"] == name))
      assert Privacy.load(stored["privacy"]) == Keys.find(name).privacy

      # The snapshot: what a data plane applies, and nothing else.
      in_snapshot = Router.snapshot().keys |> Enum.find(&(&1.name == name))
      assert in_snapshot.privacy == %{no_store: false, redact: ["secret"], unlink: false, attested: false}
      refute JSON.encode!(Router.snapshot()) =~ recipient
      assert Enum.all?(Router.snapshot().keys, &Map.has_key?(&1, :privacy))

      # Only the recipient left: nothing for a data plane to do.
      assert admin_json(:patch, "/admin/keys/#{name}", %{"privacy" => %{"encrypt_to" => recipient}}).status == 200
      assert (Router.snapshot().keys |> Enum.find(&(&1.name == name))).privacy == nil

      # Refused, and the key unchanged.
      refused = admin_json(:patch, "/admin/keys/#{name}", %{"privacy" => %{"redact" => ["everything"]}})
      assert refused.status == 400
      assert json(refused)["error"]["message"] =~ "privacy.redact"
      assert Keys.find(name).privacy.encrypt_to == recipient

      # Off again; a key listed by the admin API says so with null.
      assert admin_json(:patch, "/admin/keys/#{name}", %{"privacy" => false}).status == 200
      assert Keys.find(name).privacy == nil
      listed = conn(:get, "/admin/keys") |> bearer() |> call() |> json() |> Map.fetch!("keys") |> Enum.find(&(&1["name"] == name))
      assert listed["privacy"] == nil and listed["privacy_summary"] == ""
    end

    test "changing it is written to the audit log, with what it became and never the recipient" do
      {recipient, _, _} = AgeReader.keypair()
      name = "pv-audit-#{unique()}"
      on_exit(fn -> Keys.delete(name) end)

      assert admin_json(:post, "/admin/keys", %{"name" => name}).status == 201
      assert admin_json(:patch, "/admin/keys/#{name}", %{"privacy" => %{"no_store" => true, "encrypt_to" => recipient}}).status == 200
      assert admin_json(:patch, "/admin/keys/#{name}", %{"privacy" => nil}).status == 200
      assert admin_json(:patch, "/admin/keys/#{name}", %{"rpm" => 5}).status == 200

      entries = Audit.recent(20) |> Enum.filter(&(&1["target"] == name))

      assert [
               %{"action" => "key.update"} = rpm,
               %{"privacy" => "off"},
               %{"privacy" => "no-store, encrypt", "fields" => ["privacy"]},
               %{"action" => "key.create"} = created
             ] = entries

      refute Map.has_key?(rpm, "privacy")
      refute Map.has_key?(created, "privacy")
      refute JSON.encode!(entries) =~ recipient
    end

    test "the dashboard shows a key's privacy mode and can change it" do
      name = "pv-dash-#{unique()}"
      on_exit(fn -> Keys.delete(name) end)
      {:ok, _key, _raw} = Keys.create(%{"name" => name, "privacy" => %{"no_store" => true, "unlink" => true}})

      page = conn(:get, "/") |> bearer() |> call()
      assert page.status == 200
      assert page.resp_body =~ "no-store, unlink"
      assert page.resp_body =~ ~s(data-action="privacy")
      assert page.resp_body =~ ~s(name="privacy")
      assert Admin.overview().keys |> Enum.find(&(&1.name == name)) |> Map.fetch!(:privacy_summary) == "no-store, unlink"
    end

    test "the request header for a job: the same words the data plane takes" do
      assert Privacy.header(nil) == {:ok, false}
      assert Privacy.header("on") == {:ok, true}
      assert Privacy.header(" No-Store , redact ") == {:ok, true}
      assert Privacy.header("redact,unlink") == {:ok, false}
      for bad <- ["", "off", "false", "0", "no-store;redact", String.duplicate("x", 65)], do: assert(Privacy.header(bad) == :error, bad)
    end
  end

  # ================================================================ redaction counts

  describe "what the data plane redacted" do
    test "is counted by key and class, apart from refusals, and shown in the metrics" do
      Redactions.reset()
      Rejections.reset()
      key = "pv-counted-#{unique()}"

      body = %{
        "counters" => [
          %{"key" => key, "reason" => "redacted_email", "count" => 3},
          %{"key" => key, "reason" => "redacted_secret", "count" => 1},
          %{"key" => key, "reason" => "redacted_email", "count" => 2},
          %{"key" => key, "reason" => "rate_limit_exceeded", "count" => 7},
          %{"key" => key, "reason" => "redacted_names", "count" => 9},
          %{"key" => key, "reason" => "redacted_email", "count" => -1},
          %{"key" => String.duplicate("k", 65), "reason" => "redacted_email", "count" => 1}
        ]
      }

      answer = conn(:post, "/internal/counters", JSON.encode!(body)) |> put_req_header("content-type", "application/json") |> internal() |> call()
      assert json(answer) == %{"accepted" => 4}

      assert Redactions.all() == [%{key: key, class: "email", count: 5}, %{key: key, class: "secret", count: 1}]
      assert Rejections.all() == [%{key: key, reason: "rate_limit_exceeded", count: 7}]

      page = Metrics.render()
      assert page =~ ~s(omnigate_redactions_total{key="#{key}",class="email"} 5)
      assert page =~ ~s(omnigate_redactions_total{key="#{key}",class="secret"} 1)
      refute page =~ ~s(omnigate_rejected_requests_total{key="#{key}",reason="redacted_email"})
      assert Enum.any?(Admin.overview().redactions, &(&1.key == key and &1.class == "email" and &1.count == 5))
    end
  end

  # ================================================================ private jobs

  describe "a private job (no_store)" do
    test "keeps its input and metadata out of the job log, shows them while it runs, and erases them when it ends", %{base: base} do
      Stub.set(:submit, {:slow, 300})
      # Strings no other test puts into a job (theirs may be in the log, by design).
      canary = "ONLY-HERE-prompt-#{unique()}"
      meta_canary = "ONLY-HERE-metadata-#{unique()}"
      mine = fn extra -> Map.merge(%{"model" => "pv", "input" => %{"prompt" => canary}, "metadata" => %{"note" => meta_canary}}, extra) end
      key = hash()
      {:ok, job} = Jobs.create(key, mine.(%{"webhook_url" => base <> "/hook"}), nil, private())
      id = job["id"]

      # While it runs: the client can read back what it sent; a list does not open the files.
      running = Jobs.view(Store.get(id))
      assert running["private"] == true
      assert running["input"] == %{"prompt" => canary}
      assert running["metadata"] == %{"note" => meta_canary}
      listed = Jobs.view(Store.get(id), input: false)
      assert listed["input"] == nil and listed["input_omitted"] == true and listed["metadata"] == nil and listed["metadata_omitted"] == true
      # The record itself holds neither.
      assert Store.get(id)["input"] == nil and Store.get(id)["metadata"] == nil
      assert File.exists?(Store.input_path(id))

      done = await(id, &settled?/1)
      assert done["status"] == "succeeded"
      # The provider did get the prompt: that is what the job is for.
      assert Stub.val(:last_input) == %{"prompt" => canary}

      assert done["erased"] == true
      view = Jobs.view(done)
      assert view["input"] == nil and view["metadata"] == nil and view["input_erased"] == true and view["private"] == true
      refute Map.has_key?(view, "input_omitted")
      refute File.exists?(Store.input_path(id))
      refute File.exists?(String.replace_suffix(Store.input_path(id), ".json", ".meta.json"))

      # The webhook went out after the erasure.
      assert wait_until(fn -> Stub.val(:hook) != nil end)
      hook = Stub.val(:hook)
      assert JSON.decode!(hook)["data"]["id"] == id
      assert JSON.decode!(hook)["data"]["input_erased"] == true
      refute hook =~ canary
      refute hook =~ meta_canary

      # Nothing the control plane wrote holds either string: the job log
      # (also after the store rewrote it), the input files, the audit log.
      for path <- [jobs_log(), Application.fetch_env!(:omnigate_control, :audit_path)], File.exists?(path) do
        text = File.read!(path)
        refute text =~ canary, path
        refute text =~ meta_canary, path
      end

      for {path, bytes} <- files_under(jobs_log() <> ".inputs") do
        refute bytes =~ canary, path
        refute bytes =~ meta_canary, path
      end

      # The answer to a repeat with the same Idempotency-Key is the erased job, too.
      assert {:ok, again} = Jobs.create(key, mine.(%{}), "idem-#{id}", private())
      await(again["id"], &settled?/1)
      assert {:existing, existing} = Jobs.create(key, mine.(%{}), "idem-#{id}", private())
      assert Jobs.view(existing)["input"] == nil
    end

    test "says nothing of what a provider answered beyond the kind of failure, in the job and in the log" do
      Stub.set(:submit, :refuse)

      log =
        capture_log(fn ->
          {:ok, job} = Jobs.create(hash(), params(), nil, private())
          failed = await(job["id"], &settled?/1)
          assert failed["status"] == "failed"
          assert Enum.map(failed["attempts"], & &1["outcome"]) == ["http_400"]
          refute JSON.encode!(Jobs.view(failed)) =~ @canary
        end)

      refute log =~ @canary
      assert log =~ "http_400"

      # A job that is not private keeps the provider's words, as before.
      {:ok, open} = Jobs.create(hash(), params())
      assert [%{"outcome" => outcome}] = await(open["id"], &settled?/1)["attempts"]
      assert outcome =~ "cannot draw: " <> @canary
    end

    test "neither reads nor feeds the job cache", %{base: base} do
      ConfigStore.put_media(media(base, cache_ttl_s: 600))
      key = hash()
      # An input no other test's job has (the job cache is shared by all keys).
      probe = params(%{"cache" => true, "input" => %{"prompt" => "cache-probe-#{unique()}"}})

      {:ok, first} = Jobs.create(key, probe, nil, private())
      assert await(first["id"], &settled?/1)["status"] == "succeeded"
      assert Store.get(first["id"])["cache_key"] == nil

      # The same request again, private: the provider is asked again.
      {:ok, second} = Jobs.create(key, probe, nil, private())
      assert await(second["id"], &settled?/1)["cached"] == false
      assert Stub.val(:submits) == 2

      # And an open job with the same input is not handed the private one's output.
      {:ok, open} = Jobs.create(hash(), probe)
      assert await(open["id"], &settled?/1)["cached"] == false
      assert Stub.val(:submits) == 3

      # (The cache itself works: the open job's twin is served from it.)
      {:ok, twin} = Jobs.create(hash(), probe)
      assert await(twin["id"], &settled?/1)["cached"] == true
      assert Stub.val(:submits) == 3
    end

    test "is what the request header asks for, on a key that is not private; a wrong header is refused" do
      name = "pv-header-#{unique()}"
      on_exit(fn -> Keys.delete(name) end)
      {:ok, key, _raw} = Keys.create(%{"name" => name})

      post = fn headers ->
        Enum.reduce(
          headers,
          conn(:post, "/internal/v1/jobs", JSON.encode!(params())) |> put_req_header("content-type", "application/json") |> internal(key.key_sha256),
          fn {k, v}, c ->
            put_req_header(c, k, v)
          end
        )
        |> call()
      end

      plain = post.([])
      assert plain.status == 202
      assert json(plain)["input"] == %{"prompt" => @canary}
      refute Map.has_key?(json(plain), "private")

      asked = post.([{"x-omnigate-privacy", "no-store"}])
      assert asked.status == 202
      assert json(asked)["private"] == true
      assert await(json(asked)["id"], &settled?/1)["erased"] == true

      # Parts that are the data plane's business do not make a job private.
      assert json(post.([{"x-omnigate-privacy", "redact"}]))["private"] == nil

      bad = post.([{"x-omnigate-privacy", "off"}])
      assert bad.status == 400
      assert json(bad)["error"]["code"] == "invalid_request"
      await(json(plain)["id"], &settled?/1)
    end

    test "is every job of a key whose setting says no_store" do
      name = "pv-keyed-#{unique()}"
      on_exit(fn -> Keys.delete(name) end)
      {:ok, key, _raw} = Keys.create(%{"name" => name, "privacy" => true})

      answer =
        conn(:post, "/internal/v1/jobs", JSON.encode!(params())) |> put_req_header("content-type", "application/json") |> internal(key.key_sha256) |> call()

      assert answer.status == 202
      assert json(answer)["private"] == true
      assert await(json(answer)["id"], &settled?/1)["erased"] == true
    end

    test "ends and is erased in one write: no reader finds it finished and not yet erased" do
      # Many jobs, each watched by a reader that does nothing but look.
      for round <- 1..12 do
        Stub.set(:submit, {:slow, 5 + rem(round, 4) * 5})
        {:ok, job} = Jobs.create(hash(), %{"model" => "pv", "input" => %{"prompt" => "watched #{round}"}, "metadata" => %{"n" => round}}, nil, private())
        id = job["id"]

        watcher =
          Task.async(fn ->
            Stream.repeatedly(fn -> Store.get(id) end)
            |> Enum.reduce_while(0, fn seen, looks ->
              cond do
                seen["status"] in ~w(succeeded failed canceled) and seen["erased"] != true -> {:halt, {:finished_unerased, seen}}
                seen["erased"] == true -> {:halt, {:ok, looks}}
                true -> {:cont, looks + 1}
              end
            end)
          end)

        assert {:ok, _looks} = Task.await(watcher, 10_000)
        view = Jobs.view(await(id, &settled?/1))
        assert view["status"] == "succeeded" and view["input_erased"] == true and view["input"] == nil
        # The files follow the record at once.
        assert wait_until(fn -> not File.exists?(Store.input_path(id)) end)
      end

      # A canceled job whose provider call is still open is erased when its
      # account is closed, in that same write.
      Stub.set(:submit, {:slow, 200})
      key = hash()
      {:ok, job} = Jobs.create(key, %{"model" => "pv", "input" => %{"prompt" => "to be canceled"}}, nil, private())
      assert wait_until(fn -> match?(%{"run" => %{"attempt_started_ms" => ms}} when is_integer(ms), Store.get(job["id"])) end)
      canceled = Jobs.cancel(key, job["id"])
      assert canceled["status"] == "canceled"
      settled = await(job["id"], &settled?/1)
      assert settled["erased"] == true and settled["provider_pending"] != true

      # A stop after the record was written and before the files went:
      # the next start deletes them.
      id = "job_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
      now = System.os_time(:millisecond)
      :ok = Store.put_input(id, JSON.encode!(%{"prompt" => @canary}))
      :ok = Store.put_metadata(id, JSON.encode!(%{"note" => @meta_canary}))

      {:ok, _} =
        Store.create(%{
          "id" => id,
          "status" => "succeeded",
          "model" => "pv",
          "input" => nil,
          "input_file" => false,
          "metadata" => nil,
          "metadata_file" => false,
          "private" => true,
          "erased" => true,
          "outputs" => [],
          "attempts" => [],
          "key_sha256" => hash(),
          "created_ms" => now,
          "finished_ms" => now,
          "ledgered" => true,
          "webhook" => nil,
          "cost_usd" => 0.0
        })

      assert File.exists?(Store.input_path(id))
      Jobs.resume_all()
      refute File.exists?(Store.input_path(id))
      refute File.exists?(String.replace_suffix(Store.input_path(id), ".json", ".meta.json"))
    end

    test "a stop between its end and its erasure is made up for at the next start" do
      id = "job_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
      now = System.os_time(:millisecond)
      :ok = Store.put_input(id, JSON.encode!(%{"prompt" => @canary}))
      :ok = Store.put_metadata(id, JSON.encode!(%{"note" => @meta_canary}))

      {:ok, _} =
        Store.create(%{
          "id" => id,
          "status" => "succeeded",
          "model" => "pv",
          "input" => nil,
          "input_file" => true,
          "metadata" => nil,
          "metadata_file" => true,
          "private" => true,
          "outputs" => [],
          "attempts" => [],
          "key_sha256" => hash(),
          "created_ms" => now,
          "finished_ms" => now,
          "ledgered" => true,
          "webhook" => nil,
          "cost_usd" => 0.0
        })

      assert Jobs.view(Store.get(id))["input"] == %{"prompt" => @canary}
      Jobs.resume_all()
      assert Store.get(id)["erased"] == true
      refute File.exists?(Store.input_path(id))
      assert Jobs.view(Store.get(id))["metadata"] == nil
    end

    test "has its outputs deleted after retention.private_outputs_hours; the job stays, an open job's outputs stay" do
      key = hash()
      {:ok, mine} = Jobs.create(key, params(), nil, private())
      {:ok, other} = Jobs.create(key, params())
      await(mine["id"], &settled?/1)
      await(other["id"], &settled?/1)
      assert [file] = stored_files(mine["id"])
      assert [_] = stored_files(other["id"])
      now = System.os_time(:millisecond)

      retention = %{jobs_days: 0, ledger_ids_days: 0, ledger_days: 0, delete_bucket_objects: true, private_outputs_hours: 24}
      # Not yet a day old.
      assert Retention.sweep(retention, now + 23 * 3_600_000).private_outputs == 0
      assert stored_files(mine["id"]) == [file]
      # Switched off: kept like any other job's.
      assert Retention.sweep(%{retention | private_outputs_hours: 0}, now + 100 * 3_600_000).private_outputs == 0

      result = Retention.sweep(retention, now + 25 * 3_600_000)
      # (Other tests' private jobs are a day old by then as well.)
      assert result.private_outputs >= 1 and result.jobs == 0
      assert stored_files(mine["id"]) == []
      assert [_] = stored_files(other["id"])

      kept = Store.get(mine["id"])
      assert kept["status"] == "succeeded" and kept["outputs"] == [] and kept["outputs_expired"] == true
      assert Jobs.view(kept)["outputs_expired"] == true and Jobs.view(kept)["cost_usd"] == 0.25
      # Nothing left to do the next time.
      assert Retention.sweep(retention, now + 26 * 3_600_000).private_outputs == 0
    end
  end

  # ================================================================ encrypted outputs

  describe "the age format" do
    test "a file made for a recipient is read back by the format's own rules, at every chunk boundary" do
      {recipient, public, secret} = AgeReader.keypair()

      for size <- [0, 1, 65_535, 65_536, 65_537, 131_072, 131_073, 200_000] do
        plain = :crypto.strong_rand_bytes(size)
        sealed = Age.encrypt(recipient, plain)
        assert String.starts_with?(sealed, "age-encryption.org/v1\n-> X25519 ")
        assert AgeReader.decrypt(sealed, public, secret) == plain, "size #{size}"
        # Header, 16-byte nonce, and 16 bytes of tag per chunk.
        chunks = max(1, div(size + 65_535, 65_536))
        [head, _] = :binary.split(sealed, "\n--- ")
        assert byte_size(sealed) == byte_size(head) + 5 + 43 + 1 + 16 + size + 16 * chunks

        # Fed in pieces, the result decrypts to the same thing.
        {header, state} = Age.start(recipient)

        {body, state} =
          Enum.reduce(
            for(<<piece::binary-size(7_919) <- plain>>, do: piece) ++ [binary_part(plain, size - rem(size, 7_919), rem(size, 7_919))],
            {[], state},
            fn piece, {out, st} ->
              {more, st} = Age.update(st, piece)
              {[out, more], st}
            end
          )

        assert AgeReader.decrypt(IO.iodata_to_binary([header, body, Age.finish(state)]), public, secret) == plain
      end

      # Two files for the same recipient share nothing.
      refute Age.encrypt(recipient, "same") == Age.encrypt(recipient, "same")
    end

    test "recipients: the text form is checked, down to its checksum" do
      {recipient, public, _} = AgeReader.keypair()
      assert Age.recipient(recipient) == {:ok, public}
      assert Age.valid_recipient?(String.upcase(recipient))
      # The specification's own example recipient.
      assert Age.valid_recipient?("age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p")
      refute Age.valid_recipient?("age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8q")
      refute Age.valid_recipient?("Age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p")
      refute Age.valid_recipient?(AgeReader.bech32("age", :crypto.strong_rand_bytes(31)))
      refute Age.valid_recipient?(AgeReader.bech32("agf", public))
      refute Age.valid_recipient?(nil)
    end
  end

  describe "a download that is encrypted as it arrives" do
    test "writes only ciphertext, and reports both what it wrote and what it read", %{base: base} do
      {recipient, public, secret} = AgeReader.keypair()
      plain = :crypto.strong_rand_bytes(150_000)
      Stub.set(:file_body, plain)
      dest = Path.join(System.tmp_dir!(), "omnigate-pv-download-#{unique()}")
      on_exit(fn -> File.rm(dest) end)

      assert {:ok, meta} = Http.download(base <> "/files/a.png", dest, 1_000_000, encrypt: recipient)
      written = File.read!(dest)
      assert meta.bytes == byte_size(written)
      assert meta.sha256 == :crypto.hash(:sha256, written) |> Base.encode16(case: :lower)
      assert meta.plaintext_bytes == 150_000
      assert meta.plaintext_sha256 == :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)
      assert meta.content_type == "image/png"
      assert AgeReader.decrypt(written, public, secret) == plain
      assert :binary.match(written, binary_part(plain, 1_000, 64)) == :nomatch

      # The limit is on what is downloaded; a refused download leaves no file.
      assert {:error, :output_too_large} = Http.download(base <> "/files/a.png", dest, 100_000, encrypt: recipient)
      refute File.exists?(dest)

      # Without the option nothing changed.
      assert {:ok, %{bytes: 150_000} = open} = Http.download(base <> "/files/a.png", dest, 1_000_000)
      refute Map.has_key?(open, :plaintext_sha256)
      assert File.read!(dest) == plain
    end
  end

  describe "a job of a key with encrypt_to" do
    defp encrypting(recipient, no_store \\ false), do: [privacy: %{no_store: no_store, encrypt_to: recipient}]

    test "stores its outputs encrypted: on local disk, with a record that says so, and never in the clear" do
      {recipient, public, secret} = AgeReader.keypair()
      plain = "PNG-MARKER-" <> :crypto.strong_rand_bytes(200_000)
      Stub.set(:file_body, plain)

      {:ok, job} = Jobs.create(hash(), params(), nil, encrypting(recipient))
      done = await(job["id"], &settled?/1)
      assert done["status"] == "succeeded"

      assert [record] = done["outputs"]
      assert record["name"] == "out-0.png.age"
      assert record["encryption"] == "age"
      assert record["content_type"] == "application/octet-stream"
      assert record["plaintext_content_type"] == "image/png"
      assert record["plaintext_bytes"] == byte_size(plain)
      assert record["plaintext_sha256"] == :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)

      stored = File.read!(Storage.Local.path(ConfigStore.get().media.storage, job["id"], "out-0.png.age"))
      assert record["bytes"] == byte_size(stored)
      assert record["sha256"] == :crypto.hash(:sha256, stored) |> Base.encode16(case: :lower)
      assert AgeReader.decrypt(stored, public, secret) == plain

      # What a client is told, and what it downloads.
      [output] = Jobs.view(done)["outputs"]

      assert output["encryption"] == "age" and output["plaintext_sha256"] == record["plaintext_sha256"] and
               output["url"] =~ "/v1/files/#{job["id"]}/out-0.png.age?"

      %URI{path: path, query: query} = URI.parse(output["url"])
      served = conn(:get, "/internal" <> path <> "?" <> query) |> internal() |> call()
      assert served.status == 200
      assert get_resp_header(served, "content-type") == ["application/octet-stream"]
      assert served.resp_body == stored

      # Nowhere under the media directory (its temp directory included) is the marker.
      for {path, bytes} <- files_under(media_dir()), do: assert(:binary.match(bytes, "PNG-MARKER-") == :nomatch, path)
      assert Storage.tmp_dir() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, job["id"])) == []

      # Not a source for anybody's cache hit.
      assert done["cache_key"] == nil
      # The key is not private: what was asked is still there.
      assert Jobs.view(done)["input"] == %{"prompt" => @canary}
    end

    test "also when the provider answers with the bytes inline", %{base: base} do
      {recipient, public, secret} = AgeReader.keypair()
      ConfigStore.put_media(media(base, kind: "openai_images"))
      plain = "INLINE-MARKER-" <> :crypto.strong_rand_bytes(65_536 - 14)
      Stub.set(:file_body, plain)

      {:ok, job} = Jobs.create(hash(), params(), nil, encrypting(recipient, true))
      done = await(job["id"], &settled?/1)
      assert done["status"] == "succeeded", inspect(done["attempts"])
      assert [%{"encryption" => "age", "name" => name, "plaintext_bytes" => 65_536}] = done["outputs"]
      assert String.ends_with?(name, ".age")
      stored = File.read!(Storage.Local.path(ConfigStore.get().media.storage, job["id"], name))
      assert AgeReader.decrypt(stored, public, secret) == plain
      for {path, bytes} <- files_under(media_dir()), do: assert(:binary.match(bytes, "INLINE-MARKER-") == :nomatch, path)
      # Private as well: erased, and not cached.
      assert done["erased"] == true
    end

    test "uploads ciphertext to a bucket, as opaque bytes", %{base: base} do
      {recipient, public, secret} = AgeReader.keypair()
      plain = "BUCKET-MARKER-" <> :crypto.strong_rand_bytes(70_000)
      Stub.set(:file_body, plain)

      storage = %{
        kind: "s3",
        endpoint: base,
        bucket: "bucket",
        region: "auto",
        prefix: "",
        access_key_env: "OMNIGATE_TEST_S3_KEY",
        secret_key_env: "OMNIGATE_TEST_S3_SECRET",
        public_base_url: base <> "/bucket",
        presign_ttl_s: 600
      }

      ConfigStore.put_media(media(base, media: [storage: storage]))
      {:ok, job} = Jobs.create(hash(), params(), nil, encrypting(recipient))
      done = await(job["id"], &settled?/1)
      assert done["status"] == "succeeded", inspect(done["attempts"])

      uploaded = Stub.val(:put_body)
      assert Stub.val(:put_content_type) == ["application/octet-stream"]
      assert :binary.match(uploaded, "BUCKET-MARKER-") == :nomatch
      assert AgeReader.decrypt(uploaded, public, secret) == plain
      assert [%{"storage" => "s3", "key" => key, "sha256" => sha}] = done["outputs"]
      assert String.ends_with?(key, "/out-0.png.age")
      assert sha == :crypto.hash(:sha256, uploaded) |> Base.encode16(case: :lower)
      # The temp file that was uploaded is gone, and it never held the plaintext.
      assert Storage.tmp_dir() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, job["id"])) == []
    end

    test "is not handed another job's output from the cache, nor is its own handed on", %{base: base} do
      {recipient, _public, _secret} = AgeReader.keypair()
      ConfigStore.put_media(media(base, cache_ttl_s: 600))
      probe = params(%{"cache" => true, "input" => %{"prompt" => "cache-probe-encrypted-#{unique()}"}})

      {:ok, open} = Jobs.create(hash(), probe)
      await(open["id"], &settled?/1)
      {:ok, mine} = Jobs.create(hash(), probe, nil, encrypting(recipient))
      done = await(mine["id"], &settled?/1)
      assert done["cached"] == false
      assert [%{"encryption" => "age"}] = done["outputs"]
      {:ok, after_mine} = Jobs.create(hash(), probe)
      # Served from the open job's output, which is not encrypted.
      assert [%{"name" => "out-0.png"} = shared] = await(after_mine["id"], &settled?/1)["outputs"]
      refute Map.has_key?(shared, "encryption")
    end
  end
end
