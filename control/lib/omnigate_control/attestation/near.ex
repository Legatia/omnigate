defmodule OmnigateControl.Attestation.Near do
  @moduledoc """
  Verification of NEAR AI Cloud attestation reports and response signatures,
  as described at https://docs.near.ai/cloud/verification.

  NEAR AI Cloud runs its gateway and its own models inside Intel TDX virtual
  machines. Before sending anything private, a client asks for an attestation
  report with a fresh random nonce and checks, for the gateway and for every
  model report returned:

    * the Intel quote is genuine and the platform's status is acceptable
      (`OmnigateControl.Attestation.Tdx`);
    * the machine is not in debug mode;
    * the quote's report data contains the client's nonce (so the report is
      fresh) and the signing identity the report names (so later response
      signatures can be tied to this machine);
    * the software configuration in the report (`app_compose`) is the one the
      processor measured (`MRCONFIGID`);
    * the event log in the report replays to the measured `RTMR3`.

  All checks fail closed: anything missing, malformed or mismatched is an
  error, never a pass. What these checks do not establish is listed in
  `verify_all/3`.

  This module holds no state. The caller keeps the verified result and
  decides how long to rely on it.
  """

  alias OmnigateControl.Attestation.{EthSignature, Tdx}

  @default_statuses ["UpToDate"]
  @nras_url "https://nras.attestation.nvidia.com/v3/attest/gpu"

  @type reason :: {atom, term}

  @typedoc "A report that passed every check."
  @type verified_report :: %{
          signing_algo: String.t(),
          signing_address: String.t(),
          status: String.t(),
          advisory_ids: [String.t()],
          tls_cert_fingerprint: String.t() | nil,
          tls_bound: boolean,
          model: String.t() | nil,
          app_compose_sha256: String.t(),
          mr_td: String.t(),
          rtmr3: String.t(),
          report_data: String.t(),
          td_attributes: String.t(),
          quote_version: integer,
          gpu: :verified | :absent | :skipped,
          collateral_expires_at: integer
        }

  @type verified :: %{gateway: verified_report, models: [verified_report], nonce: String.t(), verified_at: integer}

  # ---- Fetching ----------------------------------------------------------

  @doc "A fresh nonce: 32 random bytes as 64 hexadecimal characters."
  @spec nonce() :: String.t()
  def nonce, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  @doc """
  Requests an attestation report from `base_url` (for example
  `"https://cloud-api.near.ai"`) bound to `nonce`. With a `model`, the model's
  own reports are requested too, by canonical name (aliases are refused by
  the service because `x-no-aliasing` is sent). No API key is needed or sent
  unless one is given.

  Options: `:signing_algo` (`"ed25519"`, the default, or `"ecdsa"`),
  `:include_tls_fingerprint` (default `false`), `:api_key`, `:http`.

  Returns the decoded JSON body. The report is not bound to a TLS connection
  here: that needs the certificate of the very connection a later request
  travels on, and requests travel on the data plane's connections.
  """
  @spec fetch_report(String.t(), String.t() | nil, String.t(), keyword) :: {:ok, map} | {:error, reason}
  def fetch_report(base_url, model, nonce, opts \\ []) do
    http = Keyword.get(opts, :http, OmnigateControl.Attestation.Http)

    query =
      [{"signing_algo", Keyword.get(opts, :signing_algo, "ed25519")}, {"nonce", nonce}] ++
        if(model, do: [{"model", model}, {"provider", "near"}], else: []) ++
        if(Keyword.get(opts, :include_tls_fingerprint, false), do: [{"include_tls_fingerprint", "true"}], else: [])

    headers =
      [{"accept", "application/json"}] ++
        if(model, do: [{"x-no-aliasing", "true"}], else: []) ++
        case opts[:api_key] do
          nil -> []
          key -> [{"authorization", "Bearer " <> key}]
        end

    url = String.trim_trailing(base_url, "/") <> "/v1/attestation/report?" <> URI.encode_query(query)

    case http.get(url, headers) do
      {:ok, 200, _, body} ->
        case decode_json(body) do
          {:ok, %{} = json} -> {:ok, json}
          _ -> {:error, {:bad_report, "the attestation response is not a JSON object"}}
        end

      {:ok, 429, headers, _} ->
        {:error, {:rate_limited, retry_after(headers)}}

      {:ok, status, _, body} ->
        {:error, {:report_unavailable, {status, String.slice(body, 0, 300)}}}

      {:error, reason} ->
        {:error, {:report_unavailable, reason}}
    end
  end

  defp retry_after(headers) do
    with {_, value} <- Enum.find(headers, fn {k, _} -> String.downcase(k) == "retry-after" end),
         {seconds, _} <- Integer.parse(value) do
      seconds
    else
      _ -> nil
    end
  end

  # ---- Whole-response verification ---------------------------------------

  @doc """
  Verifies the gateway report and every model report in an attestation
  response fetched with `nonce`.

  Options:

    * `:model` — the model the reports were requested for. Then at least one
      model report must be present, each must name this model, and all must
      pass; one failing candidate fails the whole verification.
    * `:accepted_statuses` — TCB statuses to accept (default `["UpToDate"]`).
    * `:gpu` — `:if_present` (default) verifies NVIDIA GPU evidence when a
      model report carries it, `:require` also fails when it is absent,
      `:skip` never contacts NVIDIA.
    * `:now` — Unix seconds, for reproducing a verification.
    * `:collateral` — a function from quote bytes to `{:ok, collateral}`;
      defaults to `Tdx.fetch_collateral/1`. Pass one that caches.
    * `:peer_spki_sha256` — the hash of the server certificate's public key
      seen on the connection that returned the report, when the report was
      requested with the TLS fingerprint.
    * `:http`.

  What a pass does not establish, per NEAR's own documentation: that a later
  completion was served by the same model instance (instances share a signing
  key); a complete chain from model to gateway to response; and that the
  measured software is software you trust — that needs a policy on the
  returned measurements (`app_compose_sha256`, `mr_td`) and image provenance.
  """
  @spec verify_all(map, String.t(), keyword) :: {:ok, verified} | {:error, reason}
  def verify_all(body, nonce, opts \\ []) do
    model = opts[:model]
    candidates = body["model_attestations"]

    with %{} = gateway_report <- body["gateway_attestation"] || {:error, {:gateway_report_missing, nil}},
         {:ok, gateway} <- check_report(gateway_report, nonce, Keyword.put(opts, :gpu, :skip)) |> tag(:gateway),
         {:ok, models} <- check_candidates(candidates, model, nonce, opts) do
      {:ok, %{gateway: gateway, models: models, nonce: nonce, verified_at: Keyword.get(opts, :now) || System.os_time(:second)}}
    end
  end

  defp check_candidates(_candidates, nil, _nonce, _opts), do: {:ok, []}

  defp check_candidates(candidates, model, nonce, opts) when is_list(candidates) and candidates != [] do
    # The TLS fingerprint in a model report describes the model's own endpoint,
    # not the connection to the gateway, so it is not compared with the peer.
    opts = Keyword.delete(opts, :peer_spki_sha256)

    candidates
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {candidate, index}, {:ok, acc} ->
      with %{} <- candidate,
           true <- candidate["model_name"] in [nil, model] || {:error, {:wrong_model, candidate["model_name"]}},
           {:ok, verified} <- check_report(candidate, nonce, opts) do
        {:cont, {:ok, acc ++ [Map.put(verified, :model, model)]}}
      else
        {:error, reason} -> {:halt, {:error, {:model_report_failed, {index, reason}}}}
        _ -> {:halt, {:error, {:model_report_failed, {index, {:bad_report, "not an object"}}}}}
      end
    end)
  end

  defp check_candidates(_candidates, model, _nonce, _opts), do: {:error, {:model_reports_missing, model}}

  defp tag({:ok, _} = ok, _), do: ok
  defp tag({:error, reason}, name), do: {:error, {:"#{name}_report_failed", reason}}

  # ---- One report --------------------------------------------------------

  @doc """
  Verifies one NEAR report (`gateway_attestation` or one entry of
  `model_attestations`) against the nonce it was requested with. Options as
  for `verify_all/3`.
  """
  @spec check_report(map, String.t(), keyword) :: {:ok, verified_report} | {:error, reason}
  def check_report(report, nonce_hex, opts \\ []) do
    now = Keyword.get(opts, :now) || System.os_time(:second)
    accepted = Keyword.get(opts, :accepted_statuses, @default_statuses)
    collateral_fun = Keyword.get(opts, :collateral, &Tdx.fetch_collateral/1)

    with {:ok, nonce} <- hex(nonce_hex, 32) |> or_error({:bad_nonce, "a nonce is 32 bytes as 64 hexadecimal characters"}),
         {:ok, quote} <- hex(report["intel_quote"]) |> or_error({:bad_report, "intel_quote is missing or not hexadecimal"}),
         # Before anything is fetched for it: a report that does not even
         # claim our nonce is somebody else's, or an old one.
         :ok <- echoed_nonce(report, nonce_hex),
         {:ok, collateral} <- collateral_fun.(quote),
         {:ok, td} <- Tdx.verify(quote, collateral, now, Keyword.take(opts, [:trusted_root_der])),
         :ok <- accepted_status(td, accepted),
         :ok <- Tdx.check_td_attributes(td.td_attributes),
         {:ok, algo, identity} <- signing_identity(report),
         {:ok, fingerprint} <- tls_fingerprint(report, opts[:peer_spki_sha256]),
         :ok <- report_data(td.report_data, identity, fingerprint, nonce),
         :ok <- echoed(report, td.report_data),
         {:ok, compose_hash} <- configuration(report, td.mr_config_id),
         :ok <- event_log(report["event_log"], td.rtmr3),
         {:ok, gpu} <- gpu(report, nonce_hex, opts) do
      {:ok,
       %{
         signing_algo: algo,
         signing_address: Base.encode16(identity, case: :lower),
         status: td.status,
         advisory_ids: td.advisory_ids,
         tls_cert_fingerprint: fingerprint && Base.encode16(fingerprint, case: :lower),
         tls_bound: fingerprint != nil and opts[:peer_spki_sha256] != nil,
         model: nil,
         app_compose_sha256: Base.encode16(compose_hash, case: :lower),
         mr_td: Base.encode16(td.mr_td, case: :lower),
         rtmr3: Base.encode16(td.rtmr3, case: :lower),
         report_data: Base.encode16(td.report_data, case: :lower),
         td_attributes: Base.encode16(td.td_attributes, case: :lower),
         quote_version: td.version,
         gpu: gpu,
         collateral_expires_at: td.collateral_expires_at
       }}
    end
  end

  defp accepted_status(td, accepted) do
    if td.status in accepted, do: :ok, else: {:error, {:tcb_status_not_accepted, {td.status, td.advisory_ids}}}
  end

  # An ECDSA identity is a 20-byte Ethereum-style address, an Ed25519 identity
  # the 32-byte public key. Identities are never compared across algorithms.
  defp signing_identity(report) do
    algo = report["signing_algo"]
    address = report["signing_address"]

    with true <- is_binary(address),
         {:ok, identity} <- hex(String.replace_prefix(address, "0x", "")),
         true <- %{"ecdsa" => 20, "ed25519" => 32}[algo] == byte_size(identity) do
      {:ok, algo, identity}
    else
      _ -> {:error, {:unsupported_signing_identity, algo}}
    end
  end

  defp tls_fingerprint(report, peer) do
    case {report["tls_cert_fingerprint"], peer} do
      {nil, nil} ->
        {:ok, nil}

      {nil, _} ->
        {:error, {:tls_fingerprint_missing, nil}}

      {fingerprint, peer} ->
        with {:ok, raw} <- hex(fingerprint, 32) |> or_error({:bad_report, "tls_cert_fingerprint is not 32 bytes of hexadecimal"}) do
          if peer == nil or String.downcase(peer) == String.downcase(fingerprint),
            do: {:ok, raw},
            else: {:error, {:tls_fingerprint_mismatch, fingerprint}}
        end
    end
  end

  # Report data is 64 bytes: 32 that bind the signing identity (alone and
  # zero-padded, or hashed together with the TLS fingerprint), then the nonce.
  defp report_data(report_data, identity, fingerprint, nonce) do
    bound =
      if fingerprint,
        do: :crypto.hash(:sha256, identity <> fingerprint),
        else: identity <> :binary.copy(<<0>>, 32 - byte_size(identity))

    case report_data do
      <<^bound::binary-32, ^nonce::binary-32>> -> :ok
      <<^bound::binary-32, _::binary>> -> {:error, {:nonce_mismatch, :quote}}
      _ -> {:error, {:signer_not_bound, nil}}
    end
  end

  # The copies in the HTTP response are only consistency checks; the quote is
  # the source of truth. A copy that disagrees with it is still an error.
  defp echoed(report, report_data) do
    cond do
      is_binary(report["report_data"]) and String.downcase(report["report_data"]) != Base.encode16(report_data, case: :lower) ->
        {:error, {:report_data_mismatch, nil}}

      true ->
        :ok
    end
  end

  defp echoed_nonce(report, nonce_hex) do
    if is_binary(report["request_nonce"]) and String.downcase(report["request_nonce"]) == String.downcase(nonce_hex),
      do: :ok,
      else: {:error, {:nonce_mismatch, :echo}}
  end

  # MRCONFIGID is 0x01, the SHA-256 of the exact app_compose text, 15 zeros.
  defp configuration(report, mr_config_id) do
    with %{} = info <- report["info"],
         {:ok, %{} = tcb_info} <- maybe_json(info["tcb_info"]),
         compose when is_binary(compose) <- tcb_info["app_compose"] do
      hash = :crypto.hash(:sha256, compose)

      if mr_config_id == <<1, hash::binary, 0::size(120)>>,
        do: {:ok, hash},
        else: {:error, {:configuration_mismatch, Base.encode16(hash, case: :lower)}}
    else
      _ -> {:error, {:bad_report, "info.tcb_info.app_compose is missing"}}
    end
  end

  @doc """
  Replays the runtime-measurement events of register 3 and returns the
  resulting 48-byte value. `event_log` is a list, or the JSON text of one.
  Each event's digest is recomputed from its content, which also
  authenticates the payloads; a digest in the log that differs is an error.
  """
  @spec replay_rtmr3(term) :: {:ok, binary} | {:error, reason}
  def replay_rtmr3(event_log) do
    case maybe_json(event_log) do
      {:ok, events} when is_list(events) ->
        events
        |> Enum.filter(&(is_map(&1) and &1["imr"] == 3))
        |> Enum.reduce_while({:ok, <<0::size(384)>>}, fn event, {:ok, rtmr} ->
          with type when is_integer(type) and type >= 0 and type <= 0xFFFFFFFF <- event["event_type"],
               name when is_binary(name) <- event["event"],
               {:ok, payload} <- hex(event["event_payload"] || ""),
               digest = :crypto.hash(:sha384, <<type::little-32, ":", name::binary, ":", payload::binary>>),
               true <- (event["digest"] in [nil, ""] or hex(event["digest"]) == {:ok, digest}) || {:error, {:event_digest_mismatch, name}} do
            {:cont, {:ok, :crypto.hash(:sha384, rtmr <> digest)}}
          else
            {:error, _} = e -> {:halt, e}
            _ -> {:halt, {:error, {:bad_report, "malformed event log entry"}}}
          end
        end)

      _ ->
        {:error, {:bad_report, "event_log is missing"}}
    end
  end

  defp event_log(log, rtmr3) do
    case replay_rtmr3(log) do
      {:ok, ^rtmr3} -> :ok
      {:ok, _} -> {:error, {:event_log_mismatch, nil}}
      error -> error
    end
  end

  # ---- GPU evidence ------------------------------------------------------

  defp gpu(report, nonce_hex, opts) do
    case {Keyword.get(opts, :gpu, :if_present), report["nvidia_payload"]} do
      {:skip, _} -> {:ok, :skipped}
      {:require, payload} when payload in [nil, ""] -> {:error, {:gpu_evidence_missing, nil}}
      {_, payload} when payload in [nil, ""] -> {:ok, :absent}
      _ -> with :ok <- check_gpu(report, nonce_hex, opts), do: {:ok, :verified}
    end
  end

  @doc """
  Verifies the NVIDIA GPU evidence of a model report: its nonce must be the
  client's, and NVIDIA's remote attestation service must return an overall
  verdict of `true`. The verdict is trusted because it arrives over verified
  TLS from NVIDIA; the token's own signature is not checked here.

  Options: `:http`, `:nras_url`.
  """
  @spec check_gpu(map, String.t(), keyword) :: :ok | {:error, reason}
  def check_gpu(report, nonce_hex, opts \\ []) do
    http = Keyword.get(opts, :http, OmnigateControl.Attestation.Http)

    with payload when is_binary(payload) and payload != "" <- report["nvidia_payload"] || {:error, {:gpu_evidence_missing, nil}},
         {:ok, %{"nonce" => nonce}} when is_binary(nonce) <- decode_json(payload) |> or_error({:bad_gpu_evidence, "not a JSON object with a nonce"}),
         true <- String.downcase(nonce) == String.downcase(nonce_hex) || {:error, {:nonce_mismatch, :gpu}},
         {:ok, 200, _, body} <-
           http.post(Keyword.get(opts, :nras_url, @nras_url), [{"accept", "application/json"}, {"content-type", "application/json"}], payload),
         {:ok, [["JWT", token] | _]} when is_binary(token) <- decode_json(body) |> or_error({:bad_gpu_verdict, "unexpected response shape"}),
         [_, claims_b64, _] <- String.split(token, "."),
         {:ok, claims_json} <- Base.url_decode64(claims_b64, padding: false),
         {:ok, %{} = claims} <- decode_json(claims_json) do
      cond do
        claims["x-nvidia-overall-att-result"] != true -> {:error, {:gpu_verdict_failed, claims["x-nvidia-overall-att-result"]}}
        is_binary(claims["eat_nonce"]) and String.downcase(claims["eat_nonce"]) != String.downcase(nonce_hex) -> {:error, {:nonce_mismatch, :gpu_verdict}}
        true -> :ok
      end
    else
      {:error, {reason, _}} = e when is_atom(reason) -> e
      {:ok, status, _, body} when is_integer(status) -> {:error, {:gpu_verdict_unavailable, {status, String.slice(body, 0, 300)}}}
      {:error, reason} -> {:error, {:gpu_verdict_unavailable, reason}}
      _ -> {:error, {:bad_gpu_verdict, "unexpected response shape"}}
    end
  end

  # ---- Response signatures -----------------------------------------------

  @doc """
  Verifies the signature NEAR returns from `GET /v1/signature/<id>` for a
  completion, against the exact bytes that were sent and received and
  against the reports verified before the request (`verify_all/3`).

  `request_bytes` and `response_bytes` are the request and response bodies
  exactly as they crossed the wire (uncompressed; for a stream, every byte
  of it). `model` is the canonical model name in the request.

  A `provider_tee` signature must come from exactly one verified model
  report and cover `<model>:<sha256 request>:<sha256 response>`; a `gateway`
  signature must come from the verified gateway and cover the two hashes. A
  signature kind this code does not know is an error. Both signing
  algorithms are verified; the report and the signature must have been
  requested with the same `signing_algo`, since identities are never compared
  across algorithms.

  Returns the kind that was verified.
  """
  @spec verify_response_signature(map, binary, binary, String.t() | nil, verified) ::
          {:ok, :provider_tee | :gateway} | {:error, reason}
  def verify_response_signature(signature, request_bytes, response_bytes, model, verified) do
    hashes = sha256_hex(request_bytes) <> ":" <> sha256_hex(response_bytes)

    with :ok <- available(signature),
         {:ok, kind, expected, candidates} <- expected_text(signature["signature_kind"], hashes, model, verified),
         true <- signature["text"] == expected || {:error, {:signature_text_mismatch, kind}},
         {:ok, algo, identity} <- signing_identity(signature),
         :ok <- signature_valid(algo, identity, signature),
         address = Base.encode16(identity, case: :lower),
         [_one] <- Enum.filter(candidates, &(&1.signing_algo == algo and &1.signing_address == address)) do
      {:ok, kind}
    else
      {:error, _} = e -> e
      matches when is_list(matches) -> {:error, {:signer_not_verified, length(matches)}}
    end
  end

  defp available(%{"error_code" => code} = sig) when not is_nil(code), do: {:error, {:signature_unavailable, {code, sig["message"]}}}
  defp available(%{"text" => text, "signature" => sig}) when is_binary(text) and is_binary(sig), do: :ok
  defp available(_), do: {:error, {:signature_unavailable, nil}}

  defp expected_text("provider_tee", _hashes, model, _) when model in [nil, ""], do: {:error, {:model_required, nil}}
  defp expected_text("provider_tee", hashes, model, v), do: {:ok, :provider_tee, model <> ":" <> hashes, v.models}
  defp expected_text("gateway", hashes, _model, v), do: {:ok, :gateway, hashes, [v.gateway]}
  defp expected_text(kind, _, _, _), do: {:error, {:unknown_signature_kind, kind}}

  defp signature_valid("ed25519", public_key, %{"text" => text, "signature" => sig_hex}) do
    with {:ok, sig} <- hex(String.replace_prefix(sig_hex, "0x", ""), 64),
         true <- ed25519_valid?(text, sig, public_key) do
      :ok
    else
      _ -> {:error, {:bad_response_signature, "ed25519"}}
    end
  end

  # An ECDSA identity is an address, so the signer is recovered from the
  # signature (an Ethereum personal-message signature) and compared with it.
  defp signature_valid("ecdsa", address, %{"text" => text, "signature" => sig_hex}) do
    with {:ok, sig} <- hex(String.replace_prefix(sig_hex, "0x", ""), 65),
         {:ok, ^address} <- EthSignature.recover_personal(text, sig) do
      :ok
    else
      _ -> {:error, {:bad_response_signature, "ecdsa"}}
    end
  end

  defp signature_valid(algo, _, _), do: {:error, {:unsupported_algo, algo}}

  defp ed25519_valid?(text, sig, public_key) do
    :crypto.verify(:eddsa, :none, text, sig, [public_key, :ed25519])
  rescue
    _ -> false
  end

  # ---- Helpers -----------------------------------------------------------

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp hex(value) when is_binary(value) do
    case Base.decode16(value, case: :mixed) do
      {:ok, bin} -> {:ok, bin}
      :error -> :error
    end
  end

  defp hex(_), do: :error

  defp hex(value, size) do
    case hex(value) do
      {:ok, bin} when byte_size(bin) == size -> {:ok, bin}
      _ -> :error
    end
  end

  defp or_error({:ok, _} = ok, _), do: ok
  defp or_error(_, reason), do: {:error, reason}

  # Some fields arrive either as JSON values or as the JSON text of one.
  defp maybe_json(value) when is_binary(value), do: decode_json(value)
  defp maybe_json(nil), do: :error
  defp maybe_json(value), do: {:ok, value}

  defp decode_json(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  end

  defp decode_json(_), do: :error
end
