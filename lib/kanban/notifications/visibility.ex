defmodule Kanban.Notifications.Visibility do
  @moduledoc """
  Which notifications a scoped user can see, and the task-notification read
  that `Kanban.Decisions` builds its released and claim-expired items from.

  `query/1` is the visibility rule `Kanban.Notifications` applies to every
  read and mark function: the scoped user's own in-app rows, on boards they
  still hold a `board_users` row on (or with no board), and while paid plans
  are enforced only paid boards' rows. Hidden rows are kept, so they
  reappear if the user rejoins the board or the board becomes paid.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Boards.BoardUser
  alias Kanban.Notifications.Notification
  alias Kanban.Plans
  alias Kanban.Repo

  @doc """
  The query of every notification the scoped user can see.
  """
  @spec query(Scope.t()) :: Ecto.Query.t()
  def query(%Scope{user: %User{id: user_id}}) do
    member_board_ids =
      from(bu in BoardUser, where: bu.user_id == ^user_id, select: bu.board_id)

    from(n in Notification,
      where: n.user_id == ^user_id and n.in_app == true,
      where: is_nil(n.board_id) or n.board_id in subquery(member_board_ids)
    )
    |> paid_boards_only()
  end

  @doc """
  Lists the scoped user's visible notifications of `event_types` whose task
  is unarchived and sits on one of `board_ids`, newest first, with the task
  and its column preloaded. One query; read or unread alike.

  `board_ids` is required and is always the caller's own list of boards the
  user can access, never ids from a client. An empty list returns `[]`
  without querying.

  ## Options

    * `:task_statuses` - only rows whose task has one of these statuses
  """
  @spec list_task_notifications(Scope.t(), [atom()], [integer()], keyword()) ::
          [Notification.t()]
  def list_task_notifications(scope, event_types, board_ids, opts \\ [])

  def list_task_notifications(_scope, _event_types, [], _opts), do: []
  def list_task_notifications(_scope, [], _board_ids, _opts), do: []

  def list_task_notifications(%Scope{user: %User{}} = scope, event_types, board_ids, opts)
      when is_list(event_types) and is_list(board_ids) do
    scope
    |> query()
    |> join(:inner, [n], t in assoc(n, :task), as: :task)
    |> join(:inner, [task: t], c in assoc(t, :column), as: :column)
    |> where([n, task: t, column: c], n.event_type in ^event_types)
    |> where([task: t, column: c], is_nil(t.archived_at) and c.board_id in ^board_ids)
    |> maybe_task_statuses(Keyword.get(opts, :task_statuses))
    |> order_by([n], desc: n.inserted_at, desc: n.id)
    |> preload([task: t, column: c], task: {t, column: c})
    |> Repo.all()
  end

  defp maybe_task_statuses(query, statuses) when is_list(statuses),
    do: where(query, [task: t], t.status in ^statuses)

  defp maybe_task_statuses(query, _statuses), do: query

  # While plans are enforced only paid boards' rows and board-less rows show.
  defp paid_boards_only(query) do
    if Plans.enforced?(),
      do:
        where(
          query,
          [n],
          is_nil(n.board_id) or n.board_id in subquery(Plans.paid_board_ids_query())
        ),
      else: query
  end
end
