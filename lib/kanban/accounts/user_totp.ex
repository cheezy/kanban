defmodule Kanban.Accounts.UserTotp do
  @moduledoc """
  A user's TOTP two-factor record.

  The shared `secret` is encrypted at rest (`Kanban.Encryption.EncryptedBinary`).
  Two-factor is enabled only once `confirmed_at` is set; before that the row is
  an enrollment in progress. `last_used_step` is the TOTP time step of the last
  accepted code, which stops a code from being used twice.
  `recovery_code_hashes` holds keyed HMAC-SHA256 digests
  (`Kanban.Encryption.hmac/1`, bound to the user id) of the unused recovery
  codes, never the codes themselves.

  Managed by `Kanban.Accounts.TwoFactor`.
  """

  use Ecto.Schema

  alias Kanban.Accounts.User

  @type t :: %__MODULE__{}

  schema "user_totps" do
    belongs_to :user, User
    field :secret, Kanban.Encryption.EncryptedBinary, redact: true
    field :confirmed_at, :utc_datetime
    field :last_used_step, :integer
    field :recovery_code_hashes, {:array, :binary}, default: [], redact: true

    timestamps(type: :utc_datetime)
  end
end
