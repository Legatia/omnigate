defmodule OmnigateControl.Attestation.Tdx do
  @moduledoc """
  Verification of Intel TDX attestation quotes (DCAP, quote versions 4 and 5).

  A quote is a statement signed inside the processor's trusted environment:
  "a virtual machine with these measurements is running on genuine, patched
  Intel hardware, and it asked me to include these 64 bytes". `verify/4`
  checks that statement against Intel's signing chain and returns the
  measurements, which the caller then compares with what it expects.

  The checks, in order:

    1. the root revocation list is signed by the pinned Intel SGX Root CA and
       is current;
    2. the TCB information and the quoting-enclave identity are signed by a
       certificate issued directly by that root, and are current;
    3. the platform (PCK) certificate chain in the quote leads to that root,
       and none of its certificates is revoked;
    4. the quoting enclave's report is signed by the platform certificate,
       commits to the attestation key, and matches Intel's published identity;
    5. the quote itself is signed by that attestation key;
    6. the platform's security versions are matched against the TCB
       information to obtain a status such as `"UpToDate"` or `"OutOfDate"`.

  A `Revoked` status is always an error. Every other status is returned for
  the caller's policy to accept or refuse. Nothing here talks to the network
  except `fetch_collateral/2`; `verify/4` is a pure function of its inputs, so
  results can be reproduced from stored collateral.

  Follows Intel's DCAP verification rules, with Phala's `dcap-qvl` as the
  reference for edge cases.
  """

  alias OmnigateControl.Attestation.Der

  import Bitwise

  # Intel SGX Root CA, the trust anchor of every DCAP chain. Downloaded on
  # 11 November 2026 from
  # https://certificates.trustedservices.intel.com/Intel_SGX_Provisioning_Certification_RootCA.cer
  # SHA-256 fingerprint 44A0196B2B99F889B8E149E95B807A350E7424964399E885A7CBB8CCFAB674D3,
  # valid until 31 December 2049.
  @intel_root_der Base.decode64!(
                    "MIICjzCCAjSgAwIBAgIUImUM1lqdNInzg7SVUr9QGzknBqwwCgYIKoZIzj0EAwIwaDEaMBgGA1UEAwwRSW50ZWwgU0dYIFJvb3QgQ0ExGjAYBgNVBAoMEUludGVsIENvcnBvcmF0aW9uMRQwEgYDVQQHDAtTYW50YSBDbGFyYTELMAkGA1UECAwCQ0ExCzAJBgNVBAYTAlVTMB4XDTE4MDUyMTEwNDUxMFoXDTQ5MTIzMTIzNTk1OVowaDEaMBgGA1UEAwwRSW50ZWwgU0dYIFJvb3QgQ0ExGjAYBgNVBAoMEUludGVsIENvcnBvcmF0aW9uMRQwEgYDVQQHDAtTYW50YSBDbGFyYTELMAkGA1UECAwCQ0ExCzAJBgNVBAYTAlVTMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEC6nEwMDIYZOj/iPWsCzaEKi71OiOSLRFhWGjbnBVJfVnkY4u3IjkDYYL0MxO4mqsyYjlBalTVYxFP2sJBK5zlKOBuzCBuDAfBgNVHSMEGDAWgBQiZQzWWp00ifODtJVSv1AbOScGrDBSBgNVHR8ESzBJMEegRaBDhkFodHRwczovL2NlcnRpZmljYXRlcy50cnVzdGVkc2VydmljZXMuaW50ZWwuY29tL0ludGVsU0dYUm9vdENBLmRlcjAdBgNVHQ4EFgQUImUM1lqdNInzg7SVUr9QGzknBqwwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQEwCgYIKoZIzj0EAwIDSQAwRgIhAOW/5QkR+S9CiSDcNoowLuPRLsWGf/Yi7GSX94BgwTwgAiEA4J0lrHoMs+Xo5o/sX6O9QWxHRAvZUGOdRQ7cvqRXaqI="
                  )

  @pcs_url "https://api.trustedservices.intel.com"
  @root_crl_url "https://certificates.trustedservices.intel.com/IntelSGXRootCA.der"

  @intel_qe_vendor_id Base.decode16!("939A7233F79C4CA9940A0DB3957F0607")
  @tee_tdx 0x81
  @key_type_p256 2
  @sgx_extension "1.2.840.113741.1.13.1"
  @max_intermediates 4

  @platform_statuses ~w(UpToDate OutOfDate ConfigurationNeeded Revoked OutOfDateConfigurationNeeded SWHardeningNeeded ConfigurationAndSWHardeningNeeded)
  @module_statuses ~w(UpToDate OutOfDate Revoked)
  @qe_statuses ~w(UpToDate OutOfDate ConfigurationNeeded Revoked OutOfDateConfigurationNeeded)

  # TD attribute bits that must be zero (Intel TDX Module ABI, table 3.23).
  @td_reserved_mask 0x3FFFFFFF_0780FF8E

  @type reason :: {atom, term}
  @type collateral :: %{optional(String.t()) => String.t() | integer}

  @typedoc "What a verified quote says. All byte fields are raw binaries."
  @type verified :: %{
          status: String.t(),
          advisory_ids: [String.t()],
          version: 4 | 5,
          tee_tcb_svn: binary,
          mr_seam: binary,
          mr_signer_seam: binary,
          seam_attributes: binary,
          td_attributes: binary,
          xfam: binary,
          mr_td: binary,
          mr_config_id: binary,
          mr_owner: binary,
          mr_owner_config: binary,
          rtmr0: binary,
          rtmr1: binary,
          rtmr2: binary,
          rtmr3: binary,
          report_data: binary,
          fmspc: binary,
          platform_status: String.t(),
          qe_status: String.t(),
          tcb_date: String.t(),
          tcb_evaluation_data_number: integer,
          collateral_expires_at: integer
        }

  @doc "The pinned Intel SGX Root CA certificate, DER encoded."
  @spec intel_root_der() :: binary
  def intel_root_der, do: @intel_root_der

  # ---- Verification ------------------------------------------------------

  @doc """
  Verifies `quote` (raw bytes) against `collateral` at the time `now` (Unix
  seconds). Returns the verified report and TCB status, or the first check
  that failed.

  Options:

    * `:trusted_root_der` — the trust anchor, for tests. Defaults to the
      pinned Intel SGX Root CA.
  """
  @spec verify(binary, collateral, integer, keyword) :: {:ok, verified} | {:error, reason}
  def verify(quote, collateral, now, opts \\ []) when is_binary(quote) and is_integer(now) do
    with {:ok, root} <- trusted_root(opts, now),
         {:ok, root_crl} <- root_crl(collateral, root, now),
         {:ok, q} <- parse(quote),
         {:ok, tcb_info, tcb_signer} <-
           signed_json(collateral, "tcb_info", root, root_crl, now),
         {:ok, qe_identity, qe_signer} <-
           signed_json(collateral, "qe_identity", root, root_crl, now),
         :ok <- qe_identity_kind(qe_identity),
         {:ok, pck_path} <- pck_chain(q, collateral, root, root_crl, now),
         [pck | _] = pck_path,
         {:ok, platform} <- sgx_extension(pck),
         :ok <- qe_report_signature(q, pck),
         :ok <- qe_report_data(q),
         {:ok, qe_level} <- qe_policy(q.qe_report, qe_identity),
         :ok <- quote_signature(q),
         {:ok, level} <- platform_tcb(tcb_info, q, platform),
         {:ok, status, advisories} <- final_status(level, qe_level) do
      expires =
        [root_crl.next_update, date!(tcb_info["nextUpdate"]), date!(qe_identity["nextUpdate"])] ++
          Enum.map(pck_path ++ [tcb_signer, qe_signer], & &1.not_after) ++
          [pck_crl_next_update(collateral)]

      {:ok,
       q.report
       |> Map.merge(%{
         status: status,
         advisory_ids: advisories,
         version: q.version,
         fmspc: platform.fmspc,
         platform_status: level.status,
         qe_status: qe_level.status,
         tcb_date: level.date,
         tcb_evaluation_data_number: min(tcb_info["tcbEvaluationDataNumber"] || 0, qe_identity["tcbEvaluationDataNumber"] || 0),
         collateral_expires_at: expires |> Enum.reject(&is_nil/1) |> Enum.min()
       })}
    end
  end

  @doc """
  Checks the TD attributes of a verified report the way Intel's verifier
  does: no debugging or profiling, no reserved bits, not migratable, no
  service-TD extension, and `SEPT_VE_DISABLE` set. Takes the 8 raw bytes.
  """
  @spec check_td_attributes(binary) :: :ok | {:error, reason}
  def check_td_attributes(<<attrs::little-64>> = raw) do
    hex = Base.encode16(raw, case: :lower)

    cond do
      (attrs &&& 0x01) != 0 -> {:error, {:debug_enabled, hex}}
      (attrs &&& 0x70) != 0 -> {:error, {:td_profiling_enabled, hex}}
      (attrs &&& @td_reserved_mask) != 0 -> {:error, {:td_attributes_reserved_bits, hex}}
      (attrs &&& 1 <<< 29) != 0 -> {:error, {:td_migratable, hex}}
      (attrs &&& 1 <<< 17) != 0 -> {:error, {:td_service_extension, hex}}
      (attrs &&& 1 <<< 28) == 0 -> {:error, {:sept_ve_disable_not_set, hex}}
      true -> :ok
    end
  end

  def check_td_attributes(_), do: {:error, {:bad_quote, "TD attributes are not 8 bytes"}}

  @doc """
  Verifies a certificate path the way `verify/4` verifies the platform
  certificate chain, on its own: `certs` are DER certificates, leaf first;
  `root_crl` is the revocation list of the trust anchor and `issuer_crl` the
  one issued by the leaf's issuer (both DER). Every certificate must be valid
  at `now`, signed by the next one up to the trust anchor, covered by a
  current revocation list from its issuer, and not on it.

  Returns the verified path without the root. Exposed so the chain and
  revocation rules can be tested with a private PKI; options as `verify/4`.
  """
  @spec verify_certificate_path([binary], binary, binary, integer, keyword) :: {:ok, [Der.cert()]} | {:error, reason}
  def verify_certificate_path(certs, root_crl, issuer_crl, now, opts \\ []) do
    collateral = %{"root_ca_crl" => Base.encode64(root_crl), "pck_crl" => Base.encode64(issuer_crl)}

    with {:ok, root} <- trusted_root(opts, now),
         {:ok, root_crl} <- root_crl(collateral, root, now),
         {:ok, parsed} <- parse_all(certs),
         {:ok, issuer_crl} <- pck_crl(collateral, parsed, now) do
      verify_path(certs, root, [root_crl, issuer_crl], now, :path)
    end
  end

  # ---- Quote parsing -----------------------------------------------------

  @doc """
  Parses a quote without verifying anything. The result is only a reading of
  untrusted bytes; use `verify/4` to learn whether any of it is true.
  """
  @spec parse(binary) :: {:ok, map} | {:error, reason}
  def parse(<<version::little-16, key_type::little-16, tee::little-32, _qe_svn::16, _pce_svn::16, vendor::binary-16, _user::binary-20, rest::binary>> = quote) do
    cond do
      version not in [4, 5] -> {:error, {:unsupported_quote, "quote version #{version}"}}
      tee != @tee_tdx -> {:error, {:unsupported_quote, "not a TDX quote (TEE type #{tee})"}}
      key_type != @key_type_p256 -> {:error, {:unsupported_quote, "attestation key type #{key_type}"}}
      vendor != @intel_qe_vendor_id -> {:error, {:unsupported_quote, "unknown quoting enclave vendor"}}
      true -> parse_body(version, rest, quote)
    end
  end

  def parse(_), do: {:error, {:bad_quote, "shorter than a quote header"}}

  defp parse_body(4, <<body::binary-584, rest::binary>>, quote), do: parse_auth(4, body, <<>>, 48 + 584, rest, quote)

  # Version 5 names its body: type 2 is the TDX 1.0 report, type 3 the TDX 1.5
  # report (the 1.0 fields followed by TEE_TCB_SVN2 and MRSERVICETD).
  defp parse_body(5, <<2::little-16, 584::little-32, body::binary-584, rest::binary>>, quote),
    do: parse_auth(5, body, <<>>, 48 + 6 + 584, rest, quote)

  defp parse_body(5, <<3::little-16, 648::little-32, body::binary-584, extra::binary-64, rest::binary>>, quote),
    do: parse_auth(5, body, extra, 48 + 6 + 648, rest, quote)

  defp parse_body(5, <<type::little-16, _::binary>>, _), do: {:error, {:unsupported_quote, "quote body type #{type}"}}
  defp parse_body(_, _, _), do: {:error, {:bad_quote, "truncated report body"}}

  defp parse_auth(version, body, extra, signed_length, <<len::little-32, auth::binary-size(len), _::binary>>, quote) do
    with <<signature::binary-64, key::binary-64, 6::little-16, clen::little-32, cert_data::binary-size(clen), _::binary>> <- auth,
         <<qe_report::binary-384, qe_signature::binary-64, alen::little-16, qe_auth::binary-size(alen), ctype::little-16, plen::little-32,
           pck::binary-size(plen), _::binary>> <- cert_data do
      <<tee_tcb_svn::binary-16, mr_seam::binary-48, mr_signer_seam::binary-48, seam_attributes::binary-8, td_attributes::binary-8, xfam::binary-8,
        mr_td::binary-48, mr_config_id::binary-48, mr_owner::binary-48, mr_owner_config::binary-48, rtmr0::binary-48, rtmr1::binary-48, rtmr2::binary-48,
        rtmr3::binary-48, report_data::binary-64>> = body

      {tee_tcb_svn2, mr_service_td} =
        case extra do
          <<svn2::binary-16, service::binary-48>> -> {svn2, service}
          _ -> {nil, nil}
        end

      {:ok,
       %{
         version: version,
         signed: binary_part(quote, 0, signed_length),
         signature: signature,
         attestation_key: key,
         qe_report: qe_report,
         qe_report_signature: qe_signature,
         qe_auth_data: qe_auth,
         pck_cert_type: ctype,
         pck_cert_data: pck,
         tee_tcb_svn2: tee_tcb_svn2,
         mr_service_td: mr_service_td,
         report: %{
           tee_tcb_svn: tee_tcb_svn,
           mr_seam: mr_seam,
           mr_signer_seam: mr_signer_seam,
           seam_attributes: seam_attributes,
           td_attributes: td_attributes,
           xfam: xfam,
           mr_td: mr_td,
           mr_config_id: mr_config_id,
           mr_owner: mr_owner,
           mr_owner_config: mr_owner_config,
           rtmr0: rtmr0,
           rtmr1: rtmr1,
           rtmr2: rtmr2,
           rtmr3: rtmr3,
           report_data: report_data
         }
       }}
    else
      _ -> {:error, {:bad_quote, "signature data is not the version 4 layout (certification type 6)"}}
    end
  end

  defp parse_auth(_, _, _, _, _, _), do: {:error, {:bad_quote, "truncated signature data"}}

  # ---- Trust anchor and revocation lists ---------------------------------

  defp trusted_root(opts, now) do
    with {:ok, root} <- Der.parse_cert(Keyword.get(opts, :trusted_root_der, @intel_root_der)),
         :ok <- valid_at(root, now, :root) do
      {:ok, root}
    end
  end

  defp root_crl(collateral, root, now) do
    with {:ok, der} <- base64(collateral, "root_ca_crl"),
         {:ok, crl} <- Der.parse_crl(der),
         :ok <- crl_ok(crl, root, now, :root_ca_crl) do
      if MapSet.member?(crl.revoked, root.serial), do: {:error, {:revoked, :root}}, else: {:ok, crl}
    end
  end

  defp crl_ok(crl, issuer, now, name) do
    cond do
      crl.issuer != issuer.subject -> {:error, {:crl_issuer_mismatch, name}}
      not Der.verify_p256(crl.tbs, crl.signature, issuer.public_key) -> {:error, {:bad_crl_signature, name}}
      crl.this_update > now -> {:error, {:crl_not_yet_valid, name}}
      crl.next_update == nil or crl.next_update < now -> {:error, {:crl_expired, name}}
      true -> :ok
    end
  end

  defp pck_crl_next_update(collateral) do
    with {:ok, der} <- base64(collateral, "pck_crl"), {:ok, crl} <- Der.parse_crl(der) do
      crl.next_update
    else
      _ -> nil
    end
  end

  # Verifies a certificate path, leaf first. Certificates that claim to be a
  # root are only accepted when they carry the trusted key, and are then left
  # out: the path always ends at the pinned root, never at a root the peer
  # supplied. `crls` are lists whose signatures have been checked; every
  # certificate must be covered by the list of its issuer and absent from it.
  # Returns the path without the root.
  defp verify_path(ders, root, crls, now, name) do
    with {:ok, certs} <- parse_all(ders),
         {:ok, path} <- strip_roots(certs, root, name),
         :ok <- path_length(path, name),
         :ok <- links(path, root, now, name),
         :ok <- revocation(path, crls, name) do
      {:ok, path}
    end
  end

  defp parse_all(ders) do
    Enum.reduce_while(ders, {:ok, []}, fn der, {:ok, acc} ->
      case Der.parse_cert(der) do
        {:ok, cert} -> {:cont, {:ok, acc ++ [cert]}}
        error -> {:halt, error}
      end
    end)
  end

  defp strip_roots(certs, root, name) do
    {roots, path} = Enum.split_with(certs, &(&1.issuer == &1.subject))

    cond do
      Enum.any?(roots, &(&1.public_key != root.public_key or &1.subject != root.subject)) -> {:error, {:untrusted_root, name}}
      path == [] -> {:error, {:bad_certificate_chain, name}}
      true -> {:ok, path}
    end
  end

  defp path_length(path, name) do
    if length(path) - 1 > @max_intermediates, do: {:error, {:bad_certificate_chain, name}}, else: :ok
  end

  defp links([cert], root, now, name) do
    cond do
      cert.issuer != root.subject or not Der.verify_p256(cert.tbs, cert.signature, root.public_key) -> {:error, {:untrusted_root, name}}
      true -> valid_at(cert, now, name)
    end
  end

  defp links([cert, issuer | rest], root, now, name) do
    cond do
      cert.issuer != issuer.subject -> {:error, {:bad_certificate_chain, name}}
      not issuer.ca -> {:error, {:issuer_not_a_ca, name}}
      not Der.verify_p256(cert.tbs, cert.signature, issuer.public_key) -> {:error, {:bad_certificate_signature, name}}
      true -> with :ok <- valid_at(cert, now, name), do: links([issuer | rest], root, now, name)
    end
  end

  defp valid_at(cert, now, name) do
    cond do
      now < cert.not_before -> {:error, {:certificate_not_yet_valid, name}}
      now > cert.not_after -> {:error, {:certificate_expired, name}}
      true -> :ok
    end
  end

  defp revocation(path, crls, name) do
    Enum.reduce_while(path, :ok, fn cert, :ok ->
      case Enum.find(crls, &(&1.issuer == cert.issuer)) do
        nil -> {:halt, {:error, {:crl_missing, name}}}
        crl -> if MapSet.member?(crl.revoked, cert.serial), do: {:halt, {:error, {:revoked, name}}}, else: {:cont, :ok}
      end
    end)
  end

  # ---- Signed collateral (TCB information, quoting-enclave identity) -----

  defp signed_json(collateral, name, root, root_crl, now) do
    with {:ok, raw} <- field(collateral, name),
         {:ok, hex} <- field(collateral, name <> "_signature"),
         {:ok, chain} <- field(collateral, name <> "_issuer_chain"),
         {:ok, [signer]} <- signer_path(chain, root, root_crl, now, name),
         {:ok, raw_sig} <- Base.decode16(hex, case: :mixed) |> or_error({:bad_collateral, name <> "_signature"}),
         {:ok, der_sig} <- Der.raw_signature_to_der(raw_sig) |> or_error({:bad_collateral, name <> "_signature"}),
         true <- Der.verify_p256(raw, der_sig, signer.public_key) || {:error, {:bad_collateral_signature, name}},
         {:ok, json} <- decode_json(raw) |> or_error({:bad_collateral, name}),
         {:ok, issued} <- date(json["issueDate"]) |> or_error({:bad_collateral, name}),
         {:ok, next} <- date(json["nextUpdate"]) |> or_error({:bad_collateral, name}) do
      cond do
        now < issued -> {:error, {:collateral_not_yet_valid, name}}
        now > next -> {:error, {:collateral_expired, name}}
        true -> {:ok, json, signer}
      end
    end
  end

  # Intel signs both documents with a certificate issued directly by the root.
  defp signer_path(chain, root, root_crl, now, name) do
    case verify_path(Der.pem_certs(chain), root, [root_crl], now, name) do
      {:ok, [_] = path} -> {:ok, path}
      {:ok, _} -> {:error, {:bad_certificate_chain, name}}
      error -> error
    end
  end

  defp qe_identity_kind(%{"id" => "TD_QE", "version" => v}) when v in [2, 3], do: :ok
  defp qe_identity_kind(id), do: {:error, {:wrong_qe_identity, {id["id"], id["version"]}}}

  # ---- Platform certificate ----------------------------------------------

  defp pck_chain(q, collateral, root, root_crl, now) do
    ders =
      case collateral["pck_certificate_chain"] do
        pem when is_binary(pem) -> Der.pem_certs(pem)
        _ when q.pck_cert_type == 5 -> Der.pem_certs(q.pck_cert_data)
        _ -> []
      end

    with false <- ders == [] and {:error, {:pck_chain_missing, q.pck_cert_type}},
         {:ok, certs} <- parse_all(ders),
         {:ok, pck_crl} <- pck_crl(collateral, certs, now) do
      verify_path(ders, root, [root_crl, pck_crl], now, :pck)
    end
  end

  # The platform revocation list must come from the certificate authority that
  # issued the platform certificate, and that authority is itself verified as
  # part of the path.
  defp pck_crl(collateral, [leaf | rest], now) do
    with {:ok, der} <- base64(collateral, "pck_crl"),
         {:ok, crl} <- Der.parse_crl(der) do
      case Enum.find(rest, &(&1.subject == leaf.issuer)) do
        nil -> {:error, {:bad_certificate_chain, :pck}}
        issuer -> with :ok <- crl_ok(crl, issuer, now, :pck_crl), do: {:ok, crl}
      end
    end
  end

  defp pck_crl(_, _, _), do: {:error, {:bad_certificate_chain, :pck}}

  # The SGX extension of a platform certificate: a sequence of {OID, value}
  # pairs, with the security versions nested one level down under ...13.1.2.
  defp sgx_extension(pck) do
    with value when is_binary(value) <- pck.extensions[@sgx_extension],
         {:ok, top} <- pairs(value),
         {:ok, tcb} <- pairs_of(top[@sgx_extension <> ".2"]),
         {0x04, <<fmspc::binary-6>>} <- top[@sgx_extension <> ".4"],
         {0x04, <<pce_id::binary-2>>} <- top[@sgx_extension <> ".3"],
         {0x04, <<cpu_svn::binary-16>>} <- tcb[@sgx_extension <> ".2.18"],
         {0x02, pce_svn} when byte_size(pce_svn) in 1..3 <- tcb[@sgx_extension <> ".2.17"] do
      {:ok, %{fmspc: fmspc, pce_id: pce_id, cpu_svn: :binary.bin_to_list(cpu_svn), pce_svn: :binary.decode_unsigned(pce_svn)}}
    else
      _ -> {:error, {:bad_certificate, "platform certificate has no usable SGX extension"}}
    end
  end

  defp pairs(der) do
    with {:ok, {0x30, body, _, <<>>}} <- Der.read(der), do: pairs_of({0x30, body})
  end

  defp pairs_of({0x30, body}) do
    with {:ok, items} <- Der.read_all(body) do
      Enum.reduce_while(items, {:ok, %{}}, fn {_, item, _}, {:ok, acc} ->
        case Der.read_all(item) do
          {:ok, [{0x06, id, _}, {tag, value, _}]} -> {:cont, {:ok, Map.put(acc, Der.oid(id), {tag, value})}}
          _ -> {:halt, :error}
        end
      end)
    end
  end

  defp pairs_of(_), do: :error

  # ---- Quoting enclave and quote signatures ------------------------------

  defp qe_report_signature(q, pck) do
    with {:ok, sig} <- Der.raw_signature_to_der(q.qe_report_signature),
         true <- Der.verify_p256(q.qe_report, sig, pck.public_key) do
      :ok
    else
      _ -> {:error, {:bad_qe_report_signature, nil}}
    end
  end

  # The quoting enclave commits to the attestation key it generated by putting
  # SHA-256(key || authentication data) into the first half of its report data.
  defp qe_report_data(q) do
    <<_::binary-320, committed::binary-32, _::binary-32>> = q.qe_report

    if :crypto.hash(:sha256, q.attestation_key <> q.qe_auth_data) == committed,
      do: :ok,
      else: {:error, {:attestation_key_not_bound, nil}}
  end

  defp qe_policy(qe_report, identity) do
    <<_cpu_svn::binary-16, misc_select::binary-4, _::binary-28, attributes::binary-16, _mr_enclave::binary-32, _::binary-32, mr_signer::binary-32, _::binary-96,
      prod_id::little-16, isv_svn::little-16, _::binary>> = qe_report

    with {:ok, want_signer} <- hex(identity["mrsigner"], 32),
         {:ok, want_misc} <- hex(identity["miscselect"], 4),
         {:ok, misc_mask} <- hex(identity["miscselectMask"], 4),
         {:ok, want_attrs} <- hex(identity["attributes"], 16),
         {:ok, attrs_mask} <- hex(identity["attributesMask"], 16) do
      cond do
        mr_signer != want_signer -> {:error, {:qe_identity_mismatch, :mrsigner}}
        (:binary.first(attributes) &&& 0x02) != 0 -> {:error, {:qe_identity_mismatch, :debug}}
        prod_id != identity["isvprodid"] -> {:error, {:qe_identity_mismatch, :isvprodid}}
        masked(misc_select, misc_mask) != masked(want_misc, misc_mask) -> {:error, {:qe_identity_mismatch, :miscselect}}
        masked(attributes, attrs_mask) != masked(want_attrs, attrs_mask) -> {:error, {:qe_identity_mismatch, :attributes}}
        true -> qe_level(isv_svn, identity["tcbLevels"] || [])
      end
    else
      _ -> {:error, {:bad_collateral, "qe_identity"}}
    end
  end

  defp qe_level(isv_svn, levels) do
    case Enum.find(levels, &(isv_svn >= get_in(&1, ["tcb", "isvsvn"]))) do
      %{"tcbStatus" => status} = level when status in @qe_statuses ->
        {:ok, %{status: status, advisories: level["advisoryIDs"] || []}}

      %{"tcbStatus" => status} ->
        {:error, {:unknown_tcb_status, status}}

      nil ->
        {:error, {:qe_below_minimum, isv_svn}}
    end
  end

  defp quote_signature(q) do
    with {:ok, sig} <- Der.raw_signature_to_der(q.signature),
         true <- Der.verify_p256(q.signed, sig, <<4, q.attestation_key::binary>>) do
      :ok
    else
      _ -> {:error, {:bad_quote_signature, nil}}
    end
  end

  # ---- TCB matching ------------------------------------------------------

  defp platform_tcb(tcb_info, q, platform) do
    tee_tcb_svn = :binary.bin_to_list(q.report.tee_tcb_svn)

    cond do
      tcb_info["id"] != "TDX" or (tcb_info["version"] || 0) < 3 ->
        {:error, {:wrong_tcb_info, {tcb_info["id"], tcb_info["version"]}}}

      hex(tcb_info["fmspc"], 6) != {:ok, platform.fmspc} ->
        {:error, {:fmspc_mismatch, Base.encode16(platform.fmspc)}}

      hex(tcb_info["pceId"], 2) != {:ok, platform.pce_id} ->
        {:error, {:pce_id_mismatch, Base.encode16(platform.pce_id)}}

      true ->
        with {:ok, level} <- tdx_level(tcb_info, platform, tee_tcb_svn),
             :ok <- module_identity(tcb_info, q.report, tee_tcb_svn),
             {:ok, level} <- relaunch(level, tcb_info, platform, q.tee_tcb_svn2) do
          {:ok, level}
        end
    end
  end

  # The platform level is the first, highest level whose every component the
  # platform meets; the TDX module's own level is then folded into it.
  defp tdx_level(tcb_info, platform, tee_tcb_svn) do
    with {:ok, level} <- find_level(tcb_info, platform, tee_tcb_svn),
         {:ok, module} <- module_level(tcb_info, tee_tcb_svn) do
      case module do
        nil ->
          {:ok, level}

        module ->
          {:ok,
           %{
             status: converge(level.status, module.status),
             advisories: Enum.uniq(level.advisories ++ module.advisories),
             date: Enum.min([level.date, module.date])
           }}
      end
    end
  end

  defp find_level(tcb_info, platform, tee_tcb_svn) do
    levels =
      (tcb_info["tcbLevels"] || [])
      |> Enum.map(fn level ->
        tcb = level["tcb"] || %{}

        %{
          sgx: svns(tcb["sgxtcbcomponents"]),
          pce: tcb["pcesvn"],
          tdx: svns(tcb["tdxtcbcomponents"]),
          status: level["tcbStatus"],
          advisories: level["advisoryIDs"] || [],
          date: level["tcbDate"] || ""
        }
      end)
      |> Enum.sort_by(&{&1.sgx, &1.pce, &1.tdx}, :desc)

    # When the module version (second byte) is non-zero, the first two TDX
    # components are judged by the module identity instead.
    skip = if Enum.at(tee_tcb_svn, 1) > 0, do: 2, else: 0

    cond do
      Enum.any?(levels, &(length(&1.sgx) != 16 or length(&1.tdx) != 16 or not is_integer(&1.pce))) ->
        {:error, {:bad_collateral, "tcb_info"}}

      true ->
        match =
          Enum.find(levels, fn l ->
            meets?(platform.cpu_svn, l.sgx) and platform.pce_svn >= l.pce and
              meets?(Enum.drop(tee_tcb_svn, skip), Enum.drop(l.tdx, skip))
          end)

        case match do
          nil -> {:error, {:no_matching_tcb_level, nil}}
          %{status: s} = l when s in @platform_statuses -> {:ok, Map.take(l, [:status, :advisories, :date])}
          %{status: s} -> {:error, {:unknown_tcb_status, s}}
        end
    end
  end

  defp svns(list) when is_list(list), do: Enum.map(list, &(&1["svn"] || 0))
  defp svns(_), do: []

  defp meets?(have, need), do: Enum.zip(have, need) |> Enum.all?(fn {h, n} -> h >= n end)

  defp module_identity_for(tcb_info, tee_tcb_svn) do
    case Enum.at(tee_tcb_svn, 1) do
      0 ->
        {:ok, nil}

      version ->
        wanted = "TDX_" <> String.pad_leading(Integer.to_string(version, 16), 2, "0")

        case Enum.find(tcb_info["tdxModuleIdentities"] || [], &(String.upcase(&1["id"] || "") == wanted)) do
          nil -> {:error, {:tdx_module_unknown, wanted}}
          identity -> {:ok, identity}
        end
    end
  end

  defp module_level(tcb_info, tee_tcb_svn) do
    with {:ok, identity} <- module_identity_for(tcb_info, tee_tcb_svn) do
      isv_svn = hd(tee_tcb_svn)

      case identity && Enum.find(identity["tcbLevels"] || [], &(isv_svn >= get_in(&1, ["tcb", "isvsvn"]))) do
        nil when identity == nil -> {:ok, nil}
        nil -> {:error, {:tdx_module_below_minimum, isv_svn}}
        %{"tcbStatus" => s} = l when s in @module_statuses -> {:ok, %{status: s, advisories: l["advisoryIDs"] || [], date: l["tcbDate"] || ""}}
        %{"tcbStatus" => s} -> {:error, {:unknown_tcb_status, s}}
      end
    end
  end

  # The TDX module that produced the report must be the one Intel signed.
  defp module_identity(tcb_info, report, tee_tcb_svn) do
    with {:ok, identity} <- module_identity_for(tcb_info, tee_tcb_svn),
         source when is_map(source) <- identity || tcb_info["tdxModule"],
         {:ok, signer} <- hex(source["mrsigner"], 48),
         {:ok, attrs} <- hex(source["attributes"], 8),
         {:ok, mask} <- hex(source["attributesMask"], 8) do
      cond do
        report.mr_signer_seam != signer -> {:error, {:tdx_module_mismatch, :mrsigner}}
        masked(report.seam_attributes, mask) != masked(attrs, mask) -> {:error, {:tdx_module_mismatch, :attributes}}
        masked(report.seam_attributes, invert(mask)) != <<0::64>> -> {:error, {:tdx_module_mismatch, :attributes}}
        true -> :ok
      end
    else
      {:error, _} = e -> e
      _ -> {:error, {:bad_collateral, "tcb_info"}}
    end
  end

  # A TDX 1.5 report also carries the security versions after a live module
  # update. When those are current but the launch-time ones are not, the fix
  # is to relaunch the machine, and the status says so.
  defp relaunch(level, _tcb_info, _platform, nil), do: {:ok, level}

  defp relaunch(level, tcb_info, platform, tee_tcb_svn2) do
    with {:ok, current} <- tdx_level(tcb_info, platform, :binary.bin_to_list(tee_tcb_svn2)) do
      {:ok, Map.put(level, :current, current.status)}
    end
  end

  defp final_status(level, qe_level) do
    status = converge(level.status, qe_level.status)
    current = level[:current] && converge(level.current, qe_level.status)
    advisories = Enum.uniq(level.advisories ++ qe_level.advisories)

    cond do
      status == "Revoked" or current == "Revoked" -> {:error, {:tcb_revoked, advisories}}
      current -> {:ok, relaunch_status(status, current), advisories}
      true -> {:ok, status, advisories}
    end
  end

  defp converge(_own, "Revoked"), do: "Revoked"
  defp converge(own, "OutOfDate") when own in ["UpToDate", "SWHardeningNeeded"], do: "OutOfDate"
  defp converge(own, "OutOfDate") when own in ["ConfigurationNeeded", "ConfigurationAndSWHardeningNeeded"], do: "OutOfDateConfigurationNeeded"
  defp converge(own, _component), do: own

  @configuration_needed ~w(ConfigurationNeeded OutOfDateConfigurationNeeded ConfigurationAndSWHardeningNeeded)

  defp relaunch_status(status, current)
       when status in ["OutOfDate", "OutOfDateConfigurationNeeded"] and
              current in ["UpToDate", "SWHardeningNeeded", "ConfigurationNeeded", "ConfigurationAndSWHardeningNeeded"] do
    if status in @configuration_needed or current in @configuration_needed,
      do: "TDRelaunchAdvisedConfigurationNeeded",
      else: "TDRelaunchAdvised"
  end

  defp relaunch_status(status, _current), do: status

  # ---- Collateral --------------------------------------------------------

  @doc """
  Fetches from Intel everything `verify/4` needs for `quote`: the TCB
  information for the platform family, the quoting-enclave identity, and the
  two revocation lists. No credentials are involved.

  The result is a map of strings (binary values are Base64), so it can be
  stored as JSON and reused until `"expires_at"`: the earliest `nextUpdate`
  among its parts, as Unix seconds.

  Options: `:http` — a module with `get/2` like `OmnigateControl.Attestation.Http`;
  `:pcs_url` — another service with Intel's PCS interface.
  """
  @spec fetch_collateral(binary, keyword) :: {:ok, collateral} | {:error, reason}
  def fetch_collateral(quote, opts \\ []) do
    http = Keyword.get(opts, :http, OmnigateControl.Attestation.Http)
    base = Keyword.get(opts, :pcs_url, @pcs_url)

    with {:ok, q} <- parse(quote),
         {:ok, [leaf | _]} <- unverified_pck(q),
         {:ok, platform} <- sgx_extension(leaf),
         ca = if(:binary.match(leaf.issuer, "Platform") != :nomatch, do: "platform", else: "processor"),
         fmspc = Base.encode16(platform.fmspc),
         {:ok, tcb, tcb_headers} <- get(http, "#{base}/tdx/certification/v4/tcb?fmspc=#{fmspc}"),
         {:ok, qe, qe_headers} <- get(http, "#{base}/tdx/certification/v4/qe/identity"),
         {:ok, pck_crl, crl_headers} <- get(http, "#{base}/sgx/certification/v4/pckcrl?ca=#{ca}&encoding=der"),
         {:ok, root_crl, _} <- get(http, @root_crl_url),
         {:ok, tcb_info, tcb_sig} <- split_signed(tcb, "tcbInfo"),
         {:ok, qe_identity, qe_sig} <- split_signed(qe, "enclaveIdentity"),
         {:ok, tcb_chain} <- chain_header(tcb_headers, ["tcb-info-issuer-chain", "sgx-tcb-info-issuer-chain"]),
         {:ok, qe_chain} <- chain_header(qe_headers, ["sgx-enclave-identity-issuer-chain"]),
         {:ok, crl_chain} <- chain_header(crl_headers, ["sgx-pck-crl-issuer-chain"]) do
      collateral = %{
        "tcb_info" => tcb_info,
        "tcb_info_signature" => tcb_sig,
        "tcb_info_issuer_chain" => tcb_chain,
        "qe_identity" => qe_identity,
        "qe_identity_signature" => qe_sig,
        "qe_identity_issuer_chain" => qe_chain,
        "pck_crl" => Base.encode64(pck_crl),
        "pck_crl_issuer_chain" => crl_chain,
        "root_ca_crl" => Base.encode64(root_crl),
        "fmspc" => fmspc,
        "pck_ca" => ca
      }

      {:ok, Map.put(collateral, "expires_at", collateral_expiry(collateral))}
    end
  end

  @doc "The FMSPC (platform family, hex) and issuing authority a quote's collateral is keyed by. Not verified."
  @spec collateral_key(binary) :: {:ok, {String.t(), String.t()}} | {:error, reason}
  def collateral_key(quote) do
    with {:ok, q} <- parse(quote), {:ok, [leaf | _]} <- unverified_pck(q), {:ok, platform} <- sgx_extension(leaf) do
      {:ok, {Base.encode16(platform.fmspc), if(:binary.match(leaf.issuer, "Platform") != :nomatch, do: "platform", else: "processor")}}
    end
  end

  defp unverified_pck(%{pck_cert_type: 5, pck_cert_data: pem}) do
    case parse_all(Der.pem_certs(pem)) do
      {:ok, [_ | _] = certs} -> {:ok, certs}
      {:ok, []} -> {:error, {:pck_chain_missing, 5}}
      error -> error
    end
  end

  defp unverified_pck(q), do: {:error, {:pck_chain_missing, q.pck_cert_type}}

  defp get(http, url) do
    case http.get(url, [{"accept", "*/*"}]) do
      {:ok, 200, headers, body} -> {:ok, body, headers}
      {:ok, status, _, _} -> {:error, {:collateral_unavailable, {url, status}}}
      {:error, reason} -> {:error, {:collateral_unavailable, {url, reason}}}
    end
  end

  # Intel signs the JSON text of the inner object exactly as sent, so it is
  # cut out of the response as bytes instead of being decoded and re-encoded.
  defp split_signed(body, key) do
    prefix = ~s({"#{key}":)

    with true <- String.starts_with?(body, prefix),
         [_ | _] = matches <- :binary.matches(body, ~s(,"signature":")),
         {at, len} = List.last(matches),
         signature = body |> binary_part(at + len, byte_size(body) - at - len) |> String.trim() |> String.trim_trailing(~s("})),
         true <- signature =~ ~r/\A[0-9a-fA-F]{128}\z/ do
      {:ok, binary_part(body, byte_size(prefix), at - byte_size(prefix)), signature}
    else
      _ -> {:error, {:bad_collateral, key}}
    end
  end

  defp chain_header(headers, names) do
    case Enum.find(headers, fn {k, _} -> String.downcase(to_string(k)) in names end) do
      {_, value} -> {:ok, URI.decode(to_string(value))}
      nil -> {:error, {:bad_collateral, hd(names)}}
    end
  end

  defp collateral_expiry(c) do
    json_dates =
      for name <- ["tcb_info", "qe_identity"], {:ok, json} <- [decode_json(c[name])], {:ok, t} <- [date(json["nextUpdate"])], do: t

    crl_dates =
      for name <- ["pck_crl", "root_ca_crl"], {:ok, der} <- [Base.decode64(c[name])], {:ok, crl} <- [Der.parse_crl(der)], crl.next_update, do: crl.next_update

    Enum.min(json_dates ++ crl_dates, fn -> 0 end)
  end

  # ---- Helpers -----------------------------------------------------------

  defp field(map, name) do
    case map[name] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:collateral_missing, name}}
    end
  end

  defp base64(map, name) do
    with {:ok, value} <- field(map, name) do
      Base.decode64(value) |> or_error({:bad_collateral, name})
    end
  end

  defp or_error({:ok, _} = ok, _), do: ok
  defp or_error(_, reason), do: {:error, reason}

  defp hex(value, size) when is_binary(value) do
    case Base.decode16(value, case: :mixed) do
      {:ok, bin} when byte_size(bin) == size -> {:ok, bin}
      _ -> :error
    end
  end

  defp hex(_, _), do: :error

  defp masked(a, mask) do
    Enum.zip(:binary.bin_to_list(a), :binary.bin_to_list(mask)) |> Enum.map(fn {x, y} -> x &&& y end) |> :binary.list_to_bin()
  end

  defp invert(bin), do: for(<<x <- bin>>, into: <<>>, do: <<bxor(x, 0xFF)>>)

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, DateTime.to_unix(dt)}
      _ -> :error
    end
  end

  defp date(_), do: :error

  defp date!(value) do
    case date(value) do
      {:ok, t} -> t
      :error -> nil
    end
  end

  defp decode_json(text) do
    case JSON.decode(text) do
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  end
end
