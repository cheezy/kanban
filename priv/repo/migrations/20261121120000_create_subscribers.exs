defmodule Kanban.Repo.Migrations.CreateSubscribers do
  @moduledoc """
  Creates the release announcement list (`Kanban.Subscribers`): one row per
  address someone asked to subscribe, and the hashed tokens that confirm or
  unsubscribe it.

  `subscribers.email` is `citext` with a unique index, so the same address in
  any letter case is one row. A row stays `pending` until its confirmation
  link is used, and records the locale, the consent text the visitor saw and
  when they agreed (CASL). No user is referenced: the list is separate from
  accounts.

  `subscriber_tokens` holds only the SHA-256 hash of each emailed token, with
  its context (`"confirm"` or `"unsubscribe"`); expiry is measured from
  `inserted_at`. Each email can carry its own unsubscribe token, so a newer
  email never breaks the link in an older one. Tokens are deleted with their
  subscriber.
  """
  use Ecto.Migration

  def change do
    create table(:subscribers) do
      add :email, :citext, null: false
      add :locale, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :consent_text, :text, null: false
      add :consented_at, :utc_datetime, null: false
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subscribers, [:email])

    create constraint(:subscribers, :subscribers_status_check,
             check: "status IN ('pending', 'active')"
           )

    create table(:subscriber_tokens) do
      add :subscriber_id, references(:subscribers, on_delete: :delete_all), null: false
      add :context, :string, null: false
      add :token_hash, :binary, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:subscriber_tokens, [:context, :token_hash])
    create index(:subscriber_tokens, [:subscriber_id])
  end
end
