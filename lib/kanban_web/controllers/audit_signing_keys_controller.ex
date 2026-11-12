defmodule KanbanWeb.AuditSigningKeysController do
  @moduledoc """
  Publishes the instance's audit signing public keys at
  `/.well-known/stride-audit-signing-keys` (W2697).

  An auditor checking a signed export, and a receiver checking a streamed
  batch's `X-Stride-Audit-Signature`, fetch the key named by the signature's
  key id from here, without signing in.

    * With no `format` param the response is a JSON Web Key Set: `keys` holds
      the current key and then every previous (retired) key, and `revoked`
      holds the key id and revocation date of each revoked key.
    * With `format=pem` and a `kid` param it is that one key as a
      SubjectPublicKeyInfo PEM, which `openssl pkey -pubin` reads.

  A revoked key is never in `keys` and is never served as PEM. An unknown,
  revoked, malformed or missing `kid`, and any `format` other than `pem`, is
  a 404 whose body never repeats the request.

  One kind of request never reaches this controller: a query string that
  cannot be decoded (a value that is not valid UTF-8, or one nested too
  deep) is refused by the endpoint with a 400. `KanbanWeb.Plugs.Parsers`
  renders that error as JSON for this address, and its body does not repeat
  the request either. A malformed percent escape such as `%ZZ` is not such a
  query: it is decoded as the literal text `%ZZ`, so `?kid=%ZZ` gets the key
  set and `?format=pem&kid=%ZZ` gets the 404.

  All key data comes from `Kanban.AuditLog.Signing.published_keys/0` and
  `Kanban.AuditLog.Signing.find_published/1`, which return public material
  only; the private seed never leaves that module, and nothing here reads the
  database or the signing config.
  """
  use KanbanWeb, :controller

  alias Kanban.AuditLog.Signing

  # An hour: long enough for a verifier checking many signatures, short enough
  # that a rotated or revoked key is seen the same day.
  @cache_control "public, max-age=3600"

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"format" => "pem"} = params), do: pem(conn, params["kid"])
  def show(conn, %{"format" => _other}), do: not_found(conn)
  def show(conn, _params), do: jwks(conn)

  defp jwks(conn) do
    %{current: current, previous: previous, revoked: revoked} = Signing.published_keys()

    conn
    |> put_resp_header("cache-control", @cache_control)
    |> json(%{
      keys: for(key <- [current | previous], key != nil, do: jwk(key)),
      revoked: Enum.map(revoked, &revoked_entry/1)
    })
  end

  # RFC 8037: an Ed25519 public key is an OKP key whose x is the 32 raw bytes
  # in unpadded base64url.
  defp jwk(%{key_id: key_id, public_key: public_key}) do
    %{
      kty: "OKP",
      crv: "Ed25519",
      x: Base.url_encode64(public_key, padding: false),
      kid: key_id,
      use: "sig",
      alg: "EdDSA"
    }
  end

  defp revoked_entry(%{key_id: key_id, revoked_on: revoked_on}) do
    %{kid: key_id, revoked_at: revoked_on && Date.to_iso8601(revoked_on)}
  end

  # The kid is checked against the key id shape before any lookup, and is
  # never written to the response. A kid given twice arrives as a list or as
  # its last value; a list is refused here.
  defp pem(conn, kid) when is_binary(kid) do
    with true <- key_id_shape?(kid),
         {:ok, %{public_key: public_key}} <- Signing.find_published(kid) do
      send_pem(conn, Signing.public_key_pem(public_key))
    else
      _refused -> not_found(conn)
    end
  end

  defp pem(conn, _kid), do: not_found(conn)

  defp key_id_shape?(kid), do: Regex.match?(~r/\Ak1-[0-9a-f]{16}\z/, kid)

  # A literal content type, fixed in code rather than looked up from a param
  # (Sobelow XSS.ContentType). The body is the PEM of a key found by
  # Signing.find_published/1, so no request value reaches it.
  defp send_pem(conn, pem) do
    conn
    |> put_resp_content_type("application/x-pem-file")
    |> put_resp_header("cache-control", @cache_control)
    |> send_resp(:ok, pem)
  end

  # A fixed body, so nothing from the query string comes back. Never cached:
  # a key deployed in the next hour must not look missing.
  defp not_found(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:not_found)
    |> put_view(json: KanbanWeb.ErrorJSON)
    |> put_format(:json)
    |> render(:"404")
  end
end
