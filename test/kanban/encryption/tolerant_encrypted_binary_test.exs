defmodule Kanban.Encryption.TolerantEncryptedBinaryTest do
  # async: false — one test swaps the application-wide encryption key.
  use ExUnit.Case, async: false

  alias Kanban.Encryption
  alias Kanban.Encryption.EncryptedBinary
  alias Kanban.Encryption.TolerantEncryptedBinary

  @other_key :binary.copy(<<7>>, 32)

  defp with_key(key, fun) do
    original = Application.fetch_env!(:kanban, Encryption)
    Application.put_env(:kanban, Encryption, key: key)

    try do
      fun.()
    after
      Application.put_env(:kanban, Encryption, original)
    end
  end

  describe "dump/1 and load/1" do
    test "round-trips a value, storing ciphertext rather than the plaintext" do
      secret = "splunk-hec-token-1234"

      assert {:ok, ciphertext} = TolerantEncryptedBinary.dump(secret)
      refute ciphertext == secret
      refute ciphertext =~ secret
      assert {:ok, ^secret} = TolerantEncryptedBinary.load(ciphertext)
    end

    test "loads a value written under another key as :unreadable instead of failing" do
      ciphertext = with_key(@other_key, fn -> Encryption.encrypt("written-elsewhere") end)

      assert {:ok, :unreadable} = TolerantEncryptedBinary.load(ciphertext)
      assert :error = EncryptedBinary.load(ciphertext)
    end

    test "loads tampered or garbage bytes as :unreadable" do
      ciphertext = Encryption.encrypt("tamper-me")
      last = :binary.last(ciphertext)

      tampered =
        binary_part(ciphertext, 0, byte_size(ciphertext) - 1) <> <<Bitwise.bxor(last, 1)>>

      assert {:ok, :unreadable} = TolerantEncryptedBinary.load(tampered)
      assert {:ok, :unreadable} = TolerantEncryptedBinary.load("not ciphertext")
      assert {:ok, :unreadable} = TolerantEncryptedBinary.load("")
    end

    test "refuses to load a value that is not a binary" do
      assert :error = TolerantEncryptedBinary.load(123)
    end

    test "refuses to dump :unreadable or a value that is not a binary" do
      assert :error = TolerantEncryptedBinary.dump(:unreadable)
      assert :error = TolerantEncryptedBinary.dump(123)
    end

    test "passes nil through without loading or dumping it" do
      assert {:ok, nil} = Ecto.Type.load(TolerantEncryptedBinary, nil)
      assert {:ok, nil} = Ecto.Type.dump(TolerantEncryptedBinary, nil)
    end
  end

  describe "cast/1" do
    test "accepts a binary" do
      assert {:ok, "value"} = TolerantEncryptedBinary.cast("value")
    end

    test "refuses :unreadable, so a form can never submit the marker" do
      assert :error = TolerantEncryptedBinary.cast(:unreadable)
      assert :error = Ecto.Type.cast(TolerantEncryptedBinary, :unreadable)
    end

    test "refuses a value that is not a binary" do
      assert :error = TolerantEncryptedBinary.cast(42)
      assert :error = TolerantEncryptedBinary.cast(%{})
    end
  end

  describe "type/0 and equal?/2" do
    test "stores as a binary column" do
      assert TolerantEncryptedBinary.type() == :binary
    end

    test "compares plaintext values" do
      assert TolerantEncryptedBinary.equal?("a", "a")
      refute TolerantEncryptedBinary.equal?("a", "b")
      refute TolerantEncryptedBinary.equal?(:unreadable, "a")
    end
  end
end
