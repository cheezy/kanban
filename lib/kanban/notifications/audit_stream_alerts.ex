defmodule Kanban.Notifications.AuditStreamAlerts do
  @moduledoc """
  The security emails every enabled org-admin of an Organization receives
  about its audit stream destinations
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.4, §8.6, §8.8, §12.3, §13.3),
  through `Kanban.Notifications.enqueue_audit_stream_email/4`.

  `enqueue/4` inserts one `Kanban.Notifications.AuditStreamEmailWorker` job
  per enabled org-admin. Call it inside the transaction that makes the
  change, so a change that rolls back emails nobody: it returns `{:error,
  changeset}` for the first job it could not insert, for the caller to roll
  back. They are security emails, so no notification preference or plan
  gates them, and the org-admin who acted is emailed too.

  The job args are a snapshot: the destination's id, type, name, host and
  last-4 hints, the start point, the names of the changed fields, the
  failing reason or the gap's counts, and the actor's id. A deleted
  destination is gone when its email is sent, so nothing is read from it
  then. The snapshot never holds a URL, credential, header value, signing
  secret or email address: the destination is read without its encrypted
  columns.

  The throttles live here as pure functions the callers apply in the same
  transaction: `status_alert/3` for Failing, recovered and the re-seed
  (`failing_emailed_at`, `recovered_emailed_at`), and `gap_email_due?/2` for a
  growing gap (`emailed_at`). `emailed_changes/1` says which edited fields
  are emailed. Nothing here adds a telemetry event (§13.1) or logs an
  address.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Kanban.Accounts.User
  alias Kanban.AuditStream.Destination
  alias Kanban.Notifications.AuditStreamEmailWorker
  alias Kanban.Organizations
  alias Kanban.Repo

  require Logger

  @kinds [
    :created,
    :updated,
    :paused,
    :resumed,
    :deleted,
    :failing,
    :recovered,
    :txid_reset,
    :gap
  ]

  # The edited fields whose change is emailed (§12.3), in the order an email
  # lists them; the name, the Splunk source type and the HTTPS format are not.
  @emailed_fields [:url, :credential, :include_personal_data, :excluded_actions]
  @emailed_settings %{
    splunk_hec: ~w(index),
    datadog: ~w(site service tags),
    https: ~w(header_name)
  }

  @status_interval_seconds 60 * 60
  @gap_interval_seconds 7 * 24 * 60 * 60

  @typedoc "A destination, a map holding its `:id`, or the id."
  @type destination_ref :: Destination.t() | %{required(:id) => pos_integer()} | pos_integer()

  @typedoc "What `status_alert/3` decides: the email, its details and the timestamp to set."
  @type status_alert :: {:failing | :recovered | :txid_reset, map(), map()} | nil

  @doc "The email kinds `enqueue/4` takes."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Enqueues the `kind` email about `destination` for every enabled org-admin
  of its Organization. `actor` is the user who acted, or `nil` when Stride
  recorded it. `details` carries `:start_from` (created), `:changed`
  (updated), `:reason` (failing) or `:gap` (gap), as `email_details/2`
  keeps them.

  Returns `:ok` — also when the destination no longer exists or the
  Organization has no enabled org-admin — or `{:error, changeset}`.
  """
  @spec enqueue(atom(), destination_ref(), User.t() | nil, map()) ::
          :ok | {:error, Changeset.t()}
  def enqueue(kind, destination, actor, details \\ %{})
      when kind in @kinds and is_map(details) do
    case destination |> destination_id() |> snapshot() do
      nil ->
        :ok

      snapshot ->
        base = base_args(kind, snapshot, actor, details)
        recipients = Organizations.list_enabled_org_admins(snapshot.organization_id)
        result = Enum.reduce_while(recipients, :ok, &insert_job(base, &1, &2))
        log_enqueued(result, kind, snapshot.id, length(recipients))
        result
    end
  end

  @doc """
  The email a dispatch run's status `plan` calls for, given the destination
  as it was `before` the run, at `now`; `nil` for none. It returns `{kind,
  details, timestamps}`, the timestamps to write with the plan's status
  fields:

    * `:txid_reset` when the run halts the destination with `txid_reset`. The
      halt bounds it, since only a re-seed clears it, so it is not throttled.
    * `:failing` on the move into Failing, and when the run halts a Failing
      destination with `credentials_unreadable`, which needs an org-admin; at
      most once an hour (`failing_emailed_at`).
    * `:recovered` on the move from Failing back to Healthy, at most once an
      hour (`recovered_emailed_at`).
  """
  @spec status_alert(Destination.t(), map(), DateTime.t()) :: status_alert()
  def status_alert(%Destination{} = before, plan, now) do
    at = DateTime.truncate(now, :second)

    cond do
      new_halt?(before, plan, :txid_reset) ->
        {:txid_reset, %{}, %{failing_emailed_at: at}}

      failing_reason(before, plan) != nil and due?(before.failing_emailed_at, at) ->
        {:failing, %{reason: failing_reason(before, plan)}, %{failing_emailed_at: at}}

      plan.audit == :recovered and due?(before.recovered_emailed_at, at) ->
        {:recovered, %{}, %{recovered_emailed_at: at}}

      true ->
        nil
    end
  end

  @doc """
  Whether a growing gap last emailed at `emailed_at` is due another email at
  `now`: never emailed, or at least 7 days ago.
  """
  @spec gap_email_due?(DateTime.t() | nil, DateTime.t()) :: boolean()
  def gap_email_due?(nil, _now), do: true

  def gap_email_due?(%DateTime{} = emailed_at, now),
    do: DateTime.diff(now, emailed_at) >= @gap_interval_seconds

  @doc """
  The emailed fields an update `changeset` changes, as strings in the order
  an email lists them: the URL, credential, personal-data setting and
  excluded actions, then the kind's settings that decide where events go
  (the Splunk index; the Datadog site, service and tags; the HTTPS header
  name). `[]` when none changes, so a change to the name alone is not
  emailed.
  """
  @spec emailed_changes(Changeset.t()) :: [String.t()]
  def emailed_changes(%Changeset{data: %Destination{} = data, changes: changes}) do
    fields = for field <- @emailed_fields, Map.has_key?(changes, field), do: to_string(field)
    fields ++ changed_settings(data, changes)
  end

  # --- enqueue ----------------------------------------------------------------

  defp destination_id(%{id: id}), do: id
  defp destination_id(id) when is_integer(id), do: id

  # Only plain columns are read, so no encrypted secret is ever loaded.
  defp snapshot(id) do
    from(d in Destination,
      where: d.id == ^id,
      select: %{
        id: d.id,
        organization_id: d.organization_id,
        kind: d.kind,
        name: d.name,
        url_host: d.url_host,
        url_hint: d.url_hint,
        credential_hint: d.credential_hint,
        settings: d.settings
      }
    )
    |> Repo.one()
  end

  defp base_args(kind, snapshot, actor, details) do
    %{
      alert: to_string(kind),
      ref: Ecto.UUID.generate(),
      organization_id: snapshot.organization_id,
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      actor_id: actor_id(actor),
      destination: %{
        id: snapshot.id,
        kind: to_string(snapshot.kind),
        name: snapshot.name,
        url_host: snapshot.url_host,
        url_hint: snapshot.url_hint,
        credential_hint: snapshot.credential_hint,
        site: site(snapshot.settings)
      },
      details: email_details(kind, details)
    }
  end

  defp actor_id(%User{id: id}), do: id
  defp actor_id(nil), do: nil

  defp site(%{"site" => site}) when is_binary(site), do: site
  defp site(_settings), do: nil

  defp email_details(:created, details),
    do: %{start_from: to_string(details[:start_from] || "now")}

  defp email_details(:updated, details),
    do: %{changed: Enum.map(details[:changed] || [], &to_string/1)}

  defp email_details(:failing, details), do: %{reason: to_string(details[:reason])}
  defp email_details(:gap, %{gap: gap}), do: %{gap: gap_details(gap)}
  defp email_details(_kind, _details), do: %{}

  defp gap_details(gap) do
    %{
      reason: to_string(gap.reason),
      events: gap.events,
      first_at: DateTime.to_iso8601(gap.first_at),
      last_at: DateTime.to_iso8601(gap.last_at),
      opened: gap.opened == true
    }
  end

  defp insert_job(base, %User{id: user_id}, :ok) do
    case base |> Map.put(:user_id, user_id) |> AuditStreamEmailWorker.new() |> Oban.insert() do
      {:ok, _job} -> {:cont, :ok}
      {:error, changeset} -> {:halt, {:error, changeset}}
    end
  end

  defp log_enqueued(:ok, kind, destination_id, count),
    do:
      Logger.info(
        "audit stream #{kind} email destination_id=#{destination_id}: #{count} enqueued"
      )

  defp log_enqueued(_error, kind, destination_id, _count),
    do:
      Logger.warning("audit stream #{kind} email destination_id=#{destination_id}: not enqueued")

  # --- throttles --------------------------------------------------------------

  defp new_halt?(before, plan, reason),
    do: Map.get(plan.destination, :halted_reason) == reason and before.halted_reason != reason

  defp failing_reason(_before, %{audit: {:failing, reason}}), do: reason

  defp failing_reason(before, plan) do
    if new_halt?(before, plan, :credentials_unreadable), do: :credentials_unreadable
  end

  defp due?(nil, _now), do: true
  defp due?(%DateTime{} = at, now), do: DateTime.diff(now, at) >= @status_interval_seconds

  # --- changes ----------------------------------------------------------------

  defp changed_settings(%Destination{kind: kind, settings: before}, %{settings: after_change}) do
    before = before || %{}

    for key <- Map.get(@emailed_settings, kind, []),
        Map.get(before, key) != Map.get(after_change, key),
        do: key
  end

  defp changed_settings(_data, _changes), do: []
end
