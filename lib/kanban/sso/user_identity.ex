defmodule Kanban.SSO.UserIdentity do
  @moduledoc """
  Links a user to the subject an identity provider asserts for them.

  Later sign-ins match on the connection, the issuer and the subject, never on
  the email address, so an identity provider changing a user's email does not
  move the sign-in to another account. The issuer is part of the key so that
  repointing a connection at a different identity provider cannot collide with
  the old provider's subjects.

  Managed by `Kanban.SSO.Provisioning`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.Accounts.User
  alias Kanban.SSO.SSOConnection

  @type t :: %__MODULE__{}

  schema "user_identities" do
    belongs_to :user, User
    belongs_to :sso_connection, SSOConnection
    field :issuer, :string
    field :subject, :string
    field :last_login_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  A changeset for a new identity. Every field comes from server-side values
  (the provisioned user, the connection and the validated id_token), so
  nothing is cast.
  """
  @spec new_changeset(User.t(), SSOConnection.t(), String.t()) :: Ecto.Changeset.t()
  def new_changeset(%User{id: user_id}, %SSOConnection{} = connection, subject)
      when is_binary(subject) do
    %__MODULE__{}
    |> change(
      user_id: user_id,
      sso_connection_id: connection.id,
      issuer: connection.issuer,
      subject: subject,
      last_login_at: DateTime.utc_now(:second)
    )
    |> validate_length(:subject, min: 1, max: 1024)
    |> unique_constraint([:sso_connection_id, :issuer, :subject])
  end
end
