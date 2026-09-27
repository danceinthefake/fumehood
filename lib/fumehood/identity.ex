defmodule Fumehood.Identity do
  @moduledoc """
  Who is making a request (DESIGN.md §6). fumehood has no accounts: the
  identity comes from how the person reached it, and is only used to stamp
  the audit log and backups.

    * `iap/3` — Google Cloud IAP: the signed `x-goog-iap-jwt-assertion` JWT,
      verified against Google's public keys → email
    * `ssh_tunnel/2` — `gcloud compute ssh … -L`: the Linux user owning the
      client end of the forwarded TCP connection → OS Login username

  Both refuse rather than guess.
  """

  import Bitwise

  @iap_issuer "https://cloud.google.com/iap"
  @iap_keys_url ~c"https://www.gstatic.com/iap/verify/public_key-jwk"

  # -- Google Cloud IAP ------------------------------------------------------

  @doc """
  Verifies an IAP JWT and returns the user's email. `keys` maps key id
  (`kid`) to `JOSE.JWK`; defaults to Google's published keys (cached).
  """
  @spec iap(String.t() | nil, String.t(), %{String.t() => JOSE.JWK.t()} | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def iap(token, audience, keys \\ nil)
  def iap(nil, _audience, _keys), do: {:error, "missing IAP assertion header"}

  def iap(token, audience, keys) do
    with {:ok, kid} <- key_id(token),
         {:ok, jwk} <- find_key(kid, keys),
         {true, %JOSE.JWT{fields: claims}, _jws} <- verify(jwk, token),
         :ok <- check_claims(claims, audience) do
      {:ok, claims["email"]}
    else
      {false, _jwt, _jws} -> {:error, "IAP assertion signature is invalid"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp key_id(token) do
    case JOSE.JWS.peek_protected(token) |> JSON.decode() do
      {:ok, %{"alg" => "ES256", "kid" => kid}} -> {:ok, kid}
      {:ok, _} -> {:error, "IAP assertion must be ES256 with a key id"}
      _ -> {:error, "IAP assertion is malformed"}
    end
  rescue
    _ -> {:error, "IAP assertion is malformed"}
  end

  defp verify(jwk, token), do: JOSE.JWT.verify_strict(jwk, ["ES256"], token)

  defp check_claims(claims, audience) do
    now = System.os_time(:second)

    cond do
      claims["iss"] != @iap_issuer ->
        {:error, "IAP assertion has the wrong issuer"}

      claims["aud"] != audience ->
        {:error, "IAP assertion is for another audience"}

      not is_integer(claims["exp"]) or claims["exp"] < now ->
        {:error, "IAP assertion expired"}

      not is_integer(claims["iat"]) or claims["iat"] > now + 60 ->
        {:error, "IAP assertion issued in the future"}

      not is_binary(claims["email"]) ->
        {:error, "IAP assertion has no email"}

      true ->
        :ok
    end
  end

  defp find_key(kid, nil), do: find_key(kid, google_keys(kid))

  defp find_key(kid, keys) do
    case Map.fetch(keys, kid) do
      {:ok, jwk} -> {:ok, jwk}
      :error -> {:error, "IAP assertion signed with an unknown key"}
    end
  end

  # Google's keys, cached for an hour; an unknown kid triggers a refresh at
  # most once a minute (keys rotate).
  defp google_keys(kid) do
    now = System.monotonic_time(:second)
    {keys, fetched_at} = :persistent_term.get({__MODULE__, :iap_keys}, {%{}, nil})
    stale? = fetched_at == nil or now - fetched_at > 3600
    unknown? = not Map.has_key?(keys, kid) and (fetched_at == nil or now - fetched_at > 60)

    if stale? or unknown? do
      case fetch_google_keys() do
        {:ok, fresh} ->
          :persistent_term.put({__MODULE__, :iap_keys}, {fresh, now})
          fresh

        {:error, _} ->
          keys
      end
    else
      keys
    end
  end

  defp fetch_google_keys do
    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    with {:ok, {{_, 200, _}, _headers, body}} <-
           :httpc.request(:get, {@iap_keys_url, []}, [ssl: ssl, timeout: 5_000],
             body_format: :binary
           ),
         {:ok, %{"keys" => keys}} <- JSON.decode(body) do
      {:ok, Map.new(keys, fn key -> {key["kid"], JOSE.JWK.from_map(key)} end)}
    else
      _ -> {:error, :unavailable}
    end
  end

  # -- gcloud SSH tunnel -----------------------------------------------------

  @doc """
  The username owning the client end of a local TCP connection: `peer` is
  the connection's remote `{ip, port}` as seen by fumehood, `local` its own
  `{ip, port}`. Looks the socket up in `/proc/net/tcp{,6}`, then the uid with
  `getent passwd` (which also resolves OS Login users).
  """
  @spec ssh_tunnel(
          {:inet.ip_address(), :inet.port_number()},
          {:inet.ip_address(), :inet.port_number()}
        ) ::
          {:ok, String.t()} | {:error, String.t()}
  def ssh_tunnel(peer, local) do
    tables =
      for file <- ["/proc/net/tcp", "/proc/net/tcp6"], {:ok, text} <- [File.read(file)], do: text

    with {:ok, uid} <- socket_owner(tables, peer, local) do
      username(uid)
    end
  end

  @doc false
  # The uid of the socket whose local end is `peer` and remote end `local`
  # — the client side of the connection, owned by the person's sshd.
  def socket_owner(tables, peer, local) do
    tables
    |> Enum.flat_map(&String.split(&1, "\n", trim: true))
    |> Enum.find_value(fn line ->
      case String.split(line) do
        [_sl, from, to, _st, _q, _t, _r, uid | _] ->
          if parse_address(from) == normalize(peer) and parse_address(to) == normalize(local),
            do: String.to_integer(uid)

        _ ->
          nil
      end
    end)
    |> case do
      nil -> {:error, "no local socket found for this connection"}
      uid -> {:ok, uid}
    end
  end

  # /proc/net/tcp addresses: hex IP in host (little-endian) byte order per
  # 32-bit word, then ":" and the port in hex.
  defp parse_address(text) do
    with [ip, port] <- String.split(text, ":"),
         {port, ""} <- Integer.parse(port, 16),
         {:ok, bytes} <- Base.decode16(ip, case: :mixed) do
      words = for <<word::little-32 <- bytes>>, do: word

      address =
        case words do
          [v4] -> {v4 >>> 24, v4 >>> 16 &&& 255, v4 >>> 8 &&& 255, v4 &&& 255}
          v6 -> v6 |> Enum.flat_map(&[&1 >>> 16, &1 &&& 0xFFFF]) |> List.to_tuple()
        end

      normalize({address, port})
    else
      _ -> :invalid
    end
  end

  # An IPv4 client may show up as IPv4-mapped IPv6 (::ffff:a.b.c.d).
  defp normalize({{0, 0, 0, 0, 0, 0xFFFF, ab, cd}, port}),
    do: {{ab >>> 8, ab &&& 255, cd >>> 8, cd &&& 255}, port}

  defp normalize(address), do: address

  defp username(uid) do
    case System.cmd("getent", ["passwd", Integer.to_string(uid)], stderr_to_stdout: true) do
      {line, 0} -> {:ok, line |> String.split(":") |> hd()}
      _ -> {:error, "uid #{uid} has no user"}
    end
  end
end
