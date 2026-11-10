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

  @optional_callbacks poll: 5, cancel: 5

  alias OmnigateControl.Jobs.Adapters

  @doc "Adapter module for an upstream `kind`, or nil."
  def for_kind("replicate"), do: Adapters.Replicate
  def for_kind("fal"), do: Adapters.Fal
  def for_kind("openai_images"), do: Adapters.OpenAIImages
  def for_kind("elevenlabs"), do: Adapters.ElevenLabs
  def for_kind("gemini"), do: Adapters.Gemini
  def for_kind(_), do: nil

  def kinds, do: ~w(replicate fal openai_images elevenlabs gemini)

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
        _ -> body |> to_string() |> String.slice(0, 200)
      end

    "http_#{status}: #{detail}" |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  def describe({:error, reason}), do: "request_failed: #{inspect(reason)}" |> String.slice(0, 300)

  @doc "429 and 5xx are worth retrying on the same provider job; anything else is final."
  def transient?({:ok, %{status: status}}), do: status == 429 or status >= 500
  def transient?({:error, _}), do: true
end
