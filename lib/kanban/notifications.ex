defmodule Kanban.Notifications do
  @moduledoc """
  The Notifications context: durable per-user notifications, delivery
  preferences and live updates over PubSub.

  `notify/3` is the single entry point every event source uses (task
  lifecycle hooks, sweepers, the comment goal). It resolves each recipient's
  in-app and email preferences (`Kanban.Notifications.Recipients`), inserts
  at most one row per `(user, dedupe_key)` and broadcasts each new in-app row
  on that user's own topic. In the same transaction it enqueues a
  `Kanban.Notifications.EmailWorker` job for each new row whose recipient
  wants email for the event type (saved preference, else the default below).

  ## Visibility

  Read and mark functions take a `%Kanban.Accounts.Scope{}` and only ever
  touch the scoped user's in-app rows (rows stored for email-only delivery,
  with `in_app: false`, never appear in the inbox or the unread count).
  `notify/3` applies the same membership rule at write time: when an event
  names a board, recipients who do not belong to that board are dropped
  before anything is inserted or broadcast. A notification tied to a board
  is hidden once the user no longer belongs to that board; a notification
  with a nil `board_id` (an account-level event such as being removed from a
  board) is always visible to its user.

  ## Default preferences

  Preferences are stored only when a user changes them; `default_preference/1`
  supplies the rest, so existing users need no backfill. In-app delivery is on
  for every event type. Email is on for events that ask the user to act or
  that change their access:

  | Event type              | Email by default |
  |-------------------------|------------------|
  | `review_requested`      | yes              |
  | `task_reviewed`         | yes              |
  | `task_assigned`         | yes              |
  | `task_unclaimed`        | yes              |
  | `claim_expired`         | yes              |
  | `after_goal_failed`     | yes              |
  | `board_access_changed`  | yes              |
  | `target_status_changed` | yes              |
  | `mentioned`             | yes              |
  | `weekly_digest`         | yes              |
  | `goal_completed`        | no               |
  | `comment_added`         | no               |

  ## PubSub messages

  Subscribers to `topic/1` receive:

    * `{:notification_created, %Notification{}}` for every newly inserted row
    * `{:notifications_read, unread_count}` after `mark_read/2` or
      `mark_all_read/1`
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Boards.BoardUser
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Notifications.Preference
  alias Kanban.Notifications.Recipients
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @email_off_by_default [:goal_completed, :comment_added]
  @default_limit 50
  @max_limit 100

  @type event_type :: atom()
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
  Returns every notification event type, including the reserved
  `:comment_added` and `:mentioned` types.
  """
  @spec event_types() :: [event_type()]
  def event_types, do: Preference.event_types()

  @doc """
  Returns the in-code default preference for an event type, as an unsaved
  `%Preference{}` with no user.

  Accepts the atom or string form. Raises `ArgumentError` for an unknown
  event type — this is a programmer-facing API.
  """
  @spec default_preference(event_type() | String.t()) :: Preference.t()
  def default_preference(event_type) do
    case normalize_event_type(event_type) do
      {:ok, type} ->
        %Preference{event_type: type, in_app: true, email: type not in @email_off_by_default}

      :error ->
        raise ArgumentError, "unknown notification event type: #{inspect(event_type)}"
    end
  end

  @doc """
  Returns the PubSub topic carrying one user's notification events.
  """
  @spec topic(Scope.t() | User.t() | pos_integer()) :: String.t()
  def topic(%Scope{user: %User{id: id}}), do: topic(id)
  def topic(%User{id: id}), do: topic(id)
  def topic(user_id) when is_integer(user_id), do: "user:#{user_id}:notifications"

  @doc """
  Subscribes the calling process to a user's notification topic.
  """
  @spec subscribe(Scope.t() | User.t() | pos_integer()) :: :ok | {:error, term()}
  def subscribe(scope_or_user), do: Phoenix.PubSub.subscribe(Kanban.PubSub, topic(scope_or_user))

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
  @spec notify(event_type() | String.t(), [User.t() | nil], notify_attrs() | map()) ::
          {:ok, [Notification.t()]} | {:error, :invalid_event_type | Ecto.Changeset.t()}
  def notify(event_type, recipients, attrs) do
    with {:ok, type} <- event_type |> normalize_event_type() |> invalid_event_type_error(),
         :ok <- validate_task_board(type, attrs),
         {:ok, inserted} <- insert_for_recipients(type, recipients, attrs) do
      broadcast_created(inserted)
    end
  end

  @doc """
  Lists the scoped user's visible notifications, newest first.

  ## Options

    * `:unread_only` - only unread notifications (default `false`)
    * `:limit` - page size, clamped to 1..#{@max_limit} (default #{@default_limit})
    * `:before` - a `%Notification{}` cursor; returns rows older than it
  """
  @spec list_notifications(Scope.t(), keyword()) :: [Notification.t()]
  def list_notifications(%Scope{user: %User{}} = scope, opts \\ []) do
    scope
    |> visible_query()
    |> maybe_unread_only(Keyword.get(opts, :unread_only, false))
    |> maybe_before(Keyword.get(opts, :before))
    |> order_by([n], desc: n.inserted_at, desc: n.id)
    |> limit(^clamp_limit(Keyword.get(opts, :limit, @default_limit)))
    |> Repo.all()
  end

  @doc """
  Counts the scoped user's visible unread notifications.
  """
  @spec unread_count(Scope.t()) :: non_neg_integer()
  def unread_count(%Scope{user: %User{}} = scope) do
    scope
    |> visible_query()
    |> where([n], is_nil(n.read_at))
    |> select([n], count(n.id))
    |> Repo.one()
  end

  @doc """
  Marks one of the scoped user's notifications read and broadcasts the new
  unread count.

  Returns `{:error, :not_found}` for an id that does not exist, belongs to
  another user, or is hidden because the user left its board. Marking an
  already-read notification is a no-op that still succeeds.
  """
  @spec mark_read(Scope.t(), integer() | String.t()) ::
          {:ok, Notification.t()} | {:error, :not_found}
  def mark_read(%Scope{user: %User{}} = scope, id) do
    with {:ok, id} <- cast_id(id),
         %Notification{} = notification <- get_visible(scope, id),
         {:ok, notification} <- stamp_read(notification) do
      broadcast(scope.user.id, {:notifications_read, unread_count(scope)})
      {:ok, notification}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Marks every visible unread notification of the scoped user read and
  broadcasts the new unread count. Returns `{:ok, updated_count}`.

  Notifications hidden because the user left their board are left untouched,
  so this touches exactly the rows `unread_count/1` counts.
  """
  @spec mark_all_read(Scope.t()) :: {:ok, non_neg_integer()}
  def mark_all_read(%Scope{user: %User{id: user_id}} = scope) do
    now = DateTime.utc_now()

    {count, _} =
      scope
      |> visible_query()
      |> where([n], is_nil(n.read_at))
      |> Repo.update_all(set: [read_at: now, updated_at: now])

    broadcast(user_id, {:notifications_read, unread_count(scope)})
    {:ok, count}
  end

  @doc """
  Returns the scoped user's preference for every event type, in
  `event_types/0` order. Types without a saved row use
  `default_preference/1`.
  """
  @spec get_preferences(Scope.t()) :: [Preference.t()]
  def get_preferences(%Scope{user: %User{id: user_id}}) do
    saved =
      Preference
      |> where([p], p.user_id == ^user_id)
      |> Repo.all()
      |> Map.new(&{&1.event_type, &1})

    Enum.map(event_types(), fn type ->
      Map.get_lazy(saved, type, fn -> %{default_preference(type) | user_id: user_id} end)
    end)
  end

  @doc """
  Creates or updates the scoped user's preference for one event type.

  `attrs` may set `:in_app` and/or `:email`; an omitted flag keeps its
  current (or default) value. Returns `{:error, :invalid_event_type}` for an
  unknown event type.
  """
  @spec update_preference(Scope.t(), event_type() | String.t(), map()) ::
          {:ok, Preference.t()} | {:error, :invalid_event_type | Ecto.Changeset.t()}
  def update_preference(%Scope{user: %User{id: user_id}}, event_type, attrs) do
    case normalize_event_type(event_type) do
      {:ok, type} ->
        current = current_preference(user_id, type)

        %Preference{
          user_id: user_id,
          event_type: type,
          in_app: current.in_app,
          email: current.email
        }
        |> Preference.changeset(attrs)
        |> Repo.insert(
          on_conflict: {:replace, [:in_app, :email, :updated_at]},
          conflict_target: [:user_id, :event_type],
          returning: true
        )

      :error ->
        {:error, :invalid_event_type}
    end
  end

  @doc """
  Turns email off for one user and one event type, leaving in-app delivery
  as it was. Used by the signed unsubscribe links, which carry a verified
  user id and event type rather than a session.

  Idempotent. Returns `{:error, :not_found}` when the user no longer exists
  and `{:error, :invalid_event_type}` for an unknown event type.
  """
  @spec unsubscribe(pos_integer(), event_type() | String.t()) ::
          :ok | {:error, :not_found | :invalid_event_type | Ecto.Changeset.t()}
  def unsubscribe(user_id, event_type) when is_integer(user_id) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      user ->
        user
        |> Scope.for_user()
        |> update_preference(event_type, %{email: false})
        |> ok_or_error()
    end
  end

  defp ok_or_error({:ok, _preference}), do: :ok
  defp ok_or_error({:error, _reason} = error), do: error

  # -- notify/3 helpers ------------------------------------------------------

  # Resolving recipients inside the transaction lets Recipients' FOR SHARE
  # membership locks hold until the rows are inserted.
  defp insert_for_recipients(type, recipients, attrs) do
    board_id = attrs |> fetch_attr(:board_id) |> cast_optional_id()

    Repo.transaction(fn ->
      deliveries = Recipients.resolve(type, recipients, board_id, default_preference(type))

      deliveries
      |> Enum.map(&insert_notification!(&1, type, attrs))
      |> Enum.reject(&is_nil(&1.id))
      |> enqueue_emails!(deliveries)
    end)
  end

  defp enqueue_emails!(inserted, deliveries) do
    email_user_ids = for %{email: true, user_id: id} <- deliveries, into: MapSet.new(), do: id

    inserted
    |> Enum.filter(&MapSet.member?(email_user_ids, &1.user_id))
    |> EmailWorker.enqueue()
    |> case do
      :ok -> inserted
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp broadcast_created(inserted) do
    inserted
    |> Enum.filter(& &1.in_app)
    |> Enum.each(&broadcast(&1.user_id, {:notification_created, &1}))

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

  # -- query helpers ---------------------------------------------------------

  defp visible_query(%Scope{user: %User{id: user_id}}) do
    member_board_ids =
      from(bu in BoardUser, where: bu.user_id == ^user_id, select: bu.board_id)

    from(n in Notification,
      where: n.user_id == ^user_id and n.in_app == true,
      where: is_nil(n.board_id) or n.board_id in subquery(member_board_ids)
    )
  end

  defp get_visible(scope, id) do
    scope
    |> visible_query()
    |> where([n], n.id == ^id)
    |> Repo.one()
  end

  defp maybe_unread_only(query, true), do: where(query, [n], is_nil(n.read_at))
  defp maybe_unread_only(query, _), do: query

  defp maybe_before(query, %Notification{inserted_at: inserted_at, id: id}) do
    where(
      query,
      [n],
      n.inserted_at < ^inserted_at or (n.inserted_at == ^inserted_at and n.id < ^id)
    )
  end

  defp maybe_before(query, _), do: query

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp clamp_limit(_), do: @default_limit

  # -- misc helpers ----------------------------------------------------------

  defp stamp_read(%Notification{read_at: nil} = notification) do
    notification
    |> Ecto.Changeset.change(read_at: DateTime.utc_now())
    |> Repo.update()
  end

  defp stamp_read(%Notification{} = notification), do: {:ok, notification}

  defp current_preference(user_id, type) do
    Repo.get_by(Preference, user_id: user_id, event_type: type) || default_preference(type)
  end

  defp fetch_attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  defp fetch_attr(_attrs, _key), do: nil

  defp cast_optional_id(nil), do: nil

  defp cast_optional_id(id) do
    case cast_id(id) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp cast_id(id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} when is_integer(id) -> {:ok, id}
      _ -> :error
    end
  end

  defp normalize_event_type(type) when is_atom(type) do
    if type in Preference.event_types(), do: {:ok, type}, else: :error
  end

  defp normalize_event_type(type) when is_binary(type) do
    case Enum.find(Preference.event_types(), &(Atom.to_string(&1) == type)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  defp normalize_event_type(_), do: :error

  defp broadcast(user_id, message) do
    Phoenix.PubSub.broadcast(Kanban.PubSub, topic(user_id), message)
  end
end
