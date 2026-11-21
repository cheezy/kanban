defmodule Kanban.Subscribers.Subscriber do
  @moduledoc """
  One address on the release announcement list (`Kanban.Subscribers`).

  A subscriber is `:pending` until the confirmation link in its email is
  used, then `:active`. It records the locale its emails are written in, the
  consent text the visitor agreed to and when (`consent_text`,
  `consented_at`), and when it was confirmed. `email` is `citext`, so the
  same address in any letter case is one row.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.ChangesetText

  @type t :: %__MODULE__{}

  schema "subscribers" do
    field :email, :string
    field :locale, :string
    field :status, Ecto.Enum, values: [:pending, :active], default: :pending
    field :consent_text, :string
    field :consented_at, :utc_datetime
    field :confirmed_at, :utc_datetime

    has_many :tokens, Kanban.Subscribers.SubscriberToken

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates a signup: a trimmed address of at most 160 characters with one
  `@`, no spaces, no invisible format or control characters and no trailing
  dot, a known locale, and the consent text and time. The last two rules stop
  `name@example.test.` or a zero-width character from passing an address
  already on the list off as a new one.
  """
  @spec signup_changeset(t(), map()) :: Ecto.Changeset.t()
  def signup_changeset(subscriber, attrs) do
    subscriber
    |> cast(attrs, [:email, :locale, :consent_text, :consented_at])
    |> update_change(:email, &String.trim/1)
    |> ChangesetText.validate_storable([:email])
    |> validate_required([:email, :locale, :consent_text, :consented_at])
    |> validate_format(
      :email,
      ~r/^[^@,;\s\p{Cc}\p{Cf}]+@[^@,;\s\p{Cc}\p{Cf}]*[^@,;\s\p{Cc}\p{Cf}.]$/u,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> validate_inclusion(:locale, Gettext.known_locales(KanbanWeb.Gettext))
    |> unique_constraint(:email)
  end

  @doc """
  Renews the consent of a pending subscriber who signs up again after their
  confirmation link expired.
  """
  @spec renew_changeset(t(), map()) :: Ecto.Changeset.t()
  def renew_changeset(subscriber, attrs) do
    subscriber
    |> cast(attrs, [:locale, :consent_text, :consented_at])
    |> validate_required([:locale, :consent_text, :consented_at])
  end

  @doc "Marks the subscriber confirmed at `now`."
  @spec confirm_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def confirm_changeset(subscriber, now) do
    change(subscriber, status: :active, confirmed_at: now)
  end
end
