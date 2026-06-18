defmodule Kanban.Accounts.UserIdentity do
  @moduledoc """
  External identity linked to a local Stride user.

  OIDC login uses this table to bind the provider issuer + subject pair to
  Stride's existing `users` rows without replacing the generated session system.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "user_identities" do
    field :provider, :string
    field :issuer, :string
    field :subject, :string
    field :email, :string
    field :claims, :map, default: %{}
    field :last_login_at, :utc_datetime

    belongs_to :user, Kanban.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:provider, :issuer, :subject, :email, :claims, :last_login_at])
    |> validate_required([:provider, :issuer, :subject, :email, :claims])
    |> validate_length(:provider, max: 80)
    |> validate_length(:issuer, max: 500)
    |> validate_length(:subject, max: 500)
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> unique_constraint([:issuer, :subject])
  end
end
