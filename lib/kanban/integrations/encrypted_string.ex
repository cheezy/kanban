defmodule Kanban.Integrations.EncryptedString do
  @moduledoc """
  An Ecto type for a string that is itself a credential (W2226), such as a
  webhook URL: a Slack incoming-webhook URL lets anyone who holds it post to
  the channel. The struct holds the plaintext; the column holds
  `Kanban.Integrations.SecretBox` ciphertext, written on every dump.

  The ciphertext differs on every write, so a column of this type can never
  be queried by value.

  A value the current `secret_key_base` cannot decrypt (the key base was
  rotated) loads as `nil` rather than failing the whole query, so the record
  can still be listed and its owner can enter the value again.
  """
  use Ecto.Type

  alias Kanban.Integrations.SecretBox

  @impl true
  def type, do: :binary

  @impl true
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def dump(value) when is_binary(value), do: {:ok, SecretBox.encrypt(value)}
  def dump(_value), do: :error

  @impl true
  def load(ciphertext) when is_binary(ciphertext) do
    case SecretBox.decrypt(ciphertext) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, :invalid} -> {:ok, nil}
    end
  end

  def load(_value), do: :error
end
