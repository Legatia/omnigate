defmodule OmnigateControl.Attestation.Http do
  @moduledoc """
  The HTTP calls attestation makes, on the control plane's own client
  (`OmnigateControl.Http`): certificates are checked against the system's
  trust store, redirects are never followed, and a response is read through
  a cap.

  Three kinds of host are ever called: the upstream being attested (the
  operator's `base_url`), Intel's provisioning certification service and
  NVIDIA's remote attestation service. The last two are fixed in the source.

  The return shape, `{:ok, status, headers, body}` with lower-case header
  names, is what `Tdx` and `Near` take as their `:http` option, so a test can
  pass a module of its own.
  """

  # An attestation response is about 340 kB (a third of it GPU evidence);
  # Intel's documents are a few kB each.
  @max_body 4 * 1024 * 1024
  @timeout 30_000

  @type headers :: [{String.t(), String.t()}]
  @type response :: {:ok, pos_integer, headers, binary} | {:error, term}

  @spec get(String.t(), headers) :: response
  def get(url, headers \\ []), do: request(:get, url, headers, nil)

  @spec post(String.t(), headers, binary) :: response
  def post(url, headers, body), do: request(:post, url, headers, body)

  defp request(method, url, headers, body) do
    # Signatures and hashes are over uncompressed bytes.
    headers = [{"accept-encoding", "identity"} | headers]

    case OmnigateControl.Http.request(method, url, headers, body, timeout: @timeout, max_body: @max_body) do
      {:ok, %{status: status, headers: response_headers, body: response_body}} -> {:ok, status, Map.to_list(response_headers), response_body}
      {:error, reason} -> {:error, reason}
    end
  end
end
