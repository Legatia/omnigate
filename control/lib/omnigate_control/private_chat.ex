defmodule OmnigateControl.PrivateChat do
  @moduledoc """
  The dashboard's "Private chat" page: a chat that shows, next to each
  answer, what privacy mode sent to the provider and what is known about the
  machine that answered.

  It adds no way around the gateway. A message typed on the page is sent by
  this process to the data plane's public port with an ordinary gateway key,
  like any client would, twice:

    1. with `x-omnigate-dry-run: privacy`, which makes the data plane answer
       with the request as privacy mode left it and send nothing anywhere;
    2. for real, with the `x-omnigate-privacy` header the page's switches
       ask for.

  So the placeholders shown are the ones the data plane's own redaction
  made of this message, and the refusal shown for a model without a
  verified attestation is the data plane's own.

  The key is a managed key named `#{inspect("private-chat")}`, created on first use. Its
  secret is held in this process's memory and nowhere else; after a restart
  the key is rotated to get a new one. It is an ordinary key: it shows in
  the key list, its usage is billed and counted, and it can be given a
  budget or be disabled there.

  Nothing of a conversation is kept here: the page holds the history and
  sends all of it with each message, every request goes out with
  `no-store`, and the messages are never logged.
  """
  alias OmnigateControl.{Attestation, ConfigStore, Http, Keys}

  @key_name "private-chat"
  @max_messages 40
  @max_chars 32_000
  @timeout 120_000

  @doc "The name of the gateway key the page uses."
  def key_name, do: @key_name

  @doc "Where this process reaches the data plane: `OMNIGATE_GATEWAY_URL`, else the config's public base URL."
  def gateway_url do
    case System.get_env("OMNIGATE_GATEWAY_URL") do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> ConfigStore.get().media.public_base_url
    end
  end

  @doc """
  What the page shows before anything is typed: the text models, and for
  each of its targets whether the upstream is attested, the verdict if so,
  and whether a provider key is set in this process's environment (the data
  plane reads its own environment; on one machine they are the same).
  """
  def state do
    config = ConfigStore.get()
    upstreams = Map.new(config.upstreams, &{&1.name, &1})
    now = System.os_time(:second)

    %{
      gateway_url: gateway_url(),
      key: @key_name,
      models:
        for route <- config.routes do
          %{
            model: route.model,
            targets:
              for target <- route.targets, up = upstreams[target.upstream] do
                entry = Attestation.Manager.status(target.upstream, target.model)

                %{
                  upstream: target.upstream,
                  model: target.model,
                  host: URI.parse(up.base_url).host,
                  attested: is_map(Map.get(up, :attestation)),
                  key_present: System.get_env(up.api_key_env) not in [nil, ""],
                  key_env: up.api_key_env,
                  attestation: entry && Attestation.view(entry, now)
                }
              end
          }
        end
    }
  end

  @doc """
  Send one turn. `params`: `"model"` (a text route), `"messages"` (the whole
  conversation: `[%{"role" => "user" | "assistant", "content" => text}]`),
  `"redact"` and `"attested"` (booleans, the page's switches).

  `{:ok, %{dry_run: ..., response: ...}}`, or `{:error, status, code, message}`.
  """
  def send_turn(params) when is_map(params) do
    with {:ok, model} <- model(params["model"]),
         {:ok, messages} <- messages(params["messages"]),
         {:ok, secret} <- secret() do
      body = JSON.encode!(%{model: model, messages: messages})

      privacy =
        ["no-store"] ++ if(params["redact"] == true, do: ["redact", "unlink"], else: []) ++ if(params["attested"] == true, do: ["attested"], else: [])

      headers = [{"authorization", "Bearer " <> secret}, {"content-type", "application/json"}, {"x-omnigate-privacy", Enum.join(privacy, ", ")}]
      url = gateway_url() <> "/v1/chat/completions"

      with {:ok, dry} <- call(url, [{"x-omnigate-dry-run", "privacy"} | headers], body, 12),
           {:ok, real} <- call(url, headers, body, 2) do
        {:ok, %{asked: Enum.join(privacy, ", "), dry_run: dry_view(dry), response: response_view(real)}}
      end
    end
  end

  def send_turn(_), do: {:error, 400, "invalid_request", "expected a JSON object"}

  # ---- The request ---------------------------------------------------------

  defp model(name) when is_binary(name) do
    if Enum.any?(ConfigStore.get().routes, &(&1.model == name)), do: {:ok, name}, else: {:error, 400, "model_not_found", "no text route with this name"}
  end

  defp model(_), do: {:error, 400, "invalid_request", "\"model\" must be the name of a text route"}

  defp messages(list) when is_list(list) and list != [] and length(list) <= @max_messages do
    ok = Enum.all?(list, &match?(%{"role" => role, "content" => content} when role in ["user", "assistant"] and is_binary(content), &1))
    size = if ok, do: list |> Enum.map(&String.length(&1["content"])) |> Enum.sum(), else: 0

    cond do
      not ok -> {:error, 400, "invalid_request", "each message needs a \"role\" (user or assistant) and a text \"content\""}
      size > @max_chars -> {:error, 400, "invalid_request", "the conversation is longer than this page sends (#{@max_chars} characters); start a new one"}
      true -> {:ok, Enum.map(list, &Map.take(&1, ["role", "content"]))}
    end
  end

  defp messages(_), do: {:error, 400, "invalid_request", "\"messages\" must be a list of 1 to #{@max_messages} messages"}

  # ---- The key -------------------------------------------------------------

  defp secret do
    case :persistent_term.get({__MODULE__, :secret}, nil) do
      nil -> new_secret()
      secret -> {:ok, secret}
    end
  end

  # A key's secret is shown once, when it is made. After a restart this
  # process no longer has it, and rotating the key is how to get another.
  defp new_secret do
    result =
      case Keys.find(@key_name) do
        nil -> Keys.create(%{"name" => @key_name, "rpm" => 120})
        _ -> Keys.rotate(@key_name)
      end

    case result do
      {:ok, _key, raw} ->
        :persistent_term.put({__MODULE__, :secret}, raw)
        {:ok, raw}

      {:error, _status, _type, message} ->
        {:error, 409, "private_chat_key_unavailable",
         "the page needs a managed key named #{inspect(@key_name)} and could not create or rotate it: #{message} " <>
           "(a key of that name in the config file is not managed; rename it)"}
    end
  end

  # ---- The call ------------------------------------------------------------

  # A key created a moment ago is unknown to the data plane until its next
  # config poll: its own 401 means "ask again shortly", a few times. (A 401
  # that a provider gave, for lack of a provider key, carries the upstream's
  # name and is an answer like any other.)
  defp call(url, headers, body, retries) do
    case Http.request(:post, url, headers, body, timeout: @timeout, max_body: 2 * 1024 * 1024) do
      {:ok, %{status: 401, headers: %{"x-omnigate-upstream" => _}} = response} ->
        {:ok, response}

      {:ok, %{status: 401}} when retries > 0 ->
        Process.sleep(500)
        call(url, headers, body, retries - 1)

      # Still unknown: the secret held here is no longer the key's (it was
      # rotated or deleted in the key list). Forget it; the next message
      # makes a new one.
      {:ok, %{status: 401}} ->
        :persistent_term.erase({__MODULE__, :secret})

        {:error, 502, "private_chat_key_unavailable",
         "the data plane does not know the page's key yet (or it was changed in the key list); send the message again"}

      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, 502, "gateway_unreachable",
         "the data plane did not answer at #{gateway_url()} (#{OmnigateControl.Text.line(inspect(reason), 120)}). " <>
           "Is it running? OMNIGATE_GATEWAY_URL sets where the control plane reaches it."}
    end
  end

  defp dry_view(%{status: 200, body: body}) do
    case JSON.decode(body) do
      {:ok, %{"object" => "omnigate.privacy_dry_run"} = dry} ->
        %{ok: true, body: dry["body"], replaced: dry["replaced"] || %{}, protections: dry["protections"] || "", attested_only: dry["attested_only"] == true}

      _ ->
        %{ok: false, error: "the data plane did not answer the dry run in the expected form (is it an older build?)"}
    end
  end

  defp dry_view(%{status: status, body: body}), do: %{ok: false, status: status, error: error_of(body).message}

  defp response_view(%{status: status, headers: headers, body: body}) do
    base = %{
      status: status,
      upstream: headers["x-omnigate-upstream"],
      attempts: headers["x-omnigate-attempts"],
      attestation: headers["x-omnigate-attestation"],
      privacy: headers["x-omnigate-privacy"],
      request_id: headers["x-omnigate-request-id"]
    }

    case {status, JSON.decode(body)} do
      {200, {:ok, %{"choices" => [%{"message" => %{"content" => text}} | _]} = answer}} when is_binary(text) ->
        Map.merge(base, %{ok: true, text: text, model: answer["model"], usage: Map.take(answer["usage"] || %{}, ["prompt_tokens", "completion_tokens"])})

      {200, _} ->
        Map.merge(base, %{ok: false, error: %{code: "unexpected_answer", message: "the provider's answer has no text"}})

      _ ->
        Map.merge(base, %{ok: false, error: error_of(body)})
    end
  end

  defp error_of(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => %{} = e}} ->
        %{code: text(e["code"] || e["type"] || "error"), message: text(e["message"] || ""), attempts: attempts(e["attempts"])}

      _ ->
        %{code: "error", message: OmnigateControl.Text.line(body, 300), attempts: []}
    end
  end

  defp attempts(list) when is_list(list), do: for(%{"upstream" => u, "outcome" => o} <- list, do: %{upstream: text(u), outcome: text(o)})
  defp attempts(_), do: []

  defp text(value), do: OmnigateControl.Text.line(value, 400)
end
