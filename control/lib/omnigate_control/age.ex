defmodule OmnigateControl.Age do
  @moduledoc """
  Encryption to an age recipient (https://age-encryption.org/v1), so that a
  job's outputs can be stored in a form only the key's owner can read, and
  read with standard tools (`age -d -i key.txt out-0.png.age`).

  Only what is needed for that: one X25519 recipient (`age1...`), binary
  output (no armor), encryption only. The format, as the specification
  gives it:

      age-encryption.org/v1
      -> X25519 <ephemeral share>
      <file key, wrapped>
      --- <header MAC>
      <16-byte nonce><STREAM of 64 KiB chunks, ChaCha20-Poly1305>

    * the file key is 16 random bytes;
    * it is wrapped with ChaCha20-Poly1305 under
      `HKDF-SHA256(ikm: X25519(ephemeral, recipient), salt: share || recipient, info: "age-encryption.org/v1/X25519")`
      and a zero nonce;
    * the header MAC is HMAC-SHA256 under `HKDF-SHA256(ikm: file key, salt: "", info: "header")`
      over the header up to and including `---`;
    * the payload key is `HKDF-SHA256(ikm: file key, salt: nonce, info: "payload")`;
      each chunk's nonce is an 11-byte big-endian counter and a last byte
      that is 1 on the final chunk. The final chunk may be short; it is
      empty only when the whole payload is.

  There is no decryption here: the gateway never holds a private key.

  Encryption is a stream (`start/1`, `update/2`, `finish/1`), so a download
  is encrypted as it arrives and its plaintext never reaches a disk.
  """
  import Bitwise

  @chunk 65_536
  @hrp "age"

  @doc "The 32-byte public key of an `age1...` recipient, or `{:error, why}`."
  def recipient(text) when is_binary(text) do
    with true <- byte_size(text) <= 90 or {:error, "an age recipient is 62 characters"},
         {:ok, @hrp, key} <- bech32_decode(text),
         true <- byte_size(key) == 32 or {:error, "an age recipient holds a 32-byte key"} do
      {:ok, key}
    else
      {:ok, _hrp, _data} -> {:error, "not an age recipient (it must start with age1)"}
      {:error, why} -> {:error, why}
    end
  end

  def recipient(_), do: {:error, "an age recipient is text that starts with age1"}

  @doc "Is this a recipient this module can encrypt to?"
  def valid_recipient?(text), do: match?({:ok, _}, recipient(text))

  @doc """
  Begin a file for `recipient` (the text form). Returns `{header, state}`:
  `header` is the first bytes of the file.
  """
  def start(recipient) when is_binary(recipient) do
    {:ok, their_public} = recipient(recipient)
    file_key = :crypto.strong_rand_bytes(16)
    {share, secret} = :crypto.generate_key(:ecdh, :x25519)
    shared = :crypto.compute_key(:ecdh, their_public, secret, :x25519)
    # An all-zero result means the recipient is a low-order point.
    if shared == <<0::256>>, do: raise(ArgumentError, "the recipient is not a usable X25519 key")

    wrap_key = hkdf(shared, share <> their_public, "age-encryption.org/v1/X25519")
    {wrapped, tag} = :crypto.crypto_one_time_aead(:chacha20_poly1305, wrap_key, <<0::96>>, file_key, "", true)

    head = "age-encryption.org/v1\n-> X25519 #{b64(share)}\n#{b64(wrapped <> tag)}\n---"
    mac = :crypto.mac(:hmac, :sha256, hkdf(file_key, "", "header"), head)
    nonce = :crypto.strong_rand_bytes(16)

    {[head, " ", b64(mac), "\n", nonce], %{key: hkdf(file_key, nonce, "payload"), counter: 0, buffer: <<>>}}
  end

  @doc """
  Encrypt more plaintext. Returns `{ciphertext, state}`; `ciphertext` may be
  empty (the last 64 KiB are kept back until `finish/1`, which is the only
  one who knows that they are the last).
  """
  def update(state, data) when is_binary(data) do
    take(%{state | buffer: state.buffer <> data}, [])
  end

  # Strictly more than a chunk in hand: the first chunk is not the last one.
  defp take(%{buffer: buffer} = state, out) when byte_size(buffer) > @chunk do
    <<chunk::binary-size(@chunk), rest::binary>> = buffer
    take(%{state | buffer: rest, counter: state.counter + 1}, [out, seal(state, chunk, 0)])
  end

  defp take(state, out), do: {out, state}

  @doc "The final chunk of the file."
  def finish(state), do: seal(state, state.buffer, 1)

  @doc "A whole binary, encrypted for `recipient`."
  def encrypt(recipient, plaintext) when is_binary(plaintext) do
    {header, state} = start(recipient)
    {body, state} = update(state, plaintext)
    IO.iodata_to_binary([header, body, finish(state)])
  end

  defp seal(state, chunk, last) do
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:chacha20_poly1305, state.key, <<state.counter::88, last::8>>, chunk, "", true)
    [ciphertext, tag]
  end

  # HKDF-SHA256 with one block of output (32 bytes), which is all age needs.
  defp hkdf(ikm, salt, info) do
    salt = if salt == "", do: <<0::256>>, else: salt
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
  end

  defp b64(bytes), do: Base.encode64(bytes, padding: false)

  # -- bech32 (BIP 173), decoding only --------------------------------------

  @charset ~c"qpzry9x8gf2tvdw0s3jn54khce6mua7l"
  @values @charset |> Enum.with_index() |> Map.new()

  @doc false
  def bech32_decode(text) do
    lower = String.downcase(text, :ascii)

    with true <- text == lower or text == String.upcase(text, :ascii) or {:error, "mixed upper and lower case"},
         true <- String.printable?(lower) or {:error, "not text"},
         [hrp, data] when hrp != "" <- split_last(lower, "1"),
         {:ok, values} <- values(data),
         true <- length(values) >= 6 or {:error, "too short"},
         true <- polymod(hrp_expand(hrp) ++ values) == 1 or {:error, "the checksum does not match (a typing error?)"},
         {:ok, bytes} <- regroup(Enum.drop(values, -6)) do
      {:ok, hrp, bytes}
    else
      {:error, why} -> {:error, why}
      _ -> {:error, "not in bech32 form"}
    end
  end

  defp split_last(text, separator) do
    case :binary.matches(text, separator) do
      [] -> :error
      matches -> with {at, 1} <- List.last(matches), do: [binary_part(text, 0, at), binary_part(text, at + 1, byte_size(text) - at - 1)]
    end
  end

  defp values(data) do
    data
    |> String.to_charlist()
    |> Enum.reduce_while({:ok, []}, fn c, {:ok, acc} ->
      case @values do
        %{^c => v} -> {:cont, {:ok, [v | acc]}}
        _ -> {:halt, {:error, "a character that bech32 does not use"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp hrp_expand(hrp) do
    chars = String.to_charlist(hrp)
    Enum.map(chars, &(&1 >>> 5)) ++ [0] ++ Enum.map(chars, &(&1 &&& 31))
  end

  @generators [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]

  defp polymod(values) do
    Enum.reduce(values, 1, fn v, chk ->
      top = chk >>> 25
      chk = bxor((chk &&& 0x1FFFFFF) <<< 5, v)

      @generators
      |> Enum.with_index()
      |> Enum.reduce(chk, fn {g, i}, chk -> if (top >>> i &&& 1) == 1, do: bxor(chk, g), else: chk end)
    end)
  end

  # Five-bit groups to bytes; what is left over must be zero padding.
  defp regroup(values) do
    bits = for v <- values, into: <<>>, do: <<v::5>>
    whole = div(bit_size(bits), 8) * 8
    <<bytes::bitstring-size(^whole), pad::bitstring>> = bits
    pad_size = bit_size(pad)

    if pad_size < 5 and pad == <<0::size(pad_size)>> do
      {:ok, bytes}
    else
      {:error, "bad padding"}
    end
  end
end
