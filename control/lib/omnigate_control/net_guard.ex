defmodule OmnigateControl.NetGuard do
  @moduledoc """
  Decides which addresses the control plane may call when the URL came from
  somebody else: a client's webhook URL, or a file URL in a provider's answer.

  `target/2` resolves the host once, checks every address it resolves to, and
  returns the address the caller must then connect to itself
  (`Http.request(..., connect_to: ip)`). Checking a name and then letting the
  HTTP client resolve it again would let a hostile DNS server answer "public"
  for the check and "internal" for the call.

  Unless `media.webhooks.allow_private` is set (local development, where the
  providers and webhook receivers are mocks on this machine), anything that
  is not a public unicast address is refused: loopback, private, link-local,
  carrier NAT, documentation and benchmarking ranges, multicast, and the IPv6
  forms that smuggle an IPv4 address (mapped, compatible, NAT64, 6to4,
  Teredo).
  """
  import Bitwise

  alias OmnigateControl.ConfigStore

  @doc """
  `{:ok, ip}` when `url` is an http(s) URL we are willing to call, else
  `{:error, reason}`. `label` names the thing in error messages.
  """
  def target(url, label \\ "url") when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "#{label} must be http or https"}

      uri.host in [nil, ""] ->
        {:error, "#{label} has no host"}

      uri.userinfo != nil ->
        {:error, "#{label} must not contain credentials"}

      true ->
        addresses = resolve(uri.host)

        cond do
          addresses == [] -> {:error, "#{label} host does not resolve"}
          allow_private?() -> {:ok, hd(addresses)}
          Enum.any?(addresses, &private?/1) -> {:error, "#{label} resolves to a private or loopback address"}
          true -> {:ok, hd(addresses)}
        end
    end
  end

  defp allow_private?, do: ConfigStore.get().media.webhooks.allow_private

  # IPv4 first. A literal address needs no lookup. Tests swap the resolver.
  defp resolve(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        [ip]

      {:error, _} ->
        resolver = Application.get_env(:omnigate_control, :webhook_resolver, &system_resolve/1)
        resolver.(host)
    end
  end

  defp system_resolve(host) do
    for family <- [:inet, :inet6],
        {:ok, list} <- [:inet.getaddrs(String.to_charlist(host), family)],
        addr <- list,
        do: addr
  end

  @doc """
  True for every address that is not public unicast. Follows the IANA
  special-purpose registries for IPv4 and IPv6.
  """
  def private?({a, b, c, _d}) do
    cond do
      # "this network", private, loopback
      a in [0, 10, 127] -> true
      # carrier-grade NAT 100.64.0.0/10
      a == 100 and b in 64..127 -> true
      # link-local, including cloud metadata 169.254.169.254
      a == 169 and b == 254 -> true
      a == 172 and b in 16..31 -> true
      # IETF protocol assignments 192.0.0.0/24, TEST-NET-1 192.0.2.0/24
      a == 192 and b == 0 and c in [0, 2] -> true
      # AS112 192.31.196.0/24, AMT 192.52.193.0/24, 6to4 relay 192.88.99.0/24, AS112 192.175.48.0/24
      {a, b, c} in [{192, 31, 196}, {192, 52, 193}, {192, 88, 99}, {192, 175, 48}] -> true
      a == 192 and b == 168 -> true
      # benchmarking 198.18.0.0/15
      a == 198 and b in [18, 19] -> true
      # TEST-NET-2 and TEST-NET-3
      {a, b, c} in [{198, 51, 100}, {203, 0, 113}] -> true
      # multicast, reserved, broadcast
      a >= 224 -> true
      true -> false
    end
  end

  # IPv4-mapped ::ffff:a.b.c.d and the deprecated IPv4-compatible ::a.b.c.d
  # (which also covers :: and ::1): judged by the IPv4 address inside, and the
  # compatible form is refused outright since nothing public uses it.
  def private?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: private?(v4(hi, lo))
  def private?({0, 0, 0, 0, 0, 0, _hi, _lo}), do: true
  # NAT64 64:ff9b::/96 reaches the IPv4 address in its last 32 bits.
  def private?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: private?(v4(hi, lo))
  # Local-use NAT64 64:ff9b:1::/48
  def private?({0x64, 0xFF9B, 1, _, _, _, _, _}), do: true
  # 6to4 2002:AABB:CCDD::/48 reaches the IPv4 address A.B.C.D.
  def private?({0x2002, hi, lo, _, _, _, _, _}), do: private?(v4(hi, lo))

  def private?({a, b, _, _, _, _, _, _}) do
    cond do
      # discard-only 100::/64
      a == 0x0100 and b == 0 -> true
      # IETF protocol assignments 2001::/23: Teredo, ORCHID, benchmarking, ...
      a == 0x2001 and b < 0x0200 -> true
      # documentation 2001:db8::/32 and 3fff::/20
      a == 0x2001 and b == 0x0DB8 -> true
      band(a, 0xFFF0) == 0x3FF0 -> true
      # segment routing SIDs 5f00::/16
      a == 0x5F00 -> true
      # unique local fc00::/7
      band(a, 0xFE00) == 0xFC00 -> true
      # link-local fe80::/10 and the deprecated site-local fec0::/10
      band(a, 0xFFC0) in [0xFE80, 0xFEC0] -> true
      # multicast ff00::/8
      band(a, 0xFF00) == 0xFF00 -> true
      true -> false
    end
  end

  defp v4(hi, lo), do: {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}
end
