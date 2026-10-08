defmodule Kanban.Encryption.EncryptedBinary do
  @moduledoc """
  An Ecto type for a binary field that is encrypted at rest.

  The field holds plaintext in the struct and ciphertext in the database:
  `dump/1` encrypts with `Kanban.Encryption` on the way in, and `load/1`
  decrypts on the way out. A row whose ciphertext cannot be decrypted (it was
  tampered with, or written under another key) fails to load instead of
  surfacing garbage.

      field :secret, Kanban.Encryption.EncryptedBinary
  """

  use Ecto.Type

  alias Kanban.Encryption

  @impl true
  def type, do: :binary

  @impl true
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def dump(value) when is_binary(value), do: {:ok, Encryption.encrypt(value)}
  def dump(_value), do: :error

  @impl true
  def load(value) when is_binary(value) do
    case Encryption.decrypt(value) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, :invalid} -> :error
    end
  end

  def load(_value), do: :error

  # Ecto compares a field's loaded and changed values to decide what to write;
  # comparing the plaintext keeps an unchanged secret out of the UPDATE.
  @impl true
  def equal?(a, b), do: a == b
end
