defmodule Kanban.Integrations.SecretBox do
  @moduledoc """
  Encrypts integration secrets (webhook signing secrets) at rest (W2226).

  A secret must be recoverable, since it is needed to sign every delivery, so
  it is encrypted rather than hashed. `Plug.Crypto.MessageEncryptor` does the
  authenticated encryption; its keys are derived from the endpoint's
  `secret_key_base` with `Plug.Crypto.KeyGenerator`, read at call time so a
  release picks up the runtime value.

  Rotating `secret_key_base` makes every stored secret unreadable:
  `decrypt/2` then returns `{:error, :invalid}` and the secret has to be
  rotated by its owner.
  """

  alias Plug.Crypto.KeyGenerator
  alias Plug.Crypto.MessageEncryptor

  @encrypt_salt "kanban.secret_box.v1.encrypt"
  @sign_salt "kanban.secret_box.v1.sign"
  @aad "kanban.integrations.secret_box.v1"
  @min_key_base_bytes 64

  @doc """
  Encrypts `plaintext`, returning the ciphertext to store. Every call gives a
  different ciphertext. `opts[:secret_key_base]` overrides the configured key
  base (tests use it).
  """
  def encrypt(plaintext, opts \\ []) when is_binary(plaintext) do
    {secret, sign_secret} = keys(opts)
    MessageEncryptor.encrypt(plaintext, @aad, secret, sign_secret)
  end

  @doc """
  Decrypts a value written by `encrypt/2`. Returns `{:error, :invalid}` for
  anything else: tampered ciphertext, a different key base, or a non-binary.
  """
  def decrypt(ciphertext, opts \\ [])

  def decrypt(ciphertext, opts) when is_binary(ciphertext) do
    {secret, sign_secret} = keys(opts)

    case MessageEncryptor.decrypt(ciphertext, @aad, secret, sign_secret) do
      {:ok, plaintext} -> {:ok, plaintext}
      :error -> {:error, :invalid}
    end
  end

  def decrypt(_ciphertext, _opts), do: {:error, :invalid}

  defp keys(opts) do
    key_base = Keyword.get_lazy(opts, :secret_key_base, &configured_key_base/0)
    validate_key_base!(key_base)

    {derive(key_base, @encrypt_salt), derive(key_base, @sign_salt)}
  end

  defp derive(key_base, salt),
    do: KeyGenerator.generate(key_base, salt, length: 32, cache: Plug.Crypto.Keys)

  defp configured_key_base do
    :kanban
    |> Application.get_env(KanbanWeb.Endpoint, [])
    |> Keyword.get(:secret_key_base)
  end

  # The message names the problem, never the value.
  defp validate_key_base!(key_base)
       when is_binary(key_base) and byte_size(key_base) >= @min_key_base_bytes,
       do: :ok

  defp validate_key_base!(_key_base),
    do: raise(ArgumentError, "SecretBox needs a secret_key_base of at least 64 bytes")
end
