defmodule Kanban.Integrations.SecretBoxTest do
  use ExUnit.Case, async: true

  alias Kanban.Integrations.SecretBox

  @key_base String.duplicate("k", 64)
  @other_key_base String.duplicate("z", 64)

  test "decrypt/2 returns what encrypt/2 was given" do
    ciphertext = SecretBox.encrypt("whsec_plain", secret_key_base: @key_base)
    assert SecretBox.decrypt(ciphertext, secret_key_base: @key_base) == {:ok, "whsec_plain"}
  end

  test "each call gives a different ciphertext that does not contain the plaintext" do
    first = SecretBox.encrypt("whsec_plain", secret_key_base: @key_base)
    second = SecretBox.encrypt("whsec_plain", secret_key_base: @key_base)

    refute first == second
    refute first =~ "whsec_plain"
  end

  test "a tampered ciphertext is :invalid" do
    ciphertext = SecretBox.encrypt("whsec_plain", secret_key_base: @key_base)
    <<head::binary-size(10), byte, rest::binary>> = ciphertext
    tampered = <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>

    assert SecretBox.decrypt(tampered, secret_key_base: @key_base) == {:error, :invalid}
  end

  test "a different secret_key_base cannot decrypt" do
    ciphertext = SecretBox.encrypt("whsec_plain", secret_key_base: @key_base)
    assert SecretBox.decrypt(ciphertext, secret_key_base: @other_key_base) == {:error, :invalid}
  end

  test "garbage and non-binaries are :invalid" do
    assert SecretBox.decrypt("not a ciphertext", secret_key_base: @key_base) == {:error, :invalid}
    assert SecretBox.decrypt(nil) == {:error, :invalid}
    assert SecretBox.decrypt(123) == {:error, :invalid}
  end

  test "the configured secret_key_base is used by default" do
    configured = Application.get_env(:kanban, KanbanWeb.Endpoint)[:secret_key_base]
    ciphertext = SecretBox.encrypt("configured")

    assert SecretBox.decrypt(ciphertext) == {:ok, "configured"}
    assert SecretBox.decrypt(ciphertext, secret_key_base: configured) == {:ok, "configured"}
    assert SecretBox.decrypt(ciphertext, secret_key_base: @other_key_base) == {:error, :invalid}
  end

  test "a missing or short secret_key_base raises without naming the value" do
    for key_base <- [nil, "short"] do
      error =
        assert_raise ArgumentError, fn ->
          SecretBox.encrypt("x", secret_key_base: key_base)
        end

      refute error.message =~ "short"
    end
  end
end
