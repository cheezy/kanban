defmodule Kanban.Notifications.Delivery do
  @moduledoc """
  Writes an event's notifications and enqueues their email and push jobs:
  the implementation of `Kanban.Notifications.notify/3`.

  `notify/3` resolves each recipient's in-app, email and push preferences
  (`Kanban.Notifications.Recipients`), inserts at most one row per
  `(user, dedupe_key)` and broadcasts each new in-app row on that user's own
  topic (`Kanban.Notifications.Broadcaster`). In the same transaction it
  enqueues a `Kanban.Notifications.EmailWorker` job for each new row whose
  recipient wants email for the event type, and a `Kanban.Push.PushWorker`
  job for each new row whose recipient has push on for it, an active device
  with a push token and paid access. A recipient with push on but in-app and
  email off gets a hidden row only when a push can reach them.

  While paid plans are enforced, an event on a board that is not paid is
  dropped before anything is locked, inserted or enqueued, and a recipient
  without paid access gets no email job.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Notifications.Broadcaster
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Notifications.NotificationTelemetry
  alias Kanban.Notifications.Preferences
  alias Kanban.Notifications.Recipients
  alias Kanban.Plans
  alias Kanban.Push.PushWorker
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @type notify_attrs :: %{
          optional(:title) => String.t(),
          optional(:body) => String.t() | nil,
          optional(:url_path) => String.t() | nil,
          optional(:actor_name) => String.t() | nil,
          optional(:metadata) => map(),
          optional(:board_id) => integer() | nil,
          optional(:task_id) => integer() | nil,
          optional(:dedupe_key) => String.t() | nil
        }

  @doc """
  Records an event for a list of recipients.

  `recipients` is a list of users (any map with an integer `:id`); `nil`
  entries and duplicates are ignored, and when `:board_id` is given only
  current members of that board are notified. `attrs` accepts `:title` (required),
  `:body`, `:url_path` (app-relative), `:actor_name`, `:metadata`,
  `:board_id`, `:task_id` and `:dedupe_key`, all with atom keys or all with
  string keys. `:board_id` is required unless the event type is one of
  `Kanban.Notifications.Notification.board_less_event_types/0`, and a
  `:task_id` must belong to that board. Board-less notifications stay visible
  after the user leaves every board, so callers must not put task titles or
  identifiers in their `:title` or `:body`; the changeset rejects board-scoped
  `:url_path` values and task metadata keys on them.

  In-app and email preferences are independent. A recipient with both off is
  skipped. A recipient with in-app off but email on gets a row stored with
  `in_app: false`, which is never listed, counted or broadcast but is emailed.
  For each inserted row whose recipient's email preference is on, an
  `EmailWorker` job is enqueued in the same transaction.
  The same `dedupe_key` yields at most one row per recipient, so retries and
  races are idempotent. Each newly inserted in-app row is broadcast as
  `{:notification_created, notification}` on its recipient's topic after the
  transaction commits.

  Returns `{:ok, inserted}` (only the rows actually inserted, including
  email-only rows),
  `{:error, :invalid_event_type}`, or `{:error, changeset}` when the
  attributes are invalid — in which case nothing is inserted for anyone.

  ## Examples

      iex> notify(:task_assigned, [user], %{title: "W12 was assigned to you"})
      {:ok, [%Notification{}]}

      iex> notify("bogus", [user], %{title: "x"})
      {:error, :invalid_event_type}

  """
  @spec notify(
          Preferences.event_type() | String.t(),
          [User.t() | nil],
          notify_attrs() | map()
        ) ::
          {:ok, [Notification.t()]} | {:error, :invalid_event_type | Ecto.Changeset.t()}
  def notify(event_type, recipients, attrs) do
    with {:ok, type} <-
           event_type |> Preferences.normalize_event_type() |> invalid_event_type_error(),
         :ok <- validate_task_board(type, attrs),
         :ok <- check_board_plan(attrs),
         {:ok, inserted} <- insert_for_recipients(type, recipients, attrs) do
      inserted
      |> broadcast_created()
      |> NotificationTelemetry.created()
    end
  end

  # Resolving recipients inside the transaction lets Recipients' FOR SHARE
  # membership locks hold until the rows are inserted.
  defp insert_for_recipients(type, recipients, attrs) do
    board_id = attrs |> fetch_attr(:board_id) |> cast_optional_id()

    Repo.transaction(fn -> deliver_in_transaction(type, recipients, board_id, attrs) end)
  end

  defp deliver_in_transaction(type, recipients, board_id, attrs) do
    default = Preferences.default_preference(type)
    deliveries = Recipients.resolve(type, recipients, board_id, default)
    push_user_ids = PushWorker.recipient_ids(type, deliveries)

    deliveries
    |> Enum.filter(&row_needed?(&1, push_user_ids))
    |> Enum.map(&insert_notification!(&1, type, attrs))
    |> Enum.reject(&is_nil(&1.id))
    |> enqueue_emails!(deliveries)
    |> enqueue_pushes!(push_user_ids)
  end

  # A push-only delivery gets a (hidden) row only when a push can reach it.
  defp row_needed?(%{in_app: in_app, email: email, user_id: user_id}, push_user_ids),
    do: in_app or email or MapSet.member?(push_user_ids, user_id)

  # Only recipients who want email and have paid access get a job.
  defp enqueue_emails!(inserted, deliveries) do
    email_user_ids =
      for(%{email: true, user_id: id} <- deliveries, do: id) |> Plans.unlocked_user_ids()

    inserted
    |> Enum.filter(&MapSet.member?(email_user_ids, &1.user_id))
    |> EmailWorker.enqueue()
    |> case do
      :ok -> inserted
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # Only recipients PushWorker.recipient_ids/2 picked get a job; it only
  # enqueues, the worker sends.
  defp enqueue_pushes!(inserted, push_user_ids) do
    case PushWorker.enqueue(inserted, push_user_ids) do
      :ok -> inserted
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp broadcast_created(inserted) do
    inserted
    |> Enum.filter(& &1.in_app)
    |> Enum.each(&Broadcaster.broadcast(&1.user_id, {:notification_created, &1}))

    {:ok, inserted}
  end

  defp invalid_event_type_error(:error), do: {:error, :invalid_event_type}
  defp invalid_event_type_error({:ok, _} = ok), do: ok

  defp validate_task_board(type, attrs) do
    task_id = attrs |> fetch_attr(:task_id) |> cast_optional_id()
    board_id = attrs |> fetch_attr(:board_id) |> cast_optional_id()

    if is_nil(task_id) or is_nil(board_id) or task_board_id(task_id) == board_id do
      :ok
    else
      changeset =
        %Notification{event_type: type}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:task_id, "does not belong to the board")

      {:error, %{changeset | action: :insert}}
    end
  end

  # A free board's events are dropped while plans are enforced. Returning
  # {:ok, []} ends notify/3's with chain before any lock, insert or job.
  defp check_board_plan(attrs) do
    case attrs |> fetch_attr(:board_id) |> cast_optional_id() do
      nil -> :ok
      board_id -> if Plans.board_unlocked?(board_id), do: :ok, else: {:ok, []}
    end
  end

  defp task_board_id(task_id) do
    from(t in Task, join: c in assoc(t, :column), where: t.id == ^task_id, select: c.board_id)
    |> Repo.one()
  end

  defp insert_notification!(%{user_id: user_id, in_app: in_app}, type, attrs) do
    %Notification{user_id: user_id, event_type: type, in_app: in_app}
    |> Notification.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :dedupe_key])
    |> case do
      {:ok, notification} -> notification
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  defp fetch_attr(_attrs, _key), do: nil

  # nil, and anything that does not cast to an integer id, is "no id".
  defp cast_optional_id(id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} when is_integer(id) -> id
      _ -> nil
    end
  end
end
