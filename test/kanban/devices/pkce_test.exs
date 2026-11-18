defmodule Kanban.Devices.PkceTest do
  use ExUnit.Case, async: true

  alias Kanban.Devices.Pkce

  # The challenge was computed outside Elixir, with Python's hashlib:
  # base64.urlsafe_b64encode(hashlib.sha256(verifier).digest()).rstrip("=").
  @verifier "dBjftJeZ4CVP-mA92Q-NtmWN3zLz1wf-kGk2XBxwMLk"
  @challenge "HUoRTFnB9N6pVJ_xr0vr25hif8B2Vm4l6NLwgAqpcgw"

  test "the challenge is the S256 transform: unpadded base64url SHA-256" do
    assert Pkce.challenge(@verifier) == @challenge
  end

  test "verifies a matching verifier and refuses a mismatch" do
    assert Pkce.verify(@challenge, @verifier)
    refute Pkce.verify(@challenge, String.replace(@verifier, "d", "e", global: false))
    refute Pkce.verify(@verifier, @verifier)
  end

  test "refuses verifiers of the wrong length or alphabet before hashing" do
    short = String.duplicate("a", 42)
    long = String.duplicate("a", 129)
    spaced = String.duplicate("a", 42) <> " "

    for bad <- [short, long, spaced, String.duplicate("a", 42) <> "+", nil, 1, ["a"]] do
      refute Pkce.valid_verifier?(bad)
      challenge = bad |> to_string_or_empty() |> Pkce.challenge()
      refute Pkce.verify(challenge, bad)
    end

    assert "a" |> String.duplicate(43) |> Pkce.valid_verifier?()
    assert "~._-" |> String.duplicate(32) |> Pkce.valid_verifier?()
  end

  test "refuses a challenge that is not a string" do
    refute Pkce.verify(nil, @verifier)
    refute Pkce.verify(%{}, @verifier)
  end

  defp to_string_or_empty(value) when is_binary(value), do: value
  defp to_string_or_empty(_value), do: ""
end
