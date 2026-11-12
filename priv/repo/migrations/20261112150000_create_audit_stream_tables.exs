defmodule Kanban.Repo.Migrations.CreateAuditStreamTables do
  @moduledoc """
  Audit log streaming storage (W2704, design §9.2, §9.3, §9.4, §9.6).

  Four tables: the destinations an Organization streams to, one cursor per
  destination (a separate table so the worker's frequent writes never
  conflict with an org-admin's edit, §9.3), the delivery attempts, and the
  gaps where events could not be delivered. Secret columns hold ciphertext
  written by `Kanban.Encryption.TolerantEncryptedBinary`. Nothing here
  references `audit_events`, so no cascade can reach the audit log.
  """

  use Ecto.Migration

  def change do
    create table(:audit_stream_destinations) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :name, :string, size: 80, null: false
      add :enabled, :boolean, null: false, default: true
      add :url, :binary
      add :url_host, :string
      add :url_hint, :string, size: 4
      add :settings, :map, null: false, default: %{}
      add :credential, :binary
      add :credential_hint, :string, size: 4
      add :signing_secret, :binary
      add :previous_signing_secret, :binary
      add :previous_secret_expires_at, :utc_datetime
      add :include_personal_data, :boolean, null: false, default: true
      add :excluded_actions, {:array, :string}, null: false, default: []
      add :filter_version, :integer, null: false, default: 1
      add :schema_version, :integer, null: false, default: 1
      add :state, :string, null: false, default: "healthy"
      add :state_reason, :string
      add :halted_reason, :string
      add :failing_since, :utc_datetime
      add :consecutive_failures, :integer, null: false, default: 0
      add :last_success_at, :utc_datetime
      add :failing_emailed_at, :utc_datetime
      add :recovered_emailed_at, :utc_datetime
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:audit_stream_destinations, [:organization_id, :name])
    create index(:audit_stream_destinations, [:created_by_id])

    create table(:audit_stream_cursors, primary_key: false) do
      add :destination_id,
          references(:audit_stream_destinations, on_delete: :delete_all),
          primary_key: true,
          null: false

      add :last_txid, :bigint, null: false
      add :last_event_id, :bigint, null: false
      add :last_inserted_at, :utc_datetime_usec
      add :not_before, :utc_datetime_usec
      add :pending_batch_id, :uuid
      add :pending_first_txid, :bigint
      add :pending_first_id, :bigint
      add :pending_last_txid, :bigint
      add :pending_last_id, :bigint
      add :pending_attempts, :integer, null: false, default: 0
      add :pending_filter_version, :integer
      add :next_attempt_at, :utc_datetime_usec
      add :leased_until, :utc_datetime_usec
      add :lease_token, :uuid

      timestamps(type: :utc_datetime_usec, inserted_at: false)
    end

    create table(:audit_stream_attempts) do
      add :destination_id, references(:audit_stream_destinations, on_delete: :delete_all),
        null: false

      add :batch_id, :uuid, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :duration_ms, :integer
      add :event_count, :integer
      add :bytes, :integer
      add :first_event_id, :bigint
      add :last_event_id, :bigint
      add :http_status, :integer
      add :outcome, :string, null: false
      add :error, :string, size: 200
    end

    create index(:audit_stream_attempts, [:destination_id, :started_at])

    create table(:audit_stream_gaps) do
      add :destination_id, references(:audit_stream_destinations, on_delete: :delete_all),
        null: false

      add :reason, :string, null: false
      add :events, :integer, null: false, default: 0
      add :first_occurred_at, :utc_datetime_usec, null: false
      add :last_occurred_at, :utc_datetime_usec, null: false
      add :opened_at, :utc_datetime_usec, null: false
      add :last_extended_at, :utc_datetime_usec, null: false
      add :emailed_at, :utc_datetime_usec
      add :audited_at, :utc_datetime_usec
      add :dismissed_at, :utc_datetime_usec
      add :dismissed_by_id, references(:users, on_delete: :nilify_all)
    end

    create index(:audit_stream_gaps, [:destination_id, :dismissed_at])
    create index(:audit_stream_gaps, [:dismissed_by_id])
  end
end
