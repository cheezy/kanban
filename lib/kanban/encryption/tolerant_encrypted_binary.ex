defmodule Kanban.Encryption.TolerantEncryptedBinary do
  @moduledoc """
  An Ecto type for a binary field that is encrypted at rest and that still
  loads when its ciphertext cannot be decrypted.

  It encrypts and decrypts through `Kanban.Encryption` exactly as
  `Kanban.Encryption.EncryptedBinary` does, with one difference: a value that
  `Kanban.Encryption.decrypt/1` rejects (written under a lost or replaced
  `ENCRYPTION_KEY`, or tampered with) loads as the atom `:unreadable` instead
  of failing the whole row (D17). Pages and sweeps that read such a row can
  then report the problem rather than crash.

  `:unreadable` is a marker, never data: `cast/1` and `dump/1` refuse it, so a
  form cannot submit it and it can never be written over the stored
  ciphertext. `nil` never reaches this type (Ecto passes it through), so a
  field that is not set stays `nil` and is never reported as unreadable.

  Two-factor and SSO secrets keep using `EncryptedBinary`, which fails to load
  an unreadable value.

      field :credential, Kanban.Encryption.TolerantEncryptedBinary, redact: true
  """

  use Ecto.Type

  alias Kanban.Encryption

  @impl true
  def type, do: :binary

  @impl true
  def cast(:unreadable), do: :error
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def dump(:unreadable), do: :error
  def dump(value) when is_binary(value), do: {:ok, Encryption.encrypt(value)}
  def dump(_value), do: :error

  @impl true
  def load(value) when is_binary(value) do
    case Encryption.decrypt(value) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, :invalid} -> {:ok, :unreadable}
    end
  end

  def load(_value), do: :error

  # Ecto compares a field's loaded and changed values to decide what to write;
  # comparing the plaintext keeps an unchanged secret out of the UPDATE.
  @impl true
  def equal?(a, b), do: a == b
end
