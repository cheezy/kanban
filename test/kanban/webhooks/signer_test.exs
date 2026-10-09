defmodule Kanban.Webhooks.SignerTest do
  use ExUnit.Case, async: true

  alias Kanban.Webhooks.Signer

  @secret "whsec_test"
  @body ~s({"event":"task.created"})
  @now 1_760_000_000

  test "sign/3 builds a t=<unix>,v1=<64 hex> header" do
    header = Signer.sign(@body, @secret, @now)

    assert header =~ ~r/\At=#{@now},v1=[0-9a-f]{64}\z/
  end

  test "verify/4 accepts what sign/3 produced" do
    header = Signer.sign(@body, @secret, @now)
    assert Signer.verify(header, @body, @secret, now: @now) == :ok
  end

  test "a tampered body or a wrong secret is :invalid_signature" do
    header = Signer.sign(@body, @secret, @now)

    assert Signer.verify(header, @body <> " ", @secret, now: @now) == {:error, :invalid_signature}
    assert Signer.verify(header, @body, "whsec_other", now: @now) == {:error, :invalid_signature}
  end

  test "a timestamp more than five minutes away is :stale_timestamp; exactly five is fine" do
    header = Signer.sign(@body, @secret, @now)

    assert Signer.verify(header, @body, @secret, now: @now + 300) == :ok
    assert Signer.verify(header, @body, @secret, now: @now - 300) == :ok
    assert Signer.verify(header, @body, @secret, now: @now + 301) == {:error, :stale_timestamp}
    assert Signer.verify(header, @body, @secret, now: @now - 301) == {:error, :stale_timestamp}
  end

  test "the tolerance can be changed" do
    header = Signer.sign(@body, @secret, @now)

    assert Signer.verify(header, @body, @secret, now: @now + 10, tolerance: 5) ==
             {:error, :stale_timestamp}
  end

  test "a malformed header is :malformed_header" do
    "t=" <> rest = Signer.sign(@body, @secret, @now)
    [_t, v1] = String.split(rest, ",")

    for header <- ["", "t=abc,#{v1}", "t=#{@now}", "t=#{@now}x,#{v1}", v1, "t=1,t=2,#{v1}", nil] do
      assert Signer.verify(header, @body, @secret, now: @now) == {:error, :malformed_header},
             inspect(header)
    end
  end

  test "any matching v1 value is enough, so a rotation can carry two" do
    good = signature(Signer.sign(@body, @secret, @now))
    bad = String.duplicate("0", 64)

    assert Signer.verify("t=#{@now},v1=#{bad},v1=#{good}", @body, @secret, now: @now) == :ok
  end

  test "the signature covers the timestamp" do
    moved = "t=#{@now + 1},v1=#{signature(Signer.sign(@body, @secret, @now))}"

    assert Signer.verify(moved, @body, @secret, now: @now) == {:error, :invalid_signature}
  end

  defp signature(header), do: header |> String.split("v1=") |> List.last()
end
