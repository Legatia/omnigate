defmodule OmnigateControl.UrlSigner do
  @moduledoc """
  HMAC-signed, expiring URLs for locally stored job outputs.

  A signed URL lets a browser or end user fetch one file without a gateway
  key. The signature covers the job id, the file name and the expiry.

  The secret is `OMNIGATE_SIGNING_SECRET`, or, when that is unset, a key
  derived from `OMNIGATE_INTERNAL_TOKEN`.
  """

  @doc "Query string (`exp=..&sig=..`) authorising `job_id/name` for `ttl_s` seconds."
  def sign(job_id, name, ttl_s, now \\ System.os_time(:second)) do
    exp = now + ttl_s
    "exp=#{exp}&sig=#{signature(job_id, name, exp)}"
  end

  @doc "Checks `exp` and `sig` (strings from the query)."
  def verify(job_id, name, exp, sig, now \\ System.os_time(:second))

  def verify(job_id, name, exp, sig, now) when is_binary(exp) and is_binary(sig) do
    case Integer.parse(exp) do
      {exp_i, ""} ->
        cond do
          not Plug.Crypto.secure_compare(signature(job_id, name, exp_i), sig) -> {:error, :bad_signature}
          exp_i < now -> {:error, :expired}
          true -> :ok
        end

      _ ->
        {:error, :bad_signature}
    end
  end

  def verify(_job_id, _name, _exp, _sig, _now), do: {:error, :missing}

  defp signature(job_id, name, exp) do
    :crypto.mac(:hmac, :sha256, secret(), "#{job_id}/#{name}\n#{exp}") |> Base.encode16(case: :lower)
  end

  defp secret do
    case System.get_env("OMNIGATE_SIGNING_SECRET") do
      s when is_binary(s) and s != "" ->
        s

      _ ->
        token =
          System.get_env("OMNIGATE_INTERNAL_TOKEN") ||
            Application.get_env(:omnigate_control, :signing_secret) ||
            raise "set OMNIGATE_SIGNING_SECRET or OMNIGATE_INTERNAL_TOKEN to sign file URLs"

        :crypto.mac(:hmac, :sha256, token, "omnigate-file-urls")
    end
  end
end
