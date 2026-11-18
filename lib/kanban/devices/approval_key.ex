defmodule Kanban.Devices.ApprovalKey do
  @moduledoc """
  The public half of the key a device signs sign-in approvals with
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §9.1).

  The app sends it at the token exchange as an uncompressed P-256 (secp256r1)
  point, `0x04 || X || Y` (65 bytes, the X9.63 form both platforms export),
  encoded as unpadded base64url: exactly 87 characters. Anything else is
  refused: another curve, a compressed point, an SPKI or PEM wrapper, padding,
  or a point that is not on the curve.

  The curve check is exact integer arithmetic on `y² = x³ - 3x + b (mod p)`.
  P-256 has cofactor 1, so every point on the curve is in the prime-order
  group, and the point at infinity has no uncompressed encoding, so a point
  that passes is a usable public key.
  """

  # NIST P-256 (FIPS 186-4 D.1.2.3): the field prime and the curve's b.
  @p 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @b 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
  @encoded_format ~r/\A[A-Za-z0-9_-]{87}\z/

  @doc """
  Returns the canonical encoding of a valid key, or `:error`.

  Unpadded base64url can spell one byte string two ways when its last
  character carries unused bits, so the key is decoded and encoded again,
  and the stored value is always the canonical spelling.
  """
  @spec canonical(term()) :: {:ok, String.t()} | :error
  def canonical(encoded) when is_binary(encoded) do
    with true <- Regex.match?(@encoded_format, encoded),
         {:ok, <<4, x::unsigned-big-256, y::unsigned-big-256>> = point} <-
           Base.url_decode64(encoded, padding: false),
         true <- on_curve?(x, y) do
      {:ok, Base.url_encode64(point, padding: false)}
    else
      _invalid -> :error
    end
  end

  def canonical(_encoded), do: :error

  @doc "Whether `encoded` is a valid P-256 public key in the wire format."
  @spec valid?(term()) :: boolean()
  def valid?(encoded), do: canonical(encoded) != :error

  defp on_curve?(x, y) when x < @p and y < @p do
    Integer.mod(y * y - (x * x * x - 3 * x + @b), @p) == 0
  end

  defp on_curve?(_x, _y), do: false
end
