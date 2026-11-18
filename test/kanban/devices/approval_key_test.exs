defmodule Kanban.Devices.ApprovalKeyTest do
  use ExUnit.Case, async: true

  alias Kanban.Devices.ApprovalKey

  defp generated_point do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :secp256r1)
    public_key
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)

  test "accepts a P-256 uncompressed point as unpadded base64url" do
    for _ <- 1..20 do
      key = encode(generated_point())
      assert byte_size(key) == 87
      assert ApprovalKey.canonical(key) == {:ok, key}
      assert ApprovalKey.valid?(key)
    end
  end

  test "refuses a point that is not on the curve" do
    <<4, x::binary-size(32), y::unsigned-big-256>> = generated_point()
    off_curve = <<4, x::binary, y + 1::unsigned-big-256>>

    assert off_curve |> encode() |> ApprovalKey.canonical() == :error
  end

  @p 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @b 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B

  # A point on the curve with a small x, so x + p still fits 256 bits and
  # names the same point modulo p: only the range check can refuse it.
  # p is 3 mod 4, so a square root of r is r^((p + 1) / 4) when one exists.
  defp small_x_point do
    Enum.find_value(1..1000, fn x ->
      rhs = Integer.mod(x * x * x - 3 * x + @b, @p)
      y = :crypto.mod_pow(rhs, div(@p + 1, 4), @p) |> :binary.decode_unsigned()
      if Integer.mod(y * y, @p) == rhs, do: {x, y}
    end)
  end

  test "refuses a coordinate at or above the field prime" do
    {x, y} = small_x_point()
    assert <<4, x::256, y::256>> |> encode() |> ApprovalKey.valid?()

    assert <<4, x + @p::256, y::256>> |> encode() |> ApprovalKey.canonical() == :error
  end

  test "refuses other encodings and other curves" do
    point = generated_point()
    <<4, x::binary-size(32), y::unsigned-big-256>> = point
    compressed = <<2 + rem(y, 2), x::binary>>
    {other_curve, _} = :crypto.generate_key(:ecdh, :secp384r1)

    for bad <- [
          encode(compressed),
          Base.url_encode64(point),
          Base.encode64(point),
          encode(<<3>> <> binary_part(point, 1, 64)),
          encode(other_curve),
          encode(:binary.copy(<<0>>, 65)),
          "fixture-public-key",
          "",
          nil,
          123
        ] do
      assert ApprovalKey.canonical(bad) == :error, inspect(bad)
      refute ApprovalKey.valid?(bad)
    end
  end

  @alphabet ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

  # 87 characters carry 522 bits for 520 bits of key, so the last character's
  # two low bits are unused: a canonical key has them clear.
  test "returns the canonical spelling of a key whose unused trailing bits are set" do
    key = encode(generated_point())
    {prefix, <<last>>} = String.split_at(key, 86)
    index = Enum.find_index(@alphabet, &(&1 == last))
    assert Bitwise.band(index, 3) == 0

    sloppy = prefix <> <<Enum.at(@alphabet, Bitwise.bor(index, 1))>>

    case Base.url_decode64(sloppy, padding: false) do
      {:ok, _bytes} -> assert ApprovalKey.canonical(sloppy) == {:ok, key}
      :error -> assert ApprovalKey.canonical(sloppy) == :error
    end
  end
end
