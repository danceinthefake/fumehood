defmodule Fumehood.IdentityTest do
  use ExUnit.Case, async: true

  alias Fumehood.Identity

  @audience "/projects/123/global/backendServices/456"

  setup do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    %{jwk: jwk, keys: %{"k1" => jwk}}
  end

  defp token(jwk, claims, header \\ %{"alg" => "ES256", "kid" => "k1"}) do
    now = System.os_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => "https://cloud.google.com/iap",
          "aud" => @audience,
          "iat" => now,
          "exp" => now + 600,
          "email" => "jane@example.com"
        },
        claims
      )

    {_, token} = jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
    token
  end

  describe "iap/3" do
    test "a valid assertion gives the email", %{jwk: jwk, keys: keys} do
      assert Identity.iap(token(jwk, %{}), @audience, keys) == {:ok, "jane@example.com"}
    end

    test "every invalid assertion is refused", %{jwk: jwk, keys: keys} do
      now = System.os_time(:second)
      other = JOSE.JWK.generate_key({:ec, "P-256"})

      cases = [
        {nil, "missing"},
        {"not.a.jwt", "malformed"},
        {token(jwk, %{"aud" => "/projects/999/other"}), "another audience"},
        {token(jwk, %{"iss" => "https://evil.example"}), "wrong issuer"},
        {token(jwk, %{"exp" => now - 1}), "expired"},
        {token(jwk, %{"iat" => now + 3600}), "future"},
        {token(jwk, %{"email" => nil}), "no email"},
        {token(other, %{}), "signature is invalid"},
        {token(jwk, %{}, %{"alg" => "ES256", "kid" => "unknown"}), "unknown key"}
      ]

      for {token, reason} <- cases do
        assert {:error, message} = Identity.iap(token, @audience, keys)
        assert message =~ reason, "#{reason}: got #{message}"
      end
    end

    test "a symmetric (HS256) token is refused, even signed with the public key", %{
      jwk: jwk,
      keys: keys
    } do
      hmac = JOSE.JWK.from_oct(JOSE.JWK.to_public(jwk) |> JOSE.JWK.to_binary() |> elem(1))

      assert {:error, message} =
               Identity.iap(token(hmac, %{}, %{"alg" => "HS256", "kid" => "k1"}), @audience, keys)

      assert message =~ "ES256"
    end
  end

  describe "socket_owner/3 (parsing /proc/net/tcp)" do
    @header "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"

    test "finds the client end of an IPv4 loopback connection" do
      # server socket 127.0.0.1:4000 (uid 999) and client socket 127.0.0.1:51234 (uid 1001)
      table =
        @header <>
          "   0: 0100007F:0FA0 0100007F:C822 01 00000000:00000000 00:00000000 00000000   999        0 1 1\n" <>
          "   1: 0100007F:C822 0100007F:0FA0 01 00000000:00000000 00:00000000 00000000  1001        0 2 1\n"

      assert Identity.socket_owner([table], {{127, 0, 0, 1}, 51234}, {{127, 0, 0, 1}, 4000}) ==
               {:ok, 1001}
    end

    test "IPv6 loopback and IPv4-mapped addresses" do
      v6 =
        @header <>
          "   0: 00000000000000000000000001000000:C822 00000000000000000000000001000000:0FA0 01 00000000:00000000 00:00000000 00000000  1002 0 3 1\n" <>
          "   1: 0000000000000000FFFF00000100007F:D000 0000000000000000FFFF00000100007F:0FA0 01 00000000:00000000 00:00000000 00000000  1003 0 4 1\n"

      assert Identity.socket_owner(
               [v6],
               {{0, 0, 0, 0, 0, 0, 0, 1}, 51234},
               {{0, 0, 0, 0, 0, 0, 0, 1}, 4000}
             ) ==
               {:ok, 1002}

      assert Identity.socket_owner([v6], {{127, 0, 0, 1}, 53248}, {{127, 0, 0, 1}, 4000}) ==
               {:ok, 1003}
    end

    test "no matching socket" do
      assert {:error, _} =
               Identity.socket_owner([@header], {{127, 0, 0, 1}, 1}, {{127, 0, 0, 1}, 2})
    end
  end
end
