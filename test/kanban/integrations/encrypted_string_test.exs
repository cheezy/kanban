defmodule Kanban.Integrations.EncryptedStringTest do
  use ExUnit.Case, async: true

  alias Kanban.Integrations.EncryptedString
  alias Kanban.Integrations.SecretBox

  @url "https://hooks.slack.com/services/T000/B000/XXXX"

  test "is stored as a binary column" do
    assert EncryptedString.type() == :binary
  end

  test "casts strings only" do
    assert EncryptedString.cast(@url) == {:ok, @url}
    assert EncryptedString.cast(42) == :error
    assert Ecto.Type.cast(EncryptedString, nil) == {:ok, nil}
  end

  test "dumps to SecretBox ciphertext that does not contain the plaintext" do
    assert {:ok, ciphertext} = EncryptedString.dump(@url)
    refute ciphertext =~ "hooks.slack.com"
    assert SecretBox.decrypt(ciphertext) == {:ok, @url}
    assert EncryptedString.dump(42) == :error
    assert Ecto.Type.dump(EncryptedString, nil) == {:ok, nil}
  end

  test "loads what it dumped" do
    {:ok, ciphertext} = EncryptedString.dump(@url)
    assert EncryptedString.load(ciphertext) == {:ok, @url}
  end

  test "a value it cannot decrypt loads as nil; a non-binary is an error" do
    other = SecretBox.encrypt(@url, secret_key_base: String.duplicate("z", 64))

    assert EncryptedString.load(other) == {:ok, nil}
    assert EncryptedString.load("not a ciphertext") == {:ok, nil}
    assert EncryptedString.load(42) == :error
  end
end
