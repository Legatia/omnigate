defmodule OmnigateControl.Attestation.Der do
  @moduledoc """
  The small part of DER, X.509 and CRL parsing that attestation needs.

  Intel's attestation PKI uses one algorithm throughout: ECDSA over P-256
  with SHA-256. This module parses exactly that and refuses everything else,
  so a certificate with another key or signature type is an error instead of
  something that might be accepted by accident. It keeps the raw bytes of the
  signed parts, because signatures are checked over the bytes as they were
  sent, never over a re-encoding.
  """

  import Bitwise

  @ecdsa_sha256 "1.2.840.10045.4.3.2"
  @ec_public_key "1.2.840.10045.2.1"
  @prime256v1 "1.2.840.10045.3.1.7"
  @basic_constraints "2.5.29.19"
  @gregorian_epoch 62_167_219_200

  @type cert :: %{
          der: binary,
          tbs: binary,
          signature: binary,
          serial: non_neg_integer,
          issuer: binary,
          subject: binary,
          not_before: integer,
          not_after: integer,
          public_key: binary,
          extensions: %{optional(String.t()) => binary},
          ca: boolean
        }

  @type crl :: %{
          tbs: binary,
          signature: binary,
          issuer: binary,
          this_update: integer,
          next_update: integer | nil,
          revoked: MapSet.t(non_neg_integer)
        }

  # ---- DER ---------------------------------------------------------------

  @doc """
  Reads one DER element. Returns `{:ok, {tag, content, whole_element, rest}}`.
  Only single-byte tags and definite lengths exist in DER certificates.
  """
  @spec read(binary) :: {:ok, {byte, binary, binary, binary}} | :error
  def read(<<tag, len, rest::binary>> = all) when len < 0x80 and (tag &&& 0x1F) != 0x1F do
    take(tag, len, rest, all, 2)
  end

  def read(<<tag, 0x81, len, rest::binary>> = all) when len >= 0x80 and (tag &&& 0x1F) != 0x1F do
    take(tag, len, rest, all, 3)
  end

  def read(<<tag, 0x82, len::16, rest::binary>> = all) when len > 0xFF and (tag &&& 0x1F) != 0x1F do
    take(tag, len, rest, all, 4)
  end

  def read(<<tag, 0x83, len::24, rest::binary>> = all) when len > 0xFFFF and (tag &&& 0x1F) != 0x1F do
    take(tag, len, rest, all, 5)
  end

  def read(_), do: :error

  defp take(tag, len, rest, all, header) do
    case rest do
      <<content::binary-size(^len), tail::binary>> ->
        {:ok, {tag, content, binary_part(all, 0, header + len), tail}}

      _ ->
        :error
    end
  end

  @doc "Reads every element of a constructed value. Returns `{:ok, [{tag, content, whole}]}`."
  @spec read_all(binary) :: {:ok, [{byte, binary, binary}]} | :error
  def read_all(bin), do: read_all(bin, [])

  defp read_all(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp read_all(bin, acc) do
    case read(bin) do
      {:ok, {tag, content, whole, rest}} -> read_all(rest, [{tag, content, whole} | acc])
      :error -> :error
    end
  end

  @doc "Decodes the content of an OBJECT IDENTIFIER into dotted form."
  @spec oid(binary) :: String.t()
  def oid(<<first, rest::binary>>) do
    [div(first, 40), rem(first, 40) | oid_arcs(rest, 0, [])] |> Enum.join(".")
  end

  def oid(_), do: ""

  defp oid_arcs(<<>>, _acc, out), do: Enum.reverse(out)
  defp oid_arcs(<<1::1, v::7, rest::binary>>, acc, out), do: oid_arcs(rest, (acc <<< 7) + v, out)
  defp oid_arcs(<<0::1, v::7, rest::binary>>, acc, out), do: oid_arcs(rest, 0, [(acc <<< 7) + v | out])

  # ---- Certificates ------------------------------------------------------

  @doc """
  Splits a PEM bundle into the DER of each certificate, in order. Anything
  outside the `CERTIFICATE` blocks (including a trailing NUL, which quotes
  carry) is ignored.
  """
  @spec pem_certs(binary) :: [binary]
  def pem_certs(pem) do
    ~r/-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----/s
    |> Regex.scan(pem, capture: :all_but_first)
    |> Enum.flat_map(fn [body] ->
      case Base.decode64(String.replace(body, ~r/\s/, "")) do
        {:ok, der} -> [der]
        :error -> []
      end
    end)
  end

  @doc "Parses one certificate. Only ECDSA P-256 / SHA-256 certificates are accepted."
  @spec parse_cert(binary) :: {:ok, cert} | {:error, {:bad_certificate, String.t()}}
  def parse_cert(der) do
    with {:ok, {0x30, body, _, <<>>}} <- read(der),
         {:ok, [{0x30, tbs_body, tbs}, {0x30, sig_alg, _}, {0x03, <<0, signature::binary>>, _}]} <-
           read_all(body),
         :ok <- expect_alg(sig_alg, @ecdsa_sha256),
         {:ok, fields} <- read_all(tbs_body),
         fields = drop_version(fields),
         [{0x02, serial, _}, {0x30, inner_alg, _}, {0x30, _, issuer}, {0x30, validity, _}, {0x30, _, subject}, {0x30, spki, _} | tail] <-
           fields,
         :ok <- expect_alg(inner_alg, @ecdsa_sha256),
         {:ok, [{t1, nb, _}, {t2, na, _}]} <- read_all(validity),
         {:ok, not_before} <- time(t1, nb),
         {:ok, not_after} <- time(t2, na),
         {:ok, public_key} <- p256_key(spki),
         {:ok, extensions} <- extensions(tail) do
      {:ok,
       %{
         der: der,
         tbs: tbs,
         signature: signature,
         serial: :binary.decode_unsigned(serial),
         issuer: issuer,
         subject: subject,
         not_before: not_before,
         not_after: not_after,
         public_key: public_key,
         extensions: extensions,
         ca: ca?(extensions)
       }}
    else
      {:error, {:bad_certificate, _}} = e -> e
      _ -> {:error, {:bad_certificate, "not a well-formed ECDSA P-256 certificate"}}
    end
  end

  @doc """
  The SHA-256 of a certificate's SubjectPublicKeyInfo, the value a TLS
  fingerprint or key pin refers to. Works for a certificate with any key
  type, since it only cuts the field out.
  """
  @spec spki_sha256(binary) :: {:ok, binary} | {:error, {:bad_certificate, String.t()}}
  def spki_sha256(der) do
    with {:ok, {0x30, body, _, _}} <- read(der),
         {:ok, {0x30, tbs_body, _, _}} <- read(body),
         {:ok, fields} <- read_all(tbs_body),
         [_serial, _alg, _issuer, _validity, _subject, {0x30, _, spki} | _] <- drop_version(fields) do
      {:ok, :crypto.hash(:sha256, spki)}
    else
      _ -> {:error, {:bad_certificate, "no public key field found"}}
    end
  end

  defp drop_version([{0xA0, _, _} | rest]), do: rest
  defp drop_version(rest), do: rest

  defp expect_alg(alg, wanted) do
    case read(alg) do
      {:ok, {0x06, oid_bytes, _, _}} ->
        if oid(oid_bytes) == wanted, do: :ok, else: {:error, {:bad_certificate, "unsupported signature algorithm #{oid(oid_bytes)}"}}

      _ ->
        :error
    end
  end

  defp p256_key(spki) do
    with {:ok, [{0x30, alg, _}, {0x03, <<0, point::binary-size(65)>>, _}]} <- read_all(spki),
         {:ok, [{0x06, kind, _}, {0x06, curve, _}]} <- read_all(alg),
         true <- oid(kind) == @ec_public_key and oid(curve) == @prime256v1,
         <<4, _::binary>> <- point do
      {:ok, point}
    else
      _ -> {:error, {:bad_certificate, "public key is not an uncompressed P-256 point"}}
    end
  end

  defp extensions(tail) do
    case Enum.find(tail, fn {tag, _, _} -> tag == 0xA3 end) do
      nil ->
        {:ok, %{}}

      {_, wrapped, _} ->
        with {:ok, {0x30, list, _, <<>>}} <- read(wrapped),
             {:ok, items} <- read_all(list) do
          Enum.reduce_while(items, {:ok, %{}}, fn {_, ext, _}, {:ok, acc} ->
            case read_all(ext) do
              {:ok, [{0x06, id, _} | rest]} ->
                case List.last(rest) do
                  {0x04, value, _} -> {:cont, {:ok, Map.put(acc, oid(id), value)}}
                  _ -> {:halt, :error}
                end

              _ ->
                {:halt, :error}
            end
          end)
        end
    end
  end

  defp ca?(extensions) do
    with value when is_binary(value) <- extensions[@basic_constraints],
         {:ok, {0x30, body, _, <<>>}} <- read(value),
         {:ok, [{0x01, <<0xFF>>, _} | _]} <- read_all(body) do
      true
    else
      _ -> false
    end
  end

  # UTCTime and GeneralizedTime, in the "Z" forms DER requires.
  defp time(0x17, <<yy::binary-2, rest::binary-size(11)>>) do
    y = String.to_integer(yy)
    time(0x18, <<Integer.to_string(if(y >= 50, do: 1900 + y, else: 2000 + y))::binary, rest::binary>>)
  rescue
    ArgumentError -> :error
  end

  defp time(0x18, <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, "Z">>) do
    [y, mo, d, h, mi, s] = Enum.map([y, mo, d, h, mi, s], &String.to_integer/1)
    {:ok, :calendar.datetime_to_gregorian_seconds({{y, mo, d}, {h, mi, s}}) - @gregorian_epoch}
  rescue
    _ -> :error
  end

  defp time(_, _), do: :error

  @doc "True when `signature` (DER ECDSA) over `data` was made by the P-256 key `public_key`."
  @spec verify_p256(binary, binary, binary) :: boolean
  def verify_p256(data, der_signature, public_key) do
    :crypto.verify(:ecdsa, :sha256, data, der_signature, [public_key, :secp256r1])
  rescue
    _ -> false
  end

  @doc "Converts a raw 64-byte `r || s` signature into the DER form `:crypto` takes."
  @spec raw_signature_to_der(binary) :: {:ok, binary} | :error
  def raw_signature_to_der(<<r::binary-32, s::binary-32>>) do
    body = der_int(r) <> der_int(s)
    {:ok, <<0x30, byte_size(body)>> <> body}
  end

  def raw_signature_to_der(_), do: :error

  defp der_int(bytes) do
    trimmed = String.trim_leading(bytes, <<0>>)
    trimmed = if trimmed == "", do: <<0>>, else: trimmed
    trimmed = if :binary.first(trimmed) >= 0x80, do: <<0>> <> trimmed, else: trimmed
    <<0x02, byte_size(trimmed)>> <> trimmed
  end

  # ---- CRLs --------------------------------------------------------------

  @doc "Parses a DER certificate revocation list signed with ECDSA P-256 / SHA-256."
  @spec parse_crl(binary) :: {:ok, crl} | {:error, {:bad_crl, String.t()}}
  def parse_crl(der) do
    with {:ok, {0x30, body, _, <<>>}} <- read(der),
         {:ok, [{0x30, tbs_body, tbs}, {0x30, sig_alg, _}, {0x03, <<0, signature::binary>>, _}]} <-
           read_all(body),
         :ok <- expect_alg(sig_alg, @ecdsa_sha256),
         {:ok, fields} <- read_all(tbs_body),
         fields = drop_crl_version(fields),
         [{0x30, _, _}, {0x30, _, issuer}, {t1, this, _} | tail] <- fields,
         {:ok, this_update} <- time(t1, this),
         {:ok, next_update, tail} <- crl_next_update(tail),
         {:ok, revoked} <- crl_revoked(tail) do
      {:ok, %{tbs: tbs, signature: signature, issuer: issuer, this_update: this_update, next_update: next_update, revoked: revoked}}
    else
      _ -> {:error, {:bad_crl, "not a well-formed ECDSA P-256 revocation list"}}
    end
  end

  defp drop_crl_version([{0x02, _, _} | rest]), do: rest
  defp drop_crl_version(rest), do: rest

  defp crl_next_update([{tag, value, _} | rest]) when tag in [0x17, 0x18] do
    with {:ok, t} <- time(tag, value), do: {:ok, t, rest}
  end

  defp crl_next_update(rest), do: {:ok, nil, rest}

  defp crl_revoked([{0x30, list, _} | _]) do
    with {:ok, entries} <- read_all(list) do
      Enum.reduce_while(entries, {:ok, MapSet.new()}, fn {_, entry, _}, {:ok, acc} ->
        case read(entry) do
          {:ok, {0x02, serial, _, _}} -> {:cont, {:ok, MapSet.put(acc, :binary.decode_unsigned(serial))}}
          _ -> {:halt, :error}
        end
      end)
    end
  end

  defp crl_revoked(_), do: {:ok, MapSet.new()}
end
