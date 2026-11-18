defmodule Kanban.Devices.Pkce do
  @moduledoc """
  PKCE (RFC 7636) verifier checks for the device sign-in token exchange
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1).

  Only the `S256` method exists: the authorize page refuses any other
  (`Kanban.Devices.Clients`), so every stored challenge is
  `BASE64URL-NOPAD(SHA256(verifier))`. A verifier is 43 to 128 characters
  from the RFC's unreserved set, and anything else is refused before it is
  hashed.
  """

  # RFC 7636 §4.1: code-verifier = 43*128unreserved.
  @verifier_format ~r/\A[A-Za-z0-9\-._~]{43,128}\z/

  @doc "Whether `verifier` has the shape RFC 7636 §4.1 allows."
  @spec valid_verifier?(term()) :: boolean()
  def valid_verifier?(verifier) when is_binary(verifier),
    do: Regex.match?(@verifier_format, verifier)

  def valid_verifier?(_verifier), do: false

  @doc """
  The S256 challenge for `verifier`: the unpadded base64url SHA-256 digest.
  """
  @spec challenge(String.t()) :: String.t()
  def challenge(verifier) when is_binary(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Whether `verifier` is well formed and hashes to `challenge`. The digests
  are compared in constant time.
  """
  @spec verify(term(), term()) :: boolean()
  def verify(challenge, verifier) when is_binary(challenge) and is_binary(verifier) do
    valid_verifier?(verifier) and verifier |> challenge() |> Plug.Crypto.secure_compare(challenge)
  end

  def verify(_challenge, _verifier), do: false
end
