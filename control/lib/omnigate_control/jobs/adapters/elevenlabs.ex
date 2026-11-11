defmodule OmnigateControl.Jobs.Adapters.ElevenLabs do
  @moduledoc """
  ElevenLabs (https://elevenlabs.io/docs/api-reference): speech, sound
  effects, music, and the image and video models it relays. All with an
  `xi-api-key` header.

  Which product a target uses is the target's `"api"` setting, never guessed
  from a model's name:

  | `"api"` | Request | Answer |
  |---|---|---|
  | `"speech"` (the default) | `POST /v1/text-to-speech/{voice_id}?output_format=...` | audio bytes |
  | `"sound"` | `POST /v1/sound-generation?output_format=...` | audio bytes |
  | `"music"` | `POST /v1/music[?output_format=...]` | audio bytes |
  | `"image"` | `POST /v1/flows/image`, then `GET /v1/flows/image/{id}` until it ends | a signed URL |
  | `"video"` | `POST /v1/flows/video`, then `GET /v1/flows/video/{id}` until it ends | a signed URL |

  The target's model is sent as `model_id`.

  ## Job `input`

    * **speech**: `text` (required), `voice_id` (required), optional
      `output_format` (default `mp3_44100_128`); every other field is passed
      through in the body.
    * **sound**: `text` (required: what the effect is), optional `duration`
      (seconds, 0.5 to 30; the provider picks one when it is left out),
      `loop`, `prompt_influence`, `output_format`.
    * **music**: `prompt`, or `composition_plan` (ElevenLabs' own structure),
      never both; with a prompt an optional `duration` (seconds, 3 to 600);
      optional `seed`, `force_instrumental`, `finetune_id`,
      `respect_sections_durations`, `sign_with_c2pa`, `output_format`.
    * **image** and **video**: `prompt` (required) and whatever the model
      takes (`aspect_ratio`, `resolution`, `images`, `seed`, ...), passed
      through; for video an optional `duration` (whole seconds).

  `duration` is the gateway's name for the length, in seconds, for every
  product: it is what `max_seconds` and a per-second price apply to. It is
  sent as the provider's own field (`duration_seconds`, `music_length_ms`,
  `duration_secs`), and those names are not taken from the input, so that a
  request cannot ask the provider for more than it told the gateway.

  Never forwarded: `webhook` (image and video: ElevenLabs would call the
  workspace's own webhooks; the gateway has its own) and
  `store_for_inpainting` (music: it keeps the song at the provider).

  ## Image and video jobs

  A generation is `pending`, `generating`, `completed` (with `content_url`,
  a signed link good for about an hour, and `content_mime_type`) or `failed`
  (with `failure_reason` and `error_message`; ElevenLabs does not charge a
  failed generation). The output is downloaded and stored like any other
  job's. ElevenLabs documents no way to cancel a generation: `cancel/5`
  answers `:not_canceled`, so a canceled job's generation runs on and is
  billed if it completes.

  ## Errors

  ElevenLabs' error object is `{"detail": {"code" | "status", "message"}}`.
  For the products added here a failure is reported as
  `elevenlabs_<code>: <message>` (`elevenlabs_paid_plan_required: This
  endpoint requires a Pro plan or above.`), a request the provider's
  validation refuses as `elevenlabs_validation_error: <field>: <what is
  wrong>`, and a failed generation as
  `elevenlabs_<failure_reason>: <error_message>`.

  ## What has been checked

  Speech against the real service with `eleven_flash_v2_5` (November 2026;
  again on 11 November 2026 at commit 809b96f). The other products were
  written from ElevenLabs' public documentation (read 11 November 2026);
  what has run against the real service since is in docs/providers.md.
  """
  @behaviour OmnigateControl.Jobs.Adapter

  import OmnigateControl.Jobs.Adapter, only: [decode: 1, describe: 1]
  alias OmnigateControl.Http
  alias OmnigateControl.Jobs.Adapter
  alias OmnigateControl.Text

  @apis ~w(speech sound music image video)
  # The provider's own names for a length; see the moduledoc.
  @native_durations ~w(duration_seconds duration_secs music_length_ms)

  @doc "The values a target's `\"api\"` may have."
  def apis, do: @apis

  @doc "Does this product take a length from the request?"
  def takes_duration?(api), do: api in ~w(sound music video)

  # -- submit ------------------------------------------------------------------

  @impl true
  def submit(up, model, input, ctx) do
    case Map.get(ctx, :api) || "speech" do
      "speech" -> speech(up, model, input, ctx)
      "sound" -> sound(up, model, input, ctx)
      "music" -> music(up, model, input, ctx)
      api when api in ["image", "video"] -> generation(up, model, input, ctx, api)
      other -> {:error, "elevenlabs_api_not_set: the target's \"api\" is #{Text.line(inspect(other), 40)}"}
    end
  end

  defp speech(up, model, input, ctx) do
    with text when is_binary(text) and text != "" <- input["text"],
         voice when is_binary(voice) and voice != "" <- input["voice_id"],
         true <- voice =~ ~r/\A[A-Za-z0-9_-]+\z/ do
      format = input["output_format"] || "mp3_44100_128"
      url = "#{up.base_url}/v1/text-to-speech/#{voice}?" <> URI.encode_query(%{"output_format" => format})
      body = input |> Map.drop(["voice_id", "output_format"]) |> Map.put("model_id", model)

      case Http.request(:post, url, [{"xi-api-key", ctx.api_key}, {"accept", "*/*"}], JSON.encode!(body),
             timeout: ctx.timeout_ms,
             max_body: Adapter.inline_cap(ctx)
           ) do
        {:ok, %{status: 200, body: audio, headers: headers}} when byte_size(audio) > 0 ->
          {:done, [{:binary, audio, headers["content-type"] || content_type(format)}]}

        {:ok, %{status: 200}} ->
          {:error, "empty audio response"}

        other ->
          {:error, describe(other)}
      end
    else
      _ -> {:error, "invalid_input: text and voice_id are required"}
    end
  end

  defp sound(up, model, input, ctx) do
    with text when is_binary(text) and text != "" <- input["text"] || :no_text,
         {:ok, seconds} <- duration(input, 0.5, 30),
         {:ok, format} <- output_format(input, "mp3_44100_128") do
      body =
        input
        |> Map.take(~w(text loop prompt_influence))
        |> Map.put("model_id", model)
        |> then(&if(seconds, do: Map.put(&1, "duration_seconds", seconds), else: &1))

      audio(up, "/v1/sound-generation?" <> URI.encode_query(%{"output_format" => format}), body, format, ctx)
    else
      :no_text -> {:error, "invalid_input: text is required (what the sound is)"}
      {:error, message} -> {:error, "invalid_input: " <> message}
      _ -> {:error, "invalid_input: text must be a non-empty string"}
    end
  end

  defp music(up, model, input, ctx) do
    prompt = input["prompt"]
    plan = input["composition_plan"]

    with :ok <- one_of(prompt, plan),
         {:ok, seconds} <- duration(input, 3, 600),
         :ok <- if(seconds && plan, do: {:error, "duration goes with a prompt; a composition_plan carries its own lengths"}, else: :ok),
         {:ok, format} <- output_format(input, nil) do
      body =
        input
        |> Map.take(~w(prompt composition_plan seed force_instrumental finetune_id respect_sections_durations sign_with_c2pa))
        |> Map.put("model_id", model)
        |> then(&if(seconds, do: Map.put(&1, "music_length_ms", round(seconds * 1000)), else: &1))

      # Without a format ElevenLabs picks the one that suits the model.
      query = if format, do: "?" <> URI.encode_query(%{"output_format" => format}), else: ""
      audio(up, "/v1/music" <> query, body, format || "mp3", ctx)
    else
      {:error, message} -> {:error, "invalid_input: " <> message}
    end
  end

  defp one_of(prompt, nil) when is_binary(prompt) and prompt != "", do: :ok
  defp one_of(nil, %{} = _plan), do: :ok
  defp one_of(_, _), do: {:error, "send prompt (a text) or composition_plan (an object), one of the two"}

  # One synchronous call that answers with the audio itself.
  defp audio(up, path, body, format, ctx) do
    case Http.request(:post, up.base_url <> path, headers(ctx, "*/*"), JSON.encode!(body), timeout: ctx.timeout_ms, max_body: Adapter.inline_cap(ctx)) do
      {:ok, %{status: 200, body: bytes, headers: headers}} when byte_size(bytes) > 0 ->
        {:done, [{:binary, bytes, headers["content-type"] || content_type(format)}]}

      {:ok, %{status: 200}} ->
        {:error, "elevenlabs_empty_response: the provider answered without audio"}

      other ->
        {:error, failure(other)}
    end
  end

  # An image or a video: started here, asked about in `poll/5`.
  defp generation(up, model, input, ctx, api) do
    with prompt when is_binary(prompt) and prompt != "" <- input["prompt"] || :no_prompt,
         {:ok, seconds} <- if(api == "video", do: duration(input, 1, 3600), else: {:ok, nil}),
         :ok <- if(seconds && seconds != trunc(seconds), do: {:error, "duration must be a whole number of seconds for a video"}, else: :ok) do
      body =
        input
        |> Map.drop(["webhook", "duration", "model_id" | @native_durations])
        |> Map.put("model_id", model)
        |> then(&if(seconds, do: Map.put(&1, "duration_secs", trunc(seconds)), else: &1))

      case Http.request(:post, "#{up.base_url}/v1/flows/#{api}", headers(ctx, "application/json"), JSON.encode!(body), timeout: 60_000) do
        {:ok, %{status: status, body: resp}} when status in 200..299 ->
          case decode(resp) do
            %{"id" => id} when is_binary(id) and id != "" -> {:async, id, %{"api" => api}}
            _ -> {:error, "elevenlabs_unexpected_response: the answer names no generation"}
          end

        other ->
          {:error, failure(other)}
      end
    else
      :no_prompt -> {:error, "invalid_input: prompt is required"}
      {:error, message} -> {:error, "invalid_input: " <> message}
      _ -> {:error, "invalid_input: prompt must be a non-empty string"}
    end
  end

  # -- poll, cancel --------------------------------------------------------------

  @impl true
  def poll(up, _model, id, state, ctx) do
    api = state["api"] || Map.get(ctx, :api)

    if api in ["image", "video"] do
      url = "#{up.base_url}/v1/flows/#{api}/#{URI.encode(id, &URI.char_unreserved?/1)}"

      case Http.request(:get, url, headers(ctx, "application/json")) do
        {:ok, %{status: 200, body: body}} -> generation_state(decode(body))
        {:ok, %{status: status}} = answer when status == 429 or status >= 500 -> {:transient, failure(answer)}
        {:ok, _} = answer -> {:error, failure(answer)}
        other -> {:transient, failure(other)}
      end
    else
      {:error, "elevenlabs_unexpected_state: a #{Text.line(inspect(api), 20)} job has nothing to ask about"}
    end
  end

  defp generation_state(%{"status" => "completed", "content_url" => url} = done) when is_binary(url) and url != "" do
    {:done, [{:url, url, if(is_binary(done["content_mime_type"]), do: done["content_mime_type"])}]}
  end

  defp generation_state(%{"status" => "completed"}), do: {:error, "elevenlabs_no_output: the completed generation has no content_url"}

  defp generation_state(%{"status" => "failed"} = failed) do
    reason = word(failed["failure_reason"]) || "generation_failed"
    {:error, Text.line("elevenlabs_#{reason}: #{message(failed["error_message"])}", 300)}
  end

  # `pending`, `generating`, and whatever state may be added between them:
  # the route's timeout is what ends the wait.
  defp generation_state(_), do: :pending

  # ElevenLabs documents no cancel for a generation: it runs on, and the
  # runner keeps asking how it ended.
  @impl true
  def cancel(_up, _model, _id, _state, _ctx), do: :not_canceled

  # -- billing -------------------------------------------------------------------

  # Without a target (the behaviour's own callback): speech.
  @impl true
  def billable(input), do: billable(input, %{})

  @doc """
  What a job on `target` is billed for: characters of `text` for speech
  (nothing else in the input is spoken); for the others the seconds asked
  for, as sent to the provider (for music with a composition plan, the sum
  of its sections), and the characters of the prompt.
  """
  def billable(input, target) do
    case Map.get(target, :api) || "speech" do
      "speech" ->
        %{chars: Adapter.chars(input, ~w(text)), seconds: 0}

      "sound" ->
        %{chars: Adapter.chars(input, ~w(text)), seconds: requested(input)}

      "music" ->
        %{
          chars: Adapter.chars(input, ~w(prompt)),
          seconds: if(is_map(input["composition_plan"]), do: plan_seconds(input["composition_plan"]), else: requested(input))
        }

      "video" ->
        %{chars: Adapter.chars(input, ~w(prompt)), seconds: requested(input)}

      _ ->
        %{chars: Adapter.chars(input, ~w(prompt)), seconds: 0}
    end
  end

  defp requested(input), do: Adapter.seconds(input, ~w(duration))

  # A plan's length: its sections (`music_v1`) or chunks (later models).
  defp plan_seconds(plan) do
    parts = List.wrap(plan["sections"]) ++ List.wrap(plan["chunks"])
    ms = for %{"duration_ms" => d} <- parts, is_number(d) and d > 0 and d <= 1.0e9, do: d
    Enum.sum(ms) / 1000
  end

  # -- pieces --------------------------------------------------------------------

  # `input.duration` within the product's limits, or nil when it is absent.
  defp duration(input, min, max) do
    case Map.fetch(input, "duration") do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        case Adapter.seconds_value(value) do
          {:ok, s} when s >= min and s <= max -> {:ok, s}
          _ -> {:error, "duration must be a number of seconds from #{min} to #{max}"}
        end
    end
  end

  defp output_format(input, default) do
    case input["output_format"] do
      nil ->
        {:ok, default}

      format when is_binary(format) ->
        if format =~ ~r/\A[a-z0-9_]{1,32}\z/, do: {:ok, format}, else: {:error, "output_format is not one of the provider's formats"}

      _ ->
        {:error, "output_format must be a string"}
    end
  end

  defp headers(ctx, accept), do: [{"xi-api-key", ctx.api_key}, {"content-type", "application/json"}, {"accept", accept}]

  # `elevenlabs_<code>: <message>`, from the provider's error object. A
  # request that fails validation is answered with a list instead, one entry
  # per field: `elevenlabs_validation_error: duration_secs: Input should be
  # greater than or equal to 4`.
  defp failure({:ok, %{status: status, body: body}}) do
    case decode(body) do
      %{"detail" => %{} = detail} ->
        case word(detail["code"]) || word(detail["status"]) do
          nil -> raw_failure(status, body)
          code -> Text.line("elevenlabs_#{code}: #{message(detail["message"])}", 300)
        end

      %{"detail" => [_ | _] = fields} ->
        words =
          for %{"msg" => msg} = field when is_binary(msg) <- Enum.take(fields, 4) do
            case field["loc"] |> List.wrap() |> List.last() do
              name when is_binary(name) -> "#{name}: #{msg}"
              _ -> msg
            end
          end

        if words == [], do: raw_failure(status, body), else: Text.line("elevenlabs_validation_error: #{Enum.join(words, "; ")}", 300)

      _ ->
        raw_failure(status, body)
    end
  end

  defp failure({:error, reason}), do: Text.line("elevenlabs_request_failed: #{inspect(reason)}", 300)

  defp raw_failure(status, body), do: Text.line("elevenlabs_http_#{status}: #{binary_part(body, 0, min(byte_size(body), 200))}", 300)

  defp message(text) when is_binary(text), do: String.slice(text, 0, 240)
  defp message(_), do: "no detail"

  # One of the provider's identifiers, if it is shaped like one.
  defp word(value) when is_binary(value) do
    if value =~ ~r/\A[a-z0-9_]{1,40}\z/, do: value
  end

  defp word(_), do: nil

  defp content_type("mp3" <> _), do: "audio/mpeg"
  defp content_type("pcm" <> _), do: "audio/pcm"
  defp content_type("wav" <> _), do: "audio/wav"
  defp content_type("ulaw" <> _), do: "audio/basic"
  defp content_type("alaw" <> _), do: "audio/basic"
  defp content_type("opus" <> _), do: "audio/ogg"
  defp content_type(_), do: "application/octet-stream"
end
