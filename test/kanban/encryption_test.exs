defmodule Kanban.EncryptionTest do
  # async: false — one test swaps the application-wide encryption key.
  use ExUnit.Case, async: false

  alias Kanban.Encryption
  alias Kanban.Encryption.EncryptedBinary

  doctest Kanban.Encryption

  defp with_key(key, fun) do
    original = Application.fetch_env!(:kanban, Encryption)
    Application.put_env(:kanban, Encryption, key: key)

    try do
      fun.()
    after
      Application.put_env(:kanban, Encryption, original)
    end
  end

  describe "encrypt/1 and decrypt/1" do
    test "round-trips the plaintext" do
      secret = :crypto.strong_rand_bytes(20)

      assert {:ok, ^secret} = secret |> Encryption.encrypt() |> Encryption.decrypt()
    end

    test "gives different ciphertext for the same plaintext (random IV)" do
      a = Encryption.encrypt("same plaintext")
      b = Encryption.encrypt("same plaintext")

      refute a == b
      assert {:ok, "same plaintext"} = Encryption.decrypt(a)
      assert {:ok, "same plaintext"} = Encryption.decrypt(b)
    end

    test "never contains the plaintext" do
      plaintext = "a recognisable plaintext value"

      assert plaintext |> Encryption.encrypt() |> :binary.match(plaintext) == :nomatch
    end

    test "starts with the key version byte" do
      assert <<1, _rest::binary>> = Encryption.encrypt("x")
    end

    test "rejects tampered ciphertext instead of returning garbage" do
      <<version, iv::binary-12, tag::binary-16, ciphertext::binary>> =
        Encryption.encrypt("do not change me")

      <<first, rest::binary>> = ciphertext
      flipped = <<version, iv::binary, tag::binary, Bitwise.bxor(first, 1), rest::binary>>

      assert Encryption.decrypt(flipped) == {:error, :invalid}
    end

    test "rejects a value with a forged tag or another version" do
      <<_version, iv::binary-12, _tag::binary-16, ciphertext::binary>> = Encryption.encrypt("x")

      assert Encryption.decrypt(<<1, iv::binary, 0::128, ciphertext::binary>>) ==
               {:error, :invalid}

      assert Encryption.decrypt(<<2, iv::binary, 0::128, ciphertext::binary>>) ==
               {:error, :invalid}
    end

    test "rejects values too short to be ciphertext" do
      assert Encryption.decrypt(<<>>) == {:error, :invalid}
      assert Encryption.decrypt(<<1, 2, 3>>) == {:error, :invalid}
    end

    test "cannot decrypt a value encrypted under another key" do
      ciphertext = with_key(:binary.copy(<<7>>, 32), fn -> Encryption.encrypt("secret") end)

      assert Encryption.decrypt(ciphertext) == {:error, :invalid}
    end

    test "raises a clear error when the configured key is not 32 bytes" do
      with_key("too short", fn ->
        assert_raise ArgumentError, ~r/must be 32 raw bytes/, fn -> Encryption.encrypt("x") end
      end)
    end
  end

  describe "hmac/1" do
    test "is deterministic for the same key and input" do
      assert Encryption.hmac("abc") == Encryption.hmac("abc")
      refute Encryption.hmac("abc") == Encryption.hmac("abd")
    end

    test "is keyed: another key gives another digest, and it is not a plain hash" do
      digest = Encryption.hmac("abc")

      refute with_key(:binary.copy(<<7>>, 32), fn -> Encryption.hmac("abc") end) == digest
      refute digest == :crypto.hash(:sha256, "abc")
    end
  end

  describe "EncryptedBinary" do
    test "is stored as a binary column" do
      assert EncryptedBinary.type() == :binary
    end

    test "casts binaries and rejects anything else" do
      assert EncryptedBinary.cast("abc") == {:ok, "abc"}
      assert EncryptedBinary.cast(123) == :error
      assert EncryptedBinary.cast(nil) == :error
    end

    test "dumps to ciphertext and loads back to plaintext" do
      assert {:ok, dumped} = EncryptedBinary.dump("plain secret")
      refute dumped == "plain secret"
      assert EncryptedBinary.load(dumped) == {:ok, "plain secret"}
    end

    test "refuses to dump or load non-binaries" do
      assert EncryptedBinary.dump(123) == :error
      assert EncryptedBinary.load(123) == :error
    end

    test "fails to load ciphertext it cannot decrypt" do
      assert EncryptedBinary.load("not ciphertext") == :error
    end

    test "compares plaintext values" do
      assert EncryptedBinary.equal?("a", "a")
      refute EncryptedBinary.equal?("a", "b")
    end
  end
end
