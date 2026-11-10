defmodule OmnigateControl.MediaUnitTest do
  use ExUnit.Case, async: true

  alias OmnigateControl.{ConfigStore, Jobs, SigV4, UrlSigner, Webhooks}

  describe "SigV4" do
    # Worked example from the AWS Signature Version 4 documentation
    # (GET iam ListUsers, 2015-08-30).
    @creds %{
      access_key: "AKIDEXAMPLE",
      secret_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      region: "us-east-1",
      service: "iam"
    }
    @empty_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    @headers [
      {"content-type", "application/x-www-form-urlencoded; charset=utf-8"},
      {"host", "iam.amazonaws.com"},
      {"x-amz-date", "20150830T123600Z"}
    ]

    test "signing key derivation matches the AWS example" do
      key = SigV4.signing_key(@creds.secret_key, "20150830", "us-east-1", "iam")

      assert Base.encode16(key, case: :lower) ==
               "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9"
    end

    test "canonical request hash matches the AWS example" do
      {canonical, signed} =
        SigV4.canonical_request("GET", "/", "Action=ListUsers&Version=2010-05-08", @headers, @empty_hash)

      assert signed == "content-type;host;x-amz-date"
      assert SigV4.sha256_hex(canonical) == "f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59"
    end

    test "full signature matches the AWS example" do
      assert SigV4.signature("GET", "/", "Action=ListUsers&Version=2010-05-08", @headers, @empty_hash, "20150830T123600Z", @creds) ==
               "5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7"
    end

    test "sign_headers produces an authorization header covering host, date and payload hash" do
      now = ~U[2026-01-02 03:04:05Z]
      creds = %{@creds | service: "s3"}

      headers =
        SigV4.sign_headers("PUT", "http://127.0.0.1:9106/bucket/job_1/out-0.png", [{"content-type", "image/png"}], @empty_hash, creds, now)

      assert {"x-amz-date", "20260102T030405Z"} in headers
      assert {"x-amz-content-sha256", @empty_hash} in headers
      refute Enum.any?(headers, fn {k, _} -> k == "host" end)
      {_, auth} = List.keyfind(headers, "authorization", 0)
      assert auth =~ "Credential=AKIDEXAMPLE/20260102/us-east-1/s3/aws4_request"
      assert auth =~ "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date"
    end

    test "presigned URLs carry the expiry and a signature" do
      url = SigV4.presign_get("http://127.0.0.1:9106/bucket/a b/c.png", 600, %{@creds | service: "s3"}, ~U[2026-01-02 03:04:05Z])
      assert url =~ "http://127.0.0.1:9106/bucket/a%20b/c.png?"
      assert url =~ "X-Amz-Expires=600"
      assert url =~ ~r/X-Amz-Signature=[0-9a-f]{64}$/
    end
  end

  describe "webhook signatures" do
    # Example published with the Standard Webhooks / Svix verification docs.
    test "match the Standard Webhooks reference example" do
      assert Webhooks.signature(
               "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw",
               "msg_p5jXN8AQM9LWM0D4loKWxJek",
               1_614_265_330,
               ~s({"test": 2432232314})
             ) == "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
    end

    test "a secret without the whsec_ prefix is used as raw bytes" do
      expected = "v1," <> Base.encode64(:crypto.mac(:hmac, :sha256, "plain", "id.5.body"))
      assert Webhooks.signature("plain", "id", 5, "body") == expected
    end
  end

  describe "signed file URLs" do
    test "verify, reject tampering and expire" do
      query = UrlSigner.sign("job_1", "out-0.png", 60, 1_000)
      %{"exp" => exp, "sig" => sig} = URI.decode_query(query)

      assert exp == "1060"
      assert UrlSigner.verify("job_1", "out-0.png", exp, sig, 1_030) == :ok
      assert UrlSigner.verify("job_1", "out-0.png", exp, sig, 1_061) == {:error, :expired}
      assert UrlSigner.verify("job_2", "out-0.png", exp, sig, 1_030) == {:error, :bad_signature}
      assert UrlSigner.verify("job_1", "out-1.png", exp, sig, 1_030) == {:error, :bad_signature}
      # Extending the expiry invalidates the signature.
      assert UrlSigner.verify("job_1", "out-0.png", "9999", sig, 1_030) == {:error, :bad_signature}
      assert UrlSigner.verify("job_1", "out-0.png", nil, nil, 1_030) == {:error, :missing}
    end
  end

  describe "cost" do
    @price %{per_job_usd: 0.01, per_output_usd: 0.002, per_input_char_usd: 0.0001, per_second_usd: 0.1}

    test "adds per-job, per-output, per-character and per-second prices" do
      assert_in_delta Jobs.cost(@price, %{"text" => "hello", "duration" => 5}, 2),
                      0.01 + 2 * 0.002 + 5 * 0.0001 + 5 * 0.1,
                      1.0e-12
    end

    test "tolerates missing or textual durations" do
      assert_in_delta Jobs.cost(@price, %{"prompt" => "ab", "duration" => "8"}, 1), 0.01 + 0.002 + 0.0002 + 0.8, 1.0e-12
      assert_in_delta Jobs.cost(@price, %{}, 0), 0.01, 1.0e-12
    end
  end

  describe "cache keys" do
    test "ignore key order but not values or the model" do
      a = Jobs.cache_key("m", %{"prompt" => "a cat", "opts" => %{"w" => 1, "h" => 2}})
      b = Jobs.cache_key("m", %{"opts" => %{"h" => 2, "w" => 1}, "prompt" => "a cat"})
      assert a == b
      refute a == Jobs.cache_key("m", %{"prompt" => "a dog", "opts" => %{"w" => 1, "h" => 2}})
      refute a == Jobs.cache_key("other", %{"prompt" => "a cat", "opts" => %{"w" => 1, "h" => 2}})
    end
  end

  describe "config" do
    test "normalize reads rpm, webhook secrets and the media section" do
      config =
        ConfigStore.normalize(%{
          "keys" => [
            %{"name" => "a", "key" => "abc", "rpm" => 5, "webhook_secret" => "s"},
            %{"name" => "b", "key" => "def"}
          ],
          "media" => %{
            "upstreams" => [%{"name" => "r", "kind" => "replicate", "base_url" => "http://x/", "api_key_env" => "K"}],
            "routes" => [
              %{"model" => "img", "cache_ttl_s" => 60, "targets" => [%{"upstream" => "r", "model" => "o/m", "price" => %{"per_output_usd" => 1}}]}
            ],
            "storage" => %{"kind" => "s3", "endpoint" => "http://s3/", "bucket" => "b", "access_key_env" => "A", "secret_key_env" => "S"}
          }
        })

      [a, b] = config.keys
      assert a.rpm == 5 and a.webhook_secret == "s"
      assert b.rpm == 0 and b.webhook_secret == nil

      [up] = config.media.upstreams
      assert up.base_url == "http://x"
      [route] = config.media.routes
      assert route.cache_ttl_s == 60 and route.timeout_s == 600
      assert hd(route.targets).price == %{per_job_usd: 0.0, per_output_usd: 1.0, per_input_char_usd: 0.0, per_second_usd: 0.0}
      assert config.media.storage.public_base_url == "http://s3/b"
      assert config.media.public_base_url == "http://127.0.0.1:8080"
      assert config.media.webhooks.allow_private == false
    end

    test "s3 storage: private by default, key prefix always ends in a slash" do
      storage = fn extra ->
        base = %{"kind" => "s3", "endpoint" => "http://s3", "bucket" => "b", "access_key_env" => "A", "secret_key_env" => "S"}
        ConfigStore.normalize(%{"media" => %{"storage" => Map.merge(base, extra)}}).media.storage
      end

      # No public URL named: the bucket is private, so URLs are presigned.
      assert storage.(%{}).presign_ttl_s == 3_600
      assert storage.(%{"presign_ttl_s" => 60}).presign_ttl_s == 60
      # A public base URL (public bucket or CDN) means plain URLs...
      assert storage.(%{"public_base_url" => "https://cdn.example/"}).presign_ttl_s == nil
      # ...unless a TTL is asked for explicitly.
      assert storage.(%{"public_base_url" => "https://cdn.example", "presign_ttl_s" => 30}).presign_ttl_s == 30

      assert storage.(%{}).prefix == ""
      assert storage.(%{"prefix" => "outputs"}).prefix == "outputs/"
      assert storage.(%{"prefix" => "/a/b/"}).prefix == "a/b/"
    end

    test "the data-plane snapshot carries rpm and no media section" do
      snapshot = OmnigateControl.Router.snapshot()
      refute Map.has_key?(snapshot, :media)
      assert Enum.all?(snapshot.keys, &is_integer(&1.rpm))
      assert Enum.find(snapshot.keys, &(&1.name == "ratelimited")).rpm == 5
    end
  end
end
