defmodule OmnigateControl.Jobs.Adapter do
  @moduledoc """
  One provider API style.

  An adapter turns a job's `input` into provider calls and reports outputs
  as things the gateway can fetch and re-host:

    * `{:url, url}` / `{:url, url, content_type}` — a (usually short-lived) provider URL
    * `{:binary, bytes, content_type}` — bytes returned inline

  Async providers return `{:async, provider_id, state}` from `submit/4`;
  `provider_id` and `state` are persisted so that a restarted gateway resumes
  polling instead of submitting (and paying) again.
  """

  @type upstream :: %{name: String.t(), kind: String.t(), base_url: String.t(), api_key_env: String.t()}
  @type output :: {:url, String.t()} | {:url, String.t(), String.t() | nil} | {:binary, binary(), String.t()}
  @type ctx :: %{api_key: String.t(), timeout_ms: pos_integer()}

  @callback submit(upstream(), target_model :: String.t(), input :: map(), ctx()) ::
              {:async, provider_id :: String.t(), state :: map()} | {:done, [output()]} | {:error, String.t()}

  @callback poll(upstream(), target_model :: String.t(), provider_id :: String.t(), state :: map(), ctx()) ::
              :pending | {:done, [output()]} | {:error, String.t()} | {:transient, String.t()}

  @callback cancel(upstream(), target_model :: String.t(), provider_id :: String.t(), state :: map(), ctx()) :: :ok

  @typedoc "What a job is billed for: characters of text and seconds of media the adapter asks the provider for."
  @type billable :: %{chars: non_neg_integer(), seconds: number()}

  @doc """
  The billable quantities in the request this adapter sends for `input`.

  Pricing must follow what goes to the provider, not what the client labelled:
  each adapter counts the text it actually forwards and the duration it
  actually requests. It is a pure function of `input` (built from the same
  code as the request), so it gives the same answer when a job is resumed
  after a restart.
  """
  @callback billable(input :: map()) :: billable()

  @optional_callbacks poll: 5, cancel: 5

  alias OmnigateControl.Jobs.Adapters
  alias OmnigateControl.Text

  @doc """
  Characters in the string values of `fields` in `input`, added up. Adapters
  that forward the whole input cannot know which of several text fields the
  provider will read, so every one that is sent is counted.
  """
  def chars(input, fields) when is_map(input) do
    Enum.reduce(fields, 0, fn field, sum ->
      case input[field] do
        text when is_binary(text) -> sum + String.length(text)
        _ -> sum
      end
    end)
  end

  @doc "Characters of every string found under a `\"text\"` key anywhere inside `term`, plus `term` itself when it is a string."
  def text_chars(text) when is_binary(text), do: String.length(text)
  def text_chars(list) when is_list(list), do: list |> Enum.map(&text_chars_in/1) |> Enum.sum()
  def text_chars(map) when is_map(map), do: text_chars_in(map)
  def text_chars(_), do: 0

  defp text_chars_in(map) when is_map(map) do
    Enum.reduce(map, 0, fn
      {"text", text}, sum when is_binary(text) -> sum + String.length(text)
      {_key, value}, sum when is_map(value) or is_list(value) -> sum + text_chars_in(value)
      _, sum -> sum
    end)
  end

  defp text_chars_in(list) when is_list(list), do: list |> Enum.map(&text_chars_in/1) |> Enum.sum()
  defp text_chars_in(_), do: 0

  @doc """
  Does a provider of this kind take a duration from the request? The others
  (images, speech) never send one, so a per-second price on them can only
  ever apply to the target's `default_seconds`; the config loader insists
  that one is set.
  """
  def takes_duration?(kind), do: kind in ~w(replicate fal xai_video)

  @doc """
  Seconds requested by `input`: the largest of the given fields, never below
  zero. Values are numbers, numeric strings (some providers take `"5"`) or a
  number with an `s` after it (`"5s"`, which others take).
  """
  def seconds(input, fields) when is_map(input) do
    fields |> Enum.map(&quantity(input[&1])) |> Enum.max(fn -> 0 end) |> max(0)
  end

  @doc "A number, a fully numeric string, or `\"<number>s\"` as a number; anything else is 0."
  def quantity(value) do
    case seconds_value(value) do
      {:ok, n} -> n
      :error -> 0
    end
  end

  @doc """
  `{:ok, seconds}` for a duration this gateway can price: a number of 0 or
  more, the same as a string (`"5"`, `"2.5"`), or with a trailing `s`
  (`"5s"`). `:error` for anything else, a negative number included.
  """
  def seconds_value(n) when is_number(n) and n >= 0 and n <= 1.0e9, do: {:ok, n}

  def seconds_value(s) when is_binary(s) and byte_size(s) <= 32 do
    case Float.parse(String.trim(s)) do
      {f, rest} when rest in ["", "s"] and f >= 0 and f <= 1.0e9 -> {:ok, f}
      _ -> :error
    end
  end

  def seconds_value(_), do: :error

  @doc "Adapter module for an upstream `kind`, or nil."
  def for_kind("replicate"), do: Adapters.Replicate
  def for_kind("fal"), do: Adapters.Fal
  def for_kind("openai_images"), do: Adapters.OpenAIImages
  def for_kind("elevenlabs"), do: Adapters.ElevenLabs
  def for_kind("gemini"), do: Adapters.Gemini
  def for_kind("xai_video"), do: Adapters.XaiVideo
  def for_kind("gemini_interactions"), do: Adapters.GeminiInteractions
  def for_kind(_), do: nil

  def kinds, do: ~w(replicate fal openai_images elevenlabs gemini xai_video gemini_interactions)

  # -- helpers shared by adapters -------------------------------------------

  @doc "Decode a JSON body, tolerating junk."
  def decode(body) do
    case JSON.decode(body) do
      {:ok, v} -> v
      _ -> %{}
    end
  end

  @doc "Short, single-line description of a failed HTTP exchange."
  def describe({:ok, %{status: status, body: body}}) do
    detail =
      case decode(body) do
        %{"detail" => d} when is_binary(d) -> d
        %{"error" => %{"message" => m}} when is_binary(m) -> m
        %{"error" => e} when is_binary(e) -> e
        %{"title" => t} when is_binary(t) -> t
        _ -> body |> to_string() |> binary_part(0, min(byte_size(body), 400))
      end

    # A provider's error body is arbitrary bytes: it becomes one line of
    # valid UTF-8 before it goes anywhere near a log, the job record or JSON.
    Text.line("http_#{status}: #{detail}", 300)
  end

  def describe({:error, reason}), do: Text.line("request_failed: #{inspect(reason)}", 300)

  @doc """
  Most bytes an adapter reads from a provider answer that carries the media
  inline (base64 in JSON, or raw bytes). The runner sets it from
  `media.max_output_bytes`; base64 is a third larger than what it encodes.
  """
  def inline_cap(ctx), do: Map.get(ctx, :max_inline_bytes, 64 * 1024 * 1024)

  @doc "429 and 5xx are worth retrying on the same provider job; anything else is final."
  def transient?({:ok, %{status: status}}), do: status == 429 or status >= 500
  def transient?({:error, _}), do: true
end
