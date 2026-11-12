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

  describe "sign_all/3" do
    test "list-of-secrets sign emits one v1 per secret, old first" do
      header = Signer.sign_all(@body, ["whsec_old", @secret], @now)

      assert [_, old, new] =
               Regex.run(~r/\At=#{@now},v1=([0-9a-f]{64}),v1=([0-9a-f]{64})\z/, header)

      assert old == signature(Signer.sign(@body, "whsec_old", @now))
      assert new == signature(Signer.sign(@body, @secret, @now))
    end

    test "verify/4 accepts the header with either secret" do
      header = Signer.sign_all(@body, ["whsec_old", @secret], @now)

      assert Signer.verify(header, @body, "whsec_old", now: @now) == :ok
      assert Signer.verify(header, @body, @secret, now: @now) == :ok

      assert Signer.verify(header, @body, "whsec_other", now: @now) ==
               {:error, :invalid_signature}
    end

    test "with one secret it is exactly sign/3's header" do
      assert Signer.sign_all(@body, [@secret], @now) == Signer.sign(@body, @secret, @now)
    end

    test "the timestamp defaults to now" do
      header = Signer.sign_all(@body, [@secret])

      assert Signer.verify(header, @body, @secret) == :ok
    end

    test "no secret, or one that is not a binary, is refused" do
      for secrets <- [[], [nil]] do
        assert_raise FunctionClauseError, fn -> Signer.sign_all(@body, secrets, @now) end
      end
    end
  end

  defp signature(header), do: header |> String.split("v1=") |> List.last()
end
