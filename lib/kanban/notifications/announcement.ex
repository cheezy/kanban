defmodule Kanban.Notifications.Announcement do
  @moduledoc """
  One-time service announcements emailed to every account (W2416), started by
  an operator through `Kanban.Release.send_launch_announcement/1`.

  An announcement is a service notice about changes to Stride itself, so it is
  sent to every confirmed, enabled user regardless of their notification
  preferences, their boards or their plan. `fan_out/2` only reads users and
  inserts jobs: one `Kanban.Notifications.AnnouncementWorker` job per
  recipient, so one slow or failing mailbox never holds up the rest.

  Jobs are unique per user and announcement key in every job state, so running
  the fan-out again enqueues nothing new while Oban still keeps the first run's
  jobs (the Pruner removes finished jobs after seven days) — not even for a
  job that was cancelled or discarded; retry one of those with
  `Oban.retry_job/2` instead. The send is meant to run once; do not run it
  again after that window.

  Nothing here logs or reports an email address: results and telemetry carry
  counts and the announcement key only.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Notifications.AnnouncementWorker
  alias Kanban.Notifications.NotificationTelemetry
  alias Kanban.Repo

  require Logger

  @keys ["organizations-launch"]

  @type result :: %{
          announcement: String.t(),
          dry_run: boolean(),
          recipients: non_neg_integer(),
          enqueued: non_neg_integer(),
          already_enqueued: non_neg_integer(),
          unconfirmed: non_neg_integer()
        }

  # How often a recipient whose job another run is inserting at that moment is
  # tried again before it is reported as unconfirmed.
  @lock_attempts 5
  @lock_wait_ms 50

  @doc "The announcement keys that have an email."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  Enqueues one email job per recipient of the announcement `key`.

  Options:

    * `:dry_run` — `true` counts the recipients and enqueues nothing; `false`
      (the default) sends. Any other value raises `ArgumentError`, so a
      mistyped dry run never sends.
    * `:oban` — the Oban instance to insert through (default `Oban`).

  Returns `{:ok, result}` where `:recipients` is the number of eligible users,
  `:enqueued` the jobs this run added, `:already_enqueued` the recipients an
  earlier run already covered and `:unconfirmed` the recipients whose job
  another run was inserting at the same moment (run again to confirm them),
  or `{:error, :unknown_announcement}` for a key with no email. Emits
  `[:kanban, :announcement, :fanout_completed]` after a real run, never after
  a dry run.
  """
  @spec fan_out(term(), keyword()) :: {:ok, result()} | {:error, :unknown_announcement}
  def fan_out(key, opts \\ [])

  def fan_out(key, opts) when key in @keys do
    dry_run? = dry_run!(opts)
    recipients = list_recipients()

    if dry_run?,
      do: {:ok, result(key, true, length(recipients), %{})},
      else: enqueue_all(key, recipients, Keyword.get(opts, :oban, Oban))
  end

  def fan_out(_key, _opts), do: {:error, :unknown_announcement}

  @doc """
  Returns the ids of every user who receives announcements — confirmed and
  enabled — in id order.
  """
  @spec list_recipients() :: [pos_integer()]
  def list_recipients do
    base_query()
    |> order_by([u], asc: u.id)
    |> select([u], u.id)
    |> Repo.all()
  end

  @doc """
  Returns the user when they still receive announcements, else `nil`, so a
  user disabled after the fan-out is skipped when their job runs.
  """
  @spec get_recipient(pos_integer()) :: User.t() | nil
  def get_recipient(user_id) when is_integer(user_id) do
    base_query()
    |> where([u], u.id == ^user_id)
    |> Repo.one()
  end

  @doc false
  # Runs `insert` (which inserts one recipient's job and returns it) until the
  # job is no longer held by a concurrent insert, then says what happened. A
  # unique insert that cannot take Oban's lock comes back as a conflict with no
  # id: the other run may still roll back, so it is not counted as covered.
  @spec await_enqueue((-> Oban.Job.t()), pos_integer()) ::
          :enqueued | :already_enqueued | :unconfirmed
  def await_enqueue(insert, attempts \\ @lock_attempts) do
    case insert.() do
      %Oban.Job{conflict?: false} ->
        :enqueued

      %Oban.Job{conflict?: true, id: id} when not is_nil(id) ->
        :already_enqueued

      %Oban.Job{conflict?: true} when attempts > 1 ->
        Process.sleep(@lock_wait_ms)
        await_enqueue(insert, attempts - 1)

      %Oban.Job{conflict?: true} ->
        :unconfirmed
    end
  end

  defp dry_run!(opts) do
    case Keyword.get(opts, :dry_run, false) do
      dry_run when is_boolean(dry_run) ->
        dry_run

      other ->
        raise ArgumentError, "expected :dry_run to be true or false, got: #{inspect(other)}"
    end
  end

  defp base_query do
    from(u in User, where: not is_nil(u.confirmed_at) and is_nil(u.disabled_at))
  end

  # Oban.insert_all ignores `unique` on the Basic engine, so insert one by one;
  # a job that already exists comes back with conflict?: true.
  defp enqueue_all(key, recipients, oban) do
    counts = Enum.frequencies_by(recipients, &enqueue(oban, key, &1))
    enqueued = Map.get(counts, :enqueued, 0)
    Logger.info("announcement #{key} fan-out: #{enqueued} of #{length(recipients)} enqueued")
    NotificationTelemetry.announcement_fanout_completed(enqueued, key)

    {:ok, result(key, false, length(recipients), counts)}
  end

  defp enqueue(oban, key, user_id) do
    job = AnnouncementWorker.new(%{user_id: user_id, key: key})
    await_enqueue(fn -> Oban.insert!(oban, job) end)
  end

  defp result(key, dry_run, recipients, counts) do
    %{
      announcement: key,
      dry_run: dry_run,
      recipients: recipients,
      enqueued: Map.get(counts, :enqueued, 0),
      already_enqueued: Map.get(counts, :already_enqueued, 0),
      unconfirmed: Map.get(counts, :unconfirmed, 0)
    }
  end
end
