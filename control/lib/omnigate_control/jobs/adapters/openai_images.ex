defmodule OmnigateControl.Jobs.Adapters.OpenAIImages do
  @moduledoc """
  OpenAI-style image generation: one synchronous
  `POST /v1/images/generations`, answering with `data[]` entries holding
  either `b64_json` or a `url`.

  The job's `input` is sent as the request body with `model` set to the
  route target's model.

  Checked against the real service with `gpt-image-1-mini` (November 2026).
  """
  @behaviour OmnigateControl.Jobs.Adapter

  import OmnigateControl.Jobs.Adapter, only: [decode: 1, describe: 1]
  alias OmnigateControl.Http

  @impl true
  def submit(up, model, input, ctx) do
    body = Map.put(input, "model", model)

    case Http.request(:post, "#{up.base_url}/v1/images/generations", [{"authorization", "Bearer #{ctx.api_key}"}], JSON.encode!(body), timeout: ctx.timeout_ms) do
      {:ok, %{status: 200, body: resp}} ->
        content_type = content_type(input["output_format"])

        outputs =
          for item <- List.wrap(decode(resp)["data"]), out = output(item, content_type), do: out

        {:done, outputs}

      other ->
        {:error, describe(other)}
    end
  end

  defp output(%{"b64_json" => b64}, content_type) when is_binary(b64) do
    case Base.decode64(b64, ignore: :whitespace) do
      {:ok, bytes} -> {:binary, bytes, content_type}
      :error -> nil
    end
  end

  defp output(%{"url" => url}, _content_type) when is_binary(url), do: {:url, url}
  defp output(_, _), do: nil

  defp content_type("jpeg"), do: "image/jpeg"
  defp content_type("webp"), do: "image/webp"
  defp content_type(_), do: "image/png"
end
