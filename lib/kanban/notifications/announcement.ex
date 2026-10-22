defmodule Kanban.Notifications.Announcement do
  @moduledoc """
  One-time service announcements emailed to every account (W2416), started by
  an operator through `Kanban.Release.send_launch_announcement/1`.

  An announcement is a service notice about changes to Stride itself, so it is
  sent to every confirmed, enabled user regardless of their notification
  preferences, their boards or their plan. `fan_out/2` only reads users and
  inserts jobs: one `Kanban.Notifications.AnnouncementWorker` job per
  recipient, so one slow or failing mailbox never holds up the rest.

  Jobs are unique per user and announcement key, so running the fan-out again
  enqueues nothing new while Oban still keeps the first run's jobs (the Pruner
  removes finished jobs after seven days). The send is meant to run once; do
  not run it again after that window.

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
          already_enqueued: non_neg_integer()
        }

  @doc "The announcement keys that have an email."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  Enqueues one email job per recipient of the announcement `key`.

  Options:

    * `:dry_run` — when `true`, counts the recipients and enqueues nothing.
    * `:oban` — the Oban instance to insert through (default `Oban`).

  Returns `{:ok, result}` where `:recipients` is the number of eligible users,
  `:enqueued` the jobs this run added and `:already_enqueued` the recipients
  an earlier run already covered, or `{:error, :unknown_announcement}` for a
  key with no email. Emits `[:kanban, :announcement, :fanout_completed]` after
  a real run, never after a dry run.
  """
  @spec fan_out(term(), keyword()) :: {:ok, result()} | {:error, :unknown_announcement}
  def fan_out(key, opts \\ [])

  def fan_out(key, opts) when key in @keys do
    recipients = list_recipients()

    if Keyword.get(opts, :dry_run, false) == true,
      do: {:ok, result(key, true, length(recipients), 0)},
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

  defp base_query do
    from(u in User, where: not is_nil(u.confirmed_at) and is_nil(u.disabled_at))
  end

  # Oban.insert_all ignores `unique` on the Basic engine, so insert one by one;
  # a job that already exists comes back with conflict?: true.
  defp enqueue_all(key, recipients, oban) do
    enqueued = Enum.count(recipients, &enqueue(oban, key, &1))
    Logger.info("announcement #{key} fan-out: #{enqueued} of #{length(recipients)} enqueued")
    NotificationTelemetry.announcement_fanout_completed(enqueued, key)

    {:ok, result(key, false, length(recipients), enqueued)}
  end

  defp enqueue(oban, key, user_id) do
    %{user_id: user_id, key: key}
    |> AnnouncementWorker.new()
    |> then(&Oban.insert!(oban, &1))
    |> Map.get(:conflict?)
    |> Kernel.!()
  end

  defp result(key, dry_run, recipients, enqueued) do
    %{
      announcement: key,
      dry_run: dry_run,
      recipients: recipients,
      enqueued: enqueued,
      already_enqueued: if(dry_run, do: 0, else: recipients - enqueued)
    }
  end
end
