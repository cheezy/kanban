defmodule Kanban.Encryption do
  @moduledoc """
  Authenticated encryption for values stored at rest, such as TOTP secrets.

  Uses AES-256-GCM with a random 96-bit IV per call, so encrypting the same
  plaintext twice gives different ciphertexts. The stored form is

      <<version::8, iv::binary-12, tag::binary-16, ciphertext::binary>>

  The leading version byte names the key that encrypted the value, so a later
  key rotation can decrypt old rows while writing new ones.

  The key is read from application config **at call time**, never at compile
  time, so a release reads the key its environment provides:

      config :kanban, Kanban.Encryption, key: <<32 raw bytes>>

  Production sets it from the `ENCRYPTION_KEY` environment variable in
  `config/runtime.exs`; dev and test use fixed keys in `config/dev.exs` and
  `config/test.exs`.
  """

  @version 1
  @aad "Kanban.Encryption.v1"
  @hmac_label "Kanban.Encryption.hmac.v1"
  @iv_size 12
  @tag_size 16
  @key_size 32

  @doc """
  Encrypts `plaintext` and returns the versioned ciphertext.

  ## Examples

      iex> ciphertext = Kanban.Encryption.encrypt("hello")
      iex> Kanban.Encryption.decrypt(ciphertext)
      {:ok, "hello"}

  """
  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_size)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, @tag_size, true)

    <<@version, iv::binary, tag::binary, ciphertext::binary>>
  end

  @doc """
  Decrypts a value produced by `encrypt/1`.

  Returns `{:error, :invalid}` for a value that was tampered with, encrypted
  under another key, or is not in the versioned format, rather than raising or
  returning garbage.

  ## Examples

      iex> Kanban.Encryption.decrypt("not ciphertext")
      {:error, :invalid}

  """
  @spec decrypt(binary()) :: {:ok, binary()} | {:error, :invalid}
  def decrypt(
        <<@version, iv::binary-size(@iv_size), tag::binary-size(@tag_size), ciphertext::binary>>
      ) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :invalid}
    end
  end

  def decrypt(_value), do: {:error, :invalid}

  @doc """
  Returns a keyed HMAC-SHA256 of `data`, for values that are stored only as a
  digest (such as recovery codes) and must not be guessable offline from a
  database dump alone.

  The HMAC key is derived from the encryption key with a fixed label, so the
  encryption key itself is never used for two purposes.

  ## Examples

      iex> Kanban.Encryption.hmac("code") == Kanban.Encryption.hmac("code")
      true

      iex> byte_size(Kanban.Encryption.hmac("code"))
      32

  """
  @spec hmac(binary()) :: binary()
  def hmac(data) when is_binary(data) do
    :crypto.mac(:hmac, :sha256, :crypto.mac(:hmac, :sha256, key(), @hmac_label), data)
  end

  defp key do
    case Application.fetch_env!(:kanban, __MODULE__)[:key] do
      <<_::binary-size(@key_size)>> = key ->
        key

      _other ->
        raise ArgumentError,
              "config :kanban, Kanban.Encryption, key: must be #{@key_size} raw bytes"
    end
  end
end
