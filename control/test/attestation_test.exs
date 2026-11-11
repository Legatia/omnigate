defmodule OmnigateControl.AttestationTest do
  @moduledoc """
  Offline checks of attestation verification on a saved real report
  (`test/fixtures/attestation`): one NEAR AI Cloud response fetched on
  11 November 2026 with its nonce, the Intel collateral per platform family
  as it was then, a root that is not Intel's, and a throwaway PKI with
  revocation lists. The saved report must verify at the recorded time, and
  every tampering must fail with its own error. Nothing here uses the
  network: collateral comes from the fixture and GPU evidence is skipped.
  """
  use ExUnit.Case, async: true

  alias OmnigateControl.Attestation.{Der, Near, Tdx}

  @fixtures Path.expand("fixtures/attestation", __DIR__)

  test "the saved report verifies and every tampering fails with its own error" do
    Process.put(:failed, [])
    Process.put(:count, 0)
    run()
    assert Process.get(:failed) == []
    # A check that silently stopped running would otherwise go unnoticed.
    assert Process.get(:count) == 96
  end

  defp json(text), do: JSON.decode!(text)
  defp encode(value), do: JSON.encode!(value)
  defp fx(name), do: File.read!(Path.join(@fixtures, name))
  defp section(_name), do: :ok

  defp check(name, got, expected) do
    ok =
      case expected do
        f when is_function(f, 1) -> f.(got)
        _ -> got == expected
      end

    Process.put(:count, Process.get(:count) + 1)
    if !ok, do: Process.put(:failed, [{name, inspect(got, limit: 12, printable_limit: 200)} | Process.get(:failed)])
  end

  # Matches {:error, {reason, _}} at any nesting depth of the report wrappers.
  defp fails(reason), do: fn got -> innermost(got) == reason end
  defp fails(reason, detail), do: fn got -> innermost_pair(got) == {reason, detail} end

  defp innermost(got), do: got |> innermost_pair() |> elem(0)
  defp innermost_pair({:error, {wrapper, {_index, {r, d}}}}) when wrapper == :model_report_failed and is_atom(r), do: {r, d}
  defp innermost_pair({:error, {wrapper, {r, d}}}) when wrapper == :gateway_report_failed and is_atom(r), do: {r, d}
  defp innermost_pair({:error, {r, d}}), do: {r, d}
  defp innermost_pair(other), do: {other, nil}

  defp flip(bin, at) do
    <<a::binary-size(^at), b, rest::binary>> = bin
    <<a::binary, Bitwise.bxor(b, 1), rest::binary>>
  end

  defp run do
    body = json(fx("report.json"))
    nonce = fx("report_nonce.txt")
    model = fx("report_model.txt")
    now = String.to_integer(fx("verified_at.txt"))
    sets = json(fx("collateral.json"))

    collateral_for = fn quote, sets ->
      with {:ok, {fmspc, ca}} <- Tdx.collateral_key(quote), do: {:ok, Map.fetch!(sets, fmspc <> "/" <> ca)}
    end

    collateral = &collateral_for.(&1, sets)
    opts = [model: model, now: now, collateral: collateral, gpu: :skip]
    gw = body["gateway_attestation"]
    [cand] = body["model_attestations"]
    gw_quote = Base.decode16!(gw["intel_quote"], case: :mixed)
    {:ok, gw_coll} = collateral.(gw_quote)
    with_gw = fn gw2 -> Near.verify_all(Map.put(body, "gateway_attestation", gw2), nonce, opts) end
    with_cand = fn c2 -> Near.verify_all(Map.put(body, "model_attestations", [c2]), nonce, opts) end
    with_quote = fn q -> with_gw.(Map.put(gw, "intel_quote", Base.encode16(q, case: :lower))) end
    with_coll = fn key, f -> Near.check_report(gw, nonce, Keyword.put(opts, :collateral, fn _ -> {:ok, Map.update!(gw_coll, key, f)} end)) end

    section("the saved real report")
    verified = Near.verify_all(body, nonce, opts)

    check(
      "gateway and model report verify offline at the recorded time",
      verified,
      &match?({:ok, %{gateway: %{status: "UpToDate"}, models: [%{status: "UpToDate"}]}}, &1)
    )

    {:ok, v} = verified

    check(
      "the result names the model and both signing identities",
      {hd(v.models).model, v.gateway.signing_algo, byte_size(v.gateway.signing_address)},
      {model, "ed25519", 64}
    )

    check("gateway report carries a TLS fingerprint, bound into the quote", v.gateway.tls_cert_fingerprint, gw["tls_cert_fingerprint"])

    check(
      "the right peer key marks the connection as bound",
      Near.check_report(gw, nonce, opts ++ [peer_spki_sha256: gw["tls_cert_fingerprint"]]),
      &match?({:ok, %{tls_bound: true}}, &1)
    )

    check(
      "Tdx.verify returns the measurements",
      Tdx.verify(gw_quote, gw_coll, now),
      &match?({:ok, %{status: "UpToDate", version: 4, mr_td: <<_::binary-48>>, report_data: <<_::binary-64>>}}, &1)
    )

    section("the quote")
    check("a flipped bit in the quote signature", with_quote.(flip(gw_quote, 640)), fails(:bad_quote_signature))
    check("a flipped bit in the signed report body (report data)", with_quote.(flip(gw_quote, 600)), fails(:bad_quote_signature))
    check("a flipped bit in a measurement (MRTD)", with_quote.(flip(gw_quote, 190)), fails(:bad_quote_signature))
    check("a flipped bit in the attestation key", with_quote.(flip(gw_quote, 710)), fails(:attestation_key_not_bound))
    check("a flipped bit in the quoting enclave's report", with_quote.(flip(gw_quote, 800)), fails(:bad_qe_report_signature))
    check("a flipped bit in the quoting enclave's report signature", with_quote.(flip(gw_quote, 1160)), fails(:bad_qe_report_signature))
    check("a truncated quote", with_quote.(binary_part(gw_quote, 0, 500)), fails(:bad_quote))
    check("a quote of another version", with_quote.(<<3, binary_part(gw_quote, 1, byte_size(gw_quote) - 1)::binary>>), fails(:unsupported_quote))
    check("no quote at all", with_gw.(Map.delete(gw, "intel_quote")), fails(:bad_report))

    check(
      "the model's quote presented as the gateway's (other signer and config)",
      with_gw.(Map.put(gw, "intel_quote", cand["intel_quote"])),
      fails(:signer_not_bound)
    )

    check("a flipped bit in the platform certificate inside the quote", with_quote.(flip(gw_quote, 1500)), fn got ->
      elem(elem(got, 1), 0) == :gateway_report_failed
    end)

    section("freshness and signer binding")
    other = String.duplicate("ab", 32)
    check("another nonce", Near.verify_all(body, other, opts), fails(:nonce_mismatch, :echo))

    check(
      "another nonce, with the echo forged to match",
      Near.verify_all(Map.put(body, "gateway_attestation", Map.put(gw, "request_nonce", other)), other, opts),
      fails(:nonce_mismatch, :quote)
    )

    check("only the echoed nonce altered", with_gw.(Map.put(gw, "request_nonce", other)), fails(:nonce_mismatch, :echo))
    check("the echoed report data altered", with_gw.(Map.put(gw, "report_data", String.duplicate("00", 64))), fails(:report_data_mismatch))
    check("a malformed nonce", Near.verify_all(body, "abc", opts), fails(:bad_nonce))
    check("another signing address", with_gw.(Map.put(gw, "signing_address", String.duplicate("11", 32))), fails(:signer_not_bound))
    check("the same address under another algorithm", with_gw.(Map.put(gw, "signing_algo", "ecdsa")), fails(:unsupported_signing_identity))
    check("an unknown signing algorithm", with_gw.(Map.put(gw, "signing_algo", "rsa")), fails(:unsupported_signing_identity))
    check("another TLS fingerprint in the report", with_gw.(Map.put(gw, "tls_cert_fingerprint", String.duplicate("22", 32))), fails(:signer_not_bound))
    check("the TLS fingerprint removed from the report", with_gw.(Map.delete(gw, "tls_cert_fingerprint")), fails(:signer_not_bound))

    check(
      "a peer key that is not the attested one",
      Near.check_report(gw, nonce, opts ++ [peer_spki_sha256: String.duplicate("33", 32)]),
      fails(:tls_fingerprint_mismatch)
    )

    check(
      "a peer key given but no fingerprint in the report",
      Near.check_report(Map.delete(gw, "tls_cert_fingerprint"), nonce, opts ++ [peer_spki_sha256: gw["tls_cert_fingerprint"]]),
      fails(:tls_fingerprint_missing)
    )

    section("configuration and event log")
    compose = gw["info"]["tcb_info"]["app_compose"]
    check("app_compose altered by one character", with_gw.(put_in(gw, ["info", "tcb_info", "app_compose"], compose <> " ")), fails(:configuration_mismatch))
    check("app_compose removed", with_gw.(put_in(gw, ["info", "tcb_info"], Map.delete(gw["info"]["tcb_info"], "app_compose"))), fails(:bad_report))
    check("tcb_info given as JSON text still verifies", with_gw.(put_in(gw, ["info", "tcb_info"], encode(gw["info"]["tcb_info"]))), &match?({:ok, _}, &1))
    events = json(gw["event_log"])
    at = Enum.find_index(events, &(&1["imr"] == 3 and (&1["event_payload"] || "") != ""))
    payload = fn e -> Map.update!(e, "event_payload", &(String.slice(&1, 0..-3//1) <> "00")) end
    log = fn list -> with_gw.(Map.put(gw, "event_log", encode(list))) end
    check("an event payload altered", log.(List.update_at(events, at, payload)), fails(:event_log_mismatch))

    check(
      "an event with a stated digest that disagrees with its content",
      log.(List.update_at(events, at, &Map.put(&1, "digest", String.duplicate("00", 48)))),
      fails(:event_digest_mismatch)
    )

    e = Enum.at(events, at)
    right = :crypto.hash(:sha384, <<e["event_type"]::little-32, ":", e["event"]::binary, ":", Base.decode16!(e["event_payload"], case: :mixed)::binary>>)

    check(
      "an event with the right stated digest still verifies",
      log.(List.update_at(events, at, &Map.put(&1, "digest", Base.encode16(right, case: :lower)))),
      &match?({:ok, _}, &1)
    )

    check("an event dropped", log.(List.delete_at(events, at)), fails(:event_log_mismatch))

    check(
      "an event added",
      log.(events ++ [%{"imr" => 3, "event_type" => 134_217_729, "event" => "extra", "event_payload" => "00", "digest" => ""}]),
      fails(:event_log_mismatch)
    )

    check("the event log removed", with_gw.(Map.delete(gw, "event_log")), fails(:bad_report))
    check("the model report's event log (a list) altered", with_cand.(Map.update!(cand, "event_log", &List.delete_at(&1, -1))), fails(:event_log_mismatch))
    check("replay_rtmr3 accepts a list and JSON text alike", Near.replay_rtmr3(events) == Near.replay_rtmr3(gw["event_log"]), true)

    section("Intel collateral")
    tamper = &String.replace(&1, "UpToDate", "UpToDatf", global: false)
    check("TCB information altered", with_coll.("tcb_info", tamper), fails(:bad_collateral_signature, "tcb_info"))

    check(
      "TCB information signature altered",
      with_coll.("tcb_info_signature", &(String.slice(&1, 0..-3//1) <> "00")),
      fails(:bad_collateral_signature, "tcb_info")
    )

    check("quoting-enclave identity altered", with_coll.("qe_identity", tamper), fails(:bad_collateral_signature, "qe_identity"))

    check(
      "TCB information of another platform family",
      Near.check_report(gw, nonce, Keyword.put(opts, :collateral, fn _ -> collateral.(Base.decode16!(cand["intel_quote"], case: :mixed)) end)),
      fails(:fmspc_mismatch)
    )

    check("platform revocation list altered", with_coll.("pck_crl", fn b64 -> b64 |> Base.decode64!() |> flip(100) |> Base.encode64() end), fn got ->
      innermost(got) in [:bad_crl_signature, :bad_crl, :crl_issuer_mismatch]
    end)

    check(
      "root revocation list missing",
      Near.check_report(gw, nonce, Keyword.put(opts, :collateral, fn _ -> {:ok, Map.delete(gw_coll, "root_ca_crl")} end)),
      fails(:collateral_missing, "root_ca_crl")
    )

    check(
      "the signer chain of the TCB information replaced by the platform chain",
      with_coll.("tcb_info_issuer_chain", fn _ -> elem(Tdx.parse(gw_quote), 1).pck_cert_data end),
      fn got -> innermost(got) in [:bad_certificate_chain, :bad_collateral_signature, :crl_missing] end
    )

    check("collateral used after it expired (60 days later)", Near.check_report(gw, nonce, Keyword.put(opts, :now, now + 60 * 86_400)), fn got ->
      innermost(got) in [:collateral_expired, :crl_expired]
    end)

    check("collateral used before it was issued (a year earlier)", Near.check_report(gw, nonce, Keyword.put(opts, :now, now - 365 * 86_400)), fn got ->
      innermost(got) in [:collateral_not_yet_valid, :crl_not_yet_valid, :certificate_not_yet_valid]
    end)

    check(
      "collateral cannot be fetched",
      Near.check_report(gw, nonce, Keyword.put(opts, :collateral, fn _ -> {:error, {:collateral_unavailable, :timeout}} end)),
      fails(:collateral_unavailable)
    )

    section("trust anchor and revocation")
    foreign = fx("other_root.der")

    check("a trust anchor that is not Intel's", Near.check_report(gw, nonce, opts ++ [trusted_root_der: foreign]), fn got ->
      innermost(got) in [:crl_issuer_mismatch, :bad_crl_signature]
    end)

    pem = fn der -> "-----BEGIN CERTIFICATE-----\n" <> Base.encode64(der) <> "\n-----END CERTIFICATE-----\n" end
    [leaf, inter | _] = Der.pem_certs(elem(Tdx.parse(gw_quote), 1).pck_cert_data)

    check(
      "a platform chain that ends in a foreign root",
      Near.check_report(
        gw,
        nonce,
        Keyword.put(opts, :collateral, fn _ -> {:ok, Map.put(gw_coll, "pck_certificate_chain", pem.(leaf) <> pem.(inter) <> pem.(foreign))} end)
      ),
      fails(:untrusted_root, :pck)
    )

    check(
      "a platform chain without its intermediate",
      Near.check_report(gw, nonce, Keyword.put(opts, :collateral, fn _ -> {:ok, Map.put(gw_coll, "pck_certificate_chain", pem.(leaf))} end)),
      fn got -> innermost(got) in [:bad_certificate_chain, :untrusted_root] end
    )

    p = &fx("pki/" <> &1)
    pki = [trusted_root_der: p.("root.der")]
    path = fn leaf, root_crl -> Tdx.verify_certificate_path([p.(leaf), p.("inter.der"), p.("root.der")], p.(root_crl), p.("inter_crl.der"), now, pki) end
    check("private PKI: a good leaf verifies", path.("leaf2.der", "root_crl.der"), &match?({:ok, [_, _]}, &1))
    check("private PKI: a revoked leaf", path.("leaf1.der", "root_crl.der"), fails(:revoked, :path))
    check("private PKI: a revoked intermediate", path.("leaf2.der", "root_crl_revoking.der"), fails(:revoked, :path))

    check(
      "private PKI: the same chain under Intel's root",
      Tdx.verify_certificate_path([p.("leaf2.der"), p.("inter.der")], p.("root_crl.der"), p.("inter_crl.der"), now),
      fn got -> innermost(got) in [:crl_issuer_mismatch, :bad_crl_signature] end
    )

    check(
      "private PKI: a leaf used as a certificate authority",
      Tdx.verify_certificate_path([p.("leaf2.der"), p.("leaf1.der"), p.("inter.der")], p.("root_crl.der"), p.("inter_crl.der"), now, pki),
      fn got -> innermost(got) in [:bad_certificate_chain, :issuer_not_a_ca, :bad_crl_signature, :crl_issuer_mismatch] end
    )

    {:ok, real_crl} = Der.parse_crl(Base.decode64!(gw_coll["pck_crl"]))
    {:ok, real_root_crl} = Der.parse_crl(Base.decode64!(gw_coll["root_ca_crl"]))

    check(
      "Intel's platform CRL parses to the 57 serials openssl lists, the root CRL to none",
      {MapSet.size(real_crl.revoked), MapSet.size(real_root_crl.revoked)},
      {57, 0}
    )

    check("pinned root is the certificate Intel publishes", Tdx.intel_root_der(), fx("intel_root.cer"))

    section("policy")

    check(
      "a policy that does not accept UpToDate",
      Near.verify_all(body, nonce, Keyword.put(opts, :accepted_statuses, ["OutOfDate"])),
      fails(:tcb_status_not_accepted)
    )

    check("debug mode", Tdx.check_td_attributes(<<1, 0, 0, 16, 0, 0, 0, 0>>), fails(:debug_enabled))
    check("SEPT_VE_DISABLE cleared", Tdx.check_td_attributes(<<0::64>>), fails(:sept_ve_disable_not_set))
    check("migratable", Tdx.check_td_attributes(<<0, 0, 0, 0x30, 0, 0, 0, 0>>), fails(:td_migratable))
    check("reserved attribute bit", Tdx.check_td_attributes(<<0, 1, 0, 16, 0, 0, 0, 0>>), fails(:td_attributes_reserved_bits))
    check("the real attributes pass", Tdx.check_td_attributes(<<0, 0, 0, 16, 0, 0, 0, 0>>), :ok)

    section("model reports")
    check("model requested, no model reports", Near.verify_all(Map.delete(body, "model_attestations"), nonce, opts), fails(:model_reports_missing))
    check("model requested, empty list", Near.verify_all(Map.put(body, "model_attestations", []), nonce, opts), fails(:model_reports_missing))
    check("a report for another model", Near.verify_all(body, nonce, Keyword.put(opts, :model, "Qwen/Qwen3.8-27B")), fails(:wrong_model))

    check(
      "one bad candidate among good ones fails everything",
      Near.verify_all(Map.put(body, "model_attestations", [cand, Map.put(cand, "request_nonce", other)]), nonce, opts),
      fn got -> match?({:error, {:model_report_failed, {1, {:nonce_mismatch, :echo}}}}, got) end
    )

    check("no gateway report", Near.verify_all(Map.delete(body, "gateway_attestation"), nonce, opts), fails(:gateway_report_missing))
    check("GPU evidence required but absent", Near.check_report(gw, nonce, Keyword.put(opts, :gpu, :require)), fails(:gpu_evidence_missing))

    check(
      "GPU evidence with another nonce is refused before NVIDIA is asked",
      Near.check_gpu(Map.put(cand, "nvidia_payload", encode(%{"nonce" => other, "arch" => "HOPPER", "evidence_list" => []})), nonce),
      fails(:nonce_mismatch, :gpu)
    )

    check(
      "no model requested: gateway only",
      Near.verify_all(Map.delete(body, "model_attestations"), nonce, Keyword.delete(opts, :model)),
      &match?({:ok, %{models: []}}, &1)
    )

    section("response signatures (Ed25519, with a key made here)")
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {pub2, _} = :crypto.generate_key(:eddsa, :ed25519)
    hexl = &Base.encode16(&1, case: :lower)
    signer = hexl.(pub)
    vr = %{gateway: %{v.gateway | signing_address: signer}, models: [%{hd(v.models) | signing_address: signer}], nonce: nonce, verified_at: now}
    req = ~s({"model":"#{model}","messages":[{"role":"user","content":"hi"}]})
    resp = ~s({"id":"chatcmpl-1","choices":[]})
    hashes = hexl.(:crypto.hash(:sha256, req)) <> ":" <> hexl.(:crypto.hash(:sha256, resp))

    sig = fn kind, text ->
      %{
        "signature_kind" => kind,
        "text" => text,
        "signing_algo" => "ed25519",
        "signing_address" => signer,
        "signature" => hexl.(:crypto.sign(:eddsa, :none, text, [priv, :ed25519]))
      }
    end

    tee = sig.("provider_tee", model <> ":" <> hashes)
    gws = sig.("gateway", hashes)
    vs = &Near.verify_response_signature(&1, req, resp, model, vr)
    check("a model signature over the exact bytes", vs.(tee), {:ok, :provider_tee})
    check("a gateway signature over the exact bytes", vs.(gws), {:ok, :gateway})
    check("a response that differs by one byte", Near.verify_response_signature(tee, req, resp <> " ", model, vr), fails(:signature_text_mismatch))
    check("a request that differs by one byte", Near.verify_response_signature(gws, req <> " ", resp, model, vr), fails(:signature_text_mismatch))
    check("a model signature for another model name", Near.verify_response_signature(tee, req, resp, "other/model", vr), fails(:signature_text_mismatch))
    check("a gateway-shaped text labelled as a model signature", vs.(sig.("provider_tee", hashes)), fails(:signature_text_mismatch))
    check("a forged signature", vs.(Map.put(tee, "signature", String.duplicate("00", 64))), fails(:bad_response_signature))
    check("a valid signature by a key that was not attested", vs.(%{tee | "signing_address" => hexl.(pub2)}), fails(:bad_response_signature))
    check("a signer no verified report names", Near.verify_response_signature(tee, req, resp, model, %{vr | models: v.models}), fails(:signer_not_verified, 0))

    check(
      "a signer two verified reports name",
      Near.verify_response_signature(tee, req, resp, model, %{vr | models: vr.models ++ vr.models}),
      fails(:signer_not_verified, 2)
    )

    check(
      "a gateway signature when the gateway report names another key",
      Near.verify_response_signature(gws, req, resp, model, %{vr | gateway: v.gateway}),
      fails(:signer_not_verified, 0)
    )

    check("no signature kind", vs.(Map.delete(tee, "signature_kind")), fails(:unknown_signature_kind))
    check("an unfamiliar signature kind", vs.(Map.put(tee, "signature_kind", "relay")), fails(:unknown_signature_kind))

    check(
      "an 'unavailable' answer with status 200",
      vs.(%{"error_code" => "signature_unavailable", "message" => "stream disconnected"}),
      fails(:signature_unavailable)
    )

    check("a model signature without knowing the model", Near.verify_response_signature(tee, req, resp, nil, vr), fails(:model_required))
    ecdsa_checks(vr, req, resp, hashes, model)

    :ok
  end

  # ECDSA: a secp256k1 key made here signs the EIP-191 digest; the recovery id
  # is not returned by :crypto, so both are tried and exactly one must verify.
  defp ecdsa_checks(vr, req, resp, hashes, model) do
    alias OmnigateControl.Attestation.EthSignature
    hexl = &Base.encode16(&1, case: :lower)
    {<<4, xy::binary-64>>, priv} = :crypto.generate_key(:ecdh, :secp256k1)
    address = hexl.(EthSignature.address(xy))

    vr = %{
      vr
      | gateway: %{vr.gateway | signing_algo: "ecdsa", signing_address: address},
        models: [%{hd(vr.models) | signing_algo: "ecdsa", signing_address: address}]
    }

    # Returns the two candidate signatures, with recovery id 27 and 28.
    sign = fn kind, text ->
      digest = EthSignature.keccak256(<<0x19, "Ethereum Signed Message:
", Integer.to_string(byte_size(text))::binary, text::binary>>)
      der = :crypto.sign(:ecdsa, :sha256, {:digest, digest}, [priv, :secp256k1])
      {:ok, {0x30, body, _, _}} = OmnigateControl.Attestation.Der.read(der)
      {:ok, [{2, r, _}, {2, s, _}]} = OmnigateControl.Attestation.Der.read_all(body)
      rs = <<:binary.decode_unsigned(r)::256, :binary.decode_unsigned(s)::256>>

      for v <- [27, 28] do
        %{"signature_kind" => kind, "text" => text, "signing_algo" => "ecdsa", "signing_address" => "0x" <> address, "signature" => "0x" <> hexl.(rs <> <<v>>)}
      end
    end

    verify = fn sigs, reports -> Enum.map(sigs, &Near.verify_response_signature(&1, req, resp, model, reports)) end

    check("ECDSA model signature: exactly one recovery id verifies", Enum.sort(verify.(sign.("provider_tee", model <> ":" <> hashes), vr)), [
      {:error, {:bad_response_signature, "ecdsa"}},
      {:ok, :provider_tee}
    ])

    check("ECDSA gateway signature: exactly one recovery id verifies", Enum.sort(verify.(sign.("gateway", hashes), vr)), [
      {:error, {:bad_response_signature, "ecdsa"}},
      {:ok, :gateway}
    ])

    other = Enum.map(sign.("gateway", hashes), &%{&1 | "signing_address" => "0x" <> String.duplicate("11", 20)})

    check("ECDSA signature attributed to another address", verify.(other, vr), [
      {:error, {:bad_response_signature, "ecdsa"}},
      {:error, {:bad_response_signature, "ecdsa"}}
    ])

    ed_reports = %{vr | gateway: %{vr.gateway | signing_algo: "ed25519"}}
    check("ECDSA signature against a report attested for Ed25519", Enum.filter(verify.(sign.("gateway", hashes), ed_reports), &match?({:ok, _}, &1)), [])

    check(
      "an unknown signing algorithm is refused",
      verify.(Enum.map(sign.("gateway", hashes), &%{&1 | "signing_algo" => "rsa"}), vr) |> hd(),
      fails(:unsupported_signing_identity)
    )

    check(
      "Keccak-256 of the empty string and of \"abc\"",
      {hexl.(EthSignature.keccak256("")), hexl.(EthSignature.keccak256("abc"))},
      {"c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"}
    )

    known =
      Base.decode16!("ddd0a7290af9526056b4e35a077b9a11b513aa0028ec6c9880948544508f3c63265e99e47ad31bb2cab9646c504576b3abc6939a1710afc08cbf3034d73214b81c",
        case: :lower
      )

    check(
      "EIP-191 vector from the ethers documentation (\"hello world\")",
      EthSignature.recover_personal("hello world", known),
      {:ok, Base.decode16!("14791697260E4c9A71f18484C9f997B308e59325", case: :mixed)}
    )

    check(
      "the address of private key 1",
      hexl.(EthSignature.address(elem(:crypto.generate_key(:ecdh, :secp256k1, <<1::256>>), 0) |> binary_part(1, 64))),
      "7e5f4552091a69125d5dfcb7b8c2659029395bdf"
    )
  end
end
