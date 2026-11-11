defmodule OmnigateControl.ElevenLabsTest do
  # ElevenLabs beyond speech: the target's "api" setting, what each product
  # is billed for, and what the adapter refuses before it calls anyone. The
  # calls themselves run against the mock in tools/e2e.py.
  use ExUnit.Case, async: true

  alias OmnigateControl.ConfigStore
  alias OmnigateControl.Jobs.Adapter
  alias OmnigateControl.Jobs.Adapters.ElevenLabs

  defp media(target, extra_upstreams \\ []) do
    ConfigStore.normalize(%{
      "media" => %{
        "upstreams" => [%{"name" => "el", "kind" => "elevenlabs", "base_url" => "https://api.elevenlabs.io", "api_key_env" => "EL_KEY"} | extra_upstreams],
        "routes" => [%{"model" => "m", "targets" => [Map.merge(%{"upstream" => "el", "model" => "some-model"}, target)]}]
      }
    }).media
  end

  defp target(media), do: media.routes |> hd() |> Map.fetch!(:targets) |> hd()

  describe "the target's \"api\"" do
    test "is one of the products, and speech when it is left out" do
      assert ElevenLabs.apis() == ~w(speech sound music image video)
      refute Map.has_key?(target(media(%{})), :api)

      for api <- ElevenLabs.apis() do
        assert target(media(%{"api" => api, "price" => %{"per_output_usd" => 0.01}})).api == api
      end

      for bad <- ["transcribe", "", nil, 1, ["sound"]] do
        assert_raise ArgumentError, ~r/"api" on an elevenlabs target must be one of speech, sound, music, image, video/, fn -> media(%{"api" => bad}) end
      end
    end

    test "belongs to elevenlabs targets only" do
      other = [%{"name" => "rep", "kind" => "replicate", "base_url" => "https://api.replicate.com", "api_key_env" => "R"}]

      assert_raise ArgumentError, ~r/"api" is a setting of elevenlabs targets; the target on "rep" is replicate/, fn ->
        media(%{"upstream" => "rep", "api" => "image"}, other)
      end
    end

    test "decides whether a per-second price needs default_seconds" do
      per_second = %{"price" => %{"per_second_usd" => 0.01}}

      # Sound, music and video take a length from the request.
      for api <- ~w(sound music video) do
        assert target(media(Map.put(per_second, "api", api))).price.per_second_usd == 0.01
        assert Adapter.takes_duration?("elevenlabs", %{api: api})
      end

      # Speech and images are never sent one: the price needs a default to apply to.
      for api <- [nil, "speech", "image"] do
        t = if api, do: Map.put(per_second, "api", api), else: per_second
        assert_raise ArgumentError, ~r/is never sent a duration/, fn -> media(t) end
        assert target(media(Map.put(t, "default_seconds", 4))).default_seconds == 4
        refute Adapter.takes_duration?("elevenlabs", if(api, do: %{api: api}, else: %{}))
      end

      # Other kinds answer as before, whatever a target says.
      assert Adapter.takes_duration?("sume", %{api: "image"})
      refute Adapter.takes_duration?("openai_images", %{api: "video"})
    end
  end

  describe "what a job is billed for" do
    test "speech: the characters of text, never seconds" do
      input = %{"text" => "hello there", "voice_id" => "v", "duration" => 9, "prompt" => "not spoken"}
      assert ElevenLabs.billable(input) == %{chars: 11, seconds: 0}
      assert ElevenLabs.billable(input, %{}) == %{chars: 11, seconds: 0}
      assert Adapter.billable(ElevenLabs, input, %{api: "speech"}) == %{chars: 11, seconds: 0}
    end

    test "sound, music and video: the seconds asked for under the gateway's name" do
      assert %{seconds: 2} = Adapter.billable(ElevenLabs, %{"text" => "x", "duration" => 2}, %{api: "sound"})
      assert %{seconds: 12.5} = Adapter.billable(ElevenLabs, %{"prompt" => "x", "duration" => "12.5"}, %{api: "music"})
      assert %{seconds: 4, chars: 5} = Adapter.billable(ElevenLabs, %{"prompt" => "steam", "duration" => 4}, %{api: "video"})
      # The provider's own names are not sent, so they are not billed either.
      assert %{seconds: 0} = Adapter.billable(ElevenLabs, %{"text" => "x", "duration_seconds" => 30}, %{api: "sound"})
      assert %{seconds: 0} = Adapter.billable(ElevenLabs, %{"prompt" => "x", "duration_secs" => 60}, %{api: "video"})
      assert %{seconds: 0} = Adapter.billable(ElevenLabs, %{"prompt" => "x", "music_length_ms" => 60_000}, %{api: "music"})
    end

    test "music from a plan: the sum of its sections or chunks" do
      sections = %{"sections" => [%{"duration_ms" => 3000}, %{"duration_ms" => 4500}, %{"duration_ms" => "x"}, %{}]}
      assert %{seconds: 7.5} = Adapter.billable(ElevenLabs, %{"composition_plan" => sections}, %{api: "music"})
      chunks = %{"chunks" => [%{"duration_ms" => 10_000}, %{"duration_ms" => -5}]}
      assert %{seconds: 10.0} = Adapter.billable(ElevenLabs, %{"composition_plan" => chunks, "duration" => 99}, %{api: "music"})
    end

    test "images: per output, no seconds" do
      assert Adapter.billable(ElevenLabs, %{"prompt" => "a cup", "duration" => 5}, %{api: "image"}) == %{chars: 5, seconds: 0}
    end

    test "an adapter without products is asked as before" do
      assert Adapter.billable(OmnigateControl.Jobs.Adapters.Sume, %{"prompt" => "abc", "duration" => 3}, %{api: "ignored"}) == %{chars: 3, seconds: 3}
    end
  end

  describe "refused before any call" do
    # (An address nothing listens on: a request that did go out would fail differently.)
    @up %{base_url: "http://127.0.0.1:9", name: "el"}
    defp ctx(api), do: %{api_key: "k", timeout_ms: 1_000, api: api}

    test "sound" do
      assert {:error, "invalid_input: text is required" <> _} = ElevenLabs.submit(@up, "m", %{}, ctx("sound"))
      assert {:error, "invalid_input: text must be" <> _} = ElevenLabs.submit(@up, "m", %{"text" => ""}, ctx("sound"))

      assert {:error, "invalid_input: duration must be a number of seconds from 0.5 to 30"} =
               ElevenLabs.submit(@up, "m", %{"text" => "x", "duration" => 31}, ctx("sound"))

      assert {:error, "invalid_input: duration must be" <> _} = ElevenLabs.submit(@up, "m", %{"text" => "x", "duration" => "soon"}, ctx("sound"))
      assert {:error, "invalid_input: output_format" <> _} = ElevenLabs.submit(@up, "m", %{"text" => "x", "output_format" => "mp3&x=1"}, ctx("sound"))
    end

    test "music" do
      plan = %{"sections" => []}
      assert {:error, "invalid_input: send prompt" <> _} = ElevenLabs.submit(@up, "m", %{}, ctx("music"))
      assert {:error, "invalid_input: send prompt" <> _} = ElevenLabs.submit(@up, "m", %{"prompt" => "x", "composition_plan" => plan}, ctx("music"))

      assert {:error, "invalid_input: duration must be a number of seconds from 3 to 600"} =
               ElevenLabs.submit(@up, "m", %{"prompt" => "x", "duration" => 2}, ctx("music"))

      assert {:error, "invalid_input: duration goes with a prompt" <> _} =
               ElevenLabs.submit(@up, "m", %{"composition_plan" => plan, "duration" => 30}, ctx("music"))
    end

    test "image and video" do
      assert {:error, "invalid_input: prompt is required"} = ElevenLabs.submit(@up, "m", %{}, ctx("image"))
      assert {:error, "invalid_input: prompt must be" <> _} = ElevenLabs.submit(@up, "m", %{"prompt" => 7}, ctx("video"))
      assert {:error, "invalid_input: duration must be a whole number" <> _} = ElevenLabs.submit(@up, "m", %{"prompt" => "x", "duration" => 4.5}, ctx("video"))
      assert {:error, "invalid_input: duration must be a number" <> _} = ElevenLabs.submit(@up, "m", %{"prompt" => "x", "duration" => 0}, ctx("video"))
    end

    test "speech is as it was, and an unknown product is not guessed" do
      assert {:error, "invalid_input: text and voice_id are required"} = ElevenLabs.submit(@up, "m", %{"text" => "x"}, ctx(nil))

      assert {:error, "invalid_input: text and voice_id are required"} =
               ElevenLabs.submit(@up, "m", %{"text" => "x", "voice_id" => "../x"}, %{api_key: "k", timeout_ms: 1_000})

      assert {:error, "elevenlabs_api_not_set" <> _} = ElevenLabs.submit(@up, "m", %{"text" => "x"}, ctx("transcribe"))
    end

    test "a generation has no cancel at the provider; only image and video jobs are asked about" do
      assert ElevenLabs.cancel(@up, "m", "gen_1", %{"api" => "video"}, ctx("video")) == :not_canceled
      assert {:error, "elevenlabs_unexpected_state" <> _} = ElevenLabs.poll(@up, "m", "x", %{}, ctx("sound"))
    end
  end
end
