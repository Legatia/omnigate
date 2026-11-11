defmodule OmnigateControl.Attestation.EthSignature do
  @moduledoc """
  Recovery of the signer of an Ethereum "personal message" signature
  (EIP-191), which is how NEAR AI Cloud signs with `signing_algo=ecdsa`.

  An ECDSA identity there is an Ethereum address: the last 20 bytes of the
  Keccak-256 hash of a secp256k1 public key. A signature does not carry the
  key, so it cannot be checked against the address directly; instead the
  public key is recovered from the signature and the message, and its address
  compared. OTP's `:crypto` offers neither Keccak-256 (which differs from
  SHA3-256 in its padding) nor key recovery, so both are implemented here in
  plain integer arithmetic. Nothing secret passes through this code — it only
  verifies — so its not being constant-time does not matter.
  """

  import Bitwise

  # secp256k1 domain parameters (SEC 2, section 2.4.1).
  @p 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
  @n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @g {0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798, 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8}

  @mask64 0xFFFFFFFFFFFFFFFF

  @round_constants [
    0x0000000000000001,
    0x0000000000008082,
    0x800000000000808A,
    0x8000000080008000,
    0x000000000000808B,
    0x0000000080000001,
    0x8000000080008081,
    0x8000000000008009,
    0x000000000000008A,
    0x0000000000000088,
    0x0000000080008009,
    0x000000008000000A,
    0x000000008000808B,
    0x800000000000008B,
    0x8000000000008089,
    0x8000000000008003,
    0x8000000000008002,
    0x8000000000000080,
    0x000000000000800A,
    0x800000008000000A,
    0x8000000080008081,
    0x8000000000008080,
    0x0000000080000001,
    0x8000000080008008
  ]

  # Rotation offsets, indexed by {x, y}.
  @rotations %{
    {0, 0} => 0,
    {0, 1} => 36,
    {0, 2} => 3,
    {0, 3} => 41,
    {0, 4} => 18,
    {1, 0} => 1,
    {1, 1} => 44,
    {1, 2} => 10,
    {1, 3} => 45,
    {1, 4} => 2,
    {2, 0} => 62,
    {2, 1} => 6,
    {2, 2} => 43,
    {2, 3} => 15,
    {2, 4} => 61,
    {3, 0} => 28,
    {3, 1} => 55,
    {3, 2} => 25,
    {3, 3} => 21,
    {3, 4} => 56,
    {4, 0} => 27,
    {4, 1} => 20,
    {4, 2} => 39,
    {4, 3} => 8,
    {4, 4} => 14
  }

  @doc """
  The 20-byte address that signed `message` as an EIP-191 personal message.
  `signature` is the 65 bytes `r || s || v`, with `v` 27 or 28 (0 or 1 is
  also accepted).
  """
  @spec recover_personal(binary, binary) :: {:ok, <<_::160>>} | :error
  def recover_personal(message, signature) when is_binary(message) do
    digest = keccak256(<<0x19, "Ethereum Signed Message:\n", Integer.to_string(byte_size(message))::binary, message::binary>>)
    recover(digest, signature)
  end

  @doc "The address whose key produced `signature` over the 32-byte `digest`."
  @spec recover(<<_::256>>, binary) :: {:ok, <<_::160>>} | :error
  def recover(<<e::256>>, <<r::256, s::256, v>>) when r > 0 and r < @n and s > 0 and s < @n and v in [0, 1, 27, 28] do
    odd = rem(v, 27) &&& 1

    # The curve point R has x = r; of its two possible y, v says which.
    with true <- r < @p,
         y2 = mod(r * r * r + 7, @p),
         y = pow(y2, div(@p + 1, 4), @p),
         true <- mod(y * y, @p) == y2 do
      y = if (y &&& 1) == odd, do: y, else: @p - y
      r_inv = pow(r, @n - 2, @n)
      # Q = r^-1 (s R - e G)
      q = add(mul({r, y}, mod(s * r_inv, @n)), mul(@g, mod(-e * r_inv, @n)))

      case q do
        {x, y} -> {:ok, address(<<x::256, y::256>>)}
        :infinity -> :error
      end
    else
      _ -> :error
    end
  end

  def recover(_, _), do: :error

  @doc "The Ethereum address of an uncompressed public key given as `x || y` (64 bytes)."
  @spec address(<<_::512>>) :: <<_::160>>
  def address(<<_::binary-64>> = public_key) do
    <<_::binary-12, address::binary-20>> = keccak256(public_key)
    address
  end

  # ---- secp256k1 in affine coordinates -----------------------------------

  defp add(:infinity, q), do: q
  defp add(p, :infinity), do: p
  defp add({x, y1}, {x, y2}) when y1 != y2, do: :infinity
  defp add({x, 0}, {x, 0}), do: :infinity

  defp add({x1, y1}, {x2, y2}) do
    slope =
      if x1 == x2,
        do: mod(3 * x1 * x1 * pow(2 * y1, @p - 2, @p), @p),
        else: mod((y2 - y1) * pow(mod(x2 - x1, @p), @p - 2, @p), @p)

    x3 = mod(slope * slope - x1 - x2, @p)
    {x3, mod(slope * (x1 - x3) - y1, @p)}
  end

  defp mul(point, k), do: mul(point, k, :infinity)
  defp mul(_point, 0, acc), do: acc
  defp mul(point, k, acc), do: mul(add(point, point), k >>> 1, if((k &&& 1) == 1, do: add(acc, point), else: acc))

  defp mod(a, m), do: Integer.mod(a, m)
  defp pow(base, exponent, modulus), do: :binary.decode_unsigned(:crypto.mod_pow(base, exponent, modulus))

  # ---- Keccak-256 --------------------------------------------------------

  @doc "Keccak-256, the hash Ethereum uses (the original Keccak padding, not SHA3-256)."
  @spec keccak256(binary) :: <<_::256>>
  def keccak256(data) when is_binary(data) do
    rate = 136
    pad = rate - rem(byte_size(data), rate)
    padding = if pad == 1, do: <<0x81>>, else: <<0x01, 0::size((pad - 2) * 8), 0x80>>

    state =
      for <<block::binary-size(^rate) <- data <> padding>>, reduce: Map.new(for(x <- 0..4, y <- 0..4, do: {{x, y}, 0})) do
        state -> state |> absorb(block) |> permute()
      end

    <<hash::binary-32, _::binary>> = for i <- 0..3, into: <<>>, do: <<state[{i, 0}]::little-64>>
    hash
  end

  defp absorb(state, block) do
    lanes = for <<lane::little-64 <- block>>, do: lane

    lanes
    |> Enum.with_index()
    |> Enum.reduce(state, fn {lane, i}, st -> Map.update!(st, {rem(i, 5), div(i, 5)}, &bxor(&1, lane)) end)
  end

  defp permute(state), do: Enum.reduce(@round_constants, state, &round/2)

  defp round(rc, a) do
    c = for x <- 0..4, into: %{}, do: {x, Enum.reduce(0..4, 0, fn y, acc -> bxor(acc, a[{x, y}]) end)}
    d = for x <- 0..4, into: %{}, do: {x, bxor(c[rem(x + 4, 5)], rotl(c[rem(x + 1, 5)], 1))}
    a = for {{x, y}, v} <- a, into: %{}, do: {{x, y}, bxor(v, d[x])}
    b = for {{x, y}, v} <- a, into: %{}, do: {{y, rem(2 * x + 3 * y, 5)}, rotl(v, @rotations[{x, y}])}
    a = for {{x, y}, v} <- b, into: %{}, do: {{x, y}, bxor(v, band(bnot(b[{rem(x + 1, 5), y}]) &&& @mask64, b[{rem(x + 2, 5), y}]))}
    Map.update!(a, {0, 0}, &bxor(&1, rc))
  end

  defp rotl(v, 0), do: v
  defp rotl(v, n), do: (v <<< n ||| v >>> (64 - n)) &&& @mask64
end
