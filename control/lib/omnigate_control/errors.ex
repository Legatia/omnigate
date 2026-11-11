defmodule OmnigateControl.Errors do
  @moduledoc """
  The one error shape every caller of this process gets, the same one the
  data plane uses for the errors it raises itself:

      {"error": {"message": "...", "type": "<category>", "param": null, "code": "<reason>"}}

  `code` is the gateway's own reason (`job_not_found`, `budget_exceeded`,
  `key_exists`, ...): the stable thing to match on. `type` is the broader,
  OpenAI-style category (`invalid_request_error`, `rate_limit_error`, ...).

  The category table mirrors `typesFor` in `dataplane/src/errors.zig`
  (OpenAI column); keep the two in step, so that a client of `/v1/jobs`
  cannot tell which of the two processes refused it.
  """

  @by_reason %{
    "missing_api_key" => "invalid_request_error",
    "invalid_api_key" => "invalid_request_error",
    "budget_exceeded" => "insufficient_quota",
    "rate_limit_exceeded" => "rate_limit_error",
    "upstream_rate_limited" => "rate_limit_error",
    "model_not_allowed" => "permission_error",
    "model_not_found" => "invalid_request_error",
    "not_found" => "invalid_request_error",
    "payload_too_large" => "invalid_request_error",
    "overloaded" => "server_error"
  }

  @doc false
  # For the test that compares this table with the Zig source.
  def by_reason, do: @by_reason

  @doc "The OpenAI-style category for a gateway reason; reasons not listed fall back on the status."
  def category(reason, status) do
    case @by_reason do
      %{^reason => category} -> category
      _ -> by_status(status)
    end
  end

  defp by_status(401), do: "invalid_request_error"
  defp by_status(403), do: "permission_error"
  defp by_status(404), do: "invalid_request_error"
  defp by_status(429), do: "rate_limit_error"
  defp by_status(400), do: "invalid_request_error"
  defp by_status(status) when status in 405..428, do: "invalid_request_error"
  defp by_status(_), do: "server_error"

  @doc "The error body as a map, ready to be encoded. `extra` adds fields inside `error` (e.g. `request_id`)."
  def body(status, reason, message, extra \\ %{}) do
    %{error: Map.merge(%{message: message, type: category(reason, status), param: nil, code: reason}, extra)}
  end
end
