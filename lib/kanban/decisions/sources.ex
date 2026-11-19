defmodule Kanban.Decisions.Sources do
  @moduledoc """
  The five decision sources behind `Kanban.Decisions.build/1`, one function
  per kind, and the shared context they read.

  `context/3` loads what more than one source needs once: the boards the
  person can see (already narrowed to the plan), their access to each, the
  person's `task_unclaimed` and `claim_expired` notifications, and the
  Ready and Backlog task counts per board. Each source then returns plain
  item maps in the shape `Kanban.Decisions` documents.

  Actions follow the same write checks the web applies: approving, asking
  for changes and moving a task need owner or modify access; replying needs
  only membership, as `Kanban.Tasks.CommentPolicy` allows any member to
  comment.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Agents
  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Notifications
  alias Kanban.Notifications.Notification
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Reviews.MobileReview
  alias Kanban.Tasks.Task

  @write_access [:owner, :modify]
  @pill_sections [:acceptance_criteria, :testing_strategy, :patterns, :security_considerations]
  @notification_types [:task_unclaimed, :claim_expired]
  @agent_task_types [:work, :defect]
  @recent_agent_seconds 24 * 60 * 60

  @doc """
  Builds the context every source reads, for `boards`: the boards the
  scoped `user` can access that the plan unlocks, each with its virtual
  `:user_access` set.
  """
  @spec context(Scope.t(), Kanban.Accounts.User.t(), [Kanban.Boards.Board.t()]) :: map()
  def context(%Scope{} = scope, user, boards) do
    board_ids = Enum.map(boards, & &1.id)

    %{
      scope: scope,
      user: user,
      now: DateTime.utc_now(),
      boards: Map.new(boards, &{&1.id, &1}),
      access: Map.new(boards, &{&1.id, &1.user_access}),
      notifications:
        Notifications.list_task_notifications(scope, @notification_types, board_ids,
          task_statuses: [:open, :in_progress]
        ),
      columns: column_counts(board_ids)
    }
  end

  # -- review ----------------------------------------------------------------

  @doc """
  Pending reviews on the context's boards, from the same query as `/review`.
  """
  @spec review(map()) :: [map()]
  def review(ctx) do
    [scope: ctx.scope]
    |> Reviews.list_pending_reviews()
    |> Enum.filter(&Map.has_key?(ctx.boards, &1.column.board_id))
    |> Enum.map(&review_item(&1, ctx))
  end

  defp review_item(task, ctx) do
    board_id = task.column.board_id
    verdicts = MobileReview.verdicts(task)

    item(ctx, :review, "review:task:#{task.id}", %{
      since: Reviews.waiting_since(task),
      task: task,
      board_id: board_id,
      details: %{
        verdicts:
          for(v <- verdicts, v.section in @pill_sections, do: Map.take(v, [:section, :status])),
        first_failed_note: first_failed_note(verdicts)
      },
      actions: review_actions(task, ctx, board_id),
      path: task_path(board_id, task.id)
    })
  end

  defp first_failed_note(verdicts) do
    Enum.find_value(verdicts, fn
      %{status: "failed", note: note} when is_binary(note) and note != "" -> note
      _verdict -> nil
    end)
  end

  # Approval and change requests are refused for read-only members and
  # archived tasks by `Kanban.Reviews.DecisionChecks.decidable/4` (app) and
  # by the write check in `Reviews.commit_review!` (web), so only offer them
  # where both would pass.
  defp review_actions(%Task{archived_at: nil}, ctx, board_id) do
    if writable?(ctx, board_id),
      do: [:open_review, :approve, :request_changes, :open_on_web],
      else: [:open_on_web]
  end

  defp review_actions(_task, _ctx, _board_id), do: [:open_on_web]

  # -- released --------------------------------------------------------------

  @doc """
  The person's newest `task_unclaimed` notification per task, while it is
  unread and the task is still open in Ready.
  """
  @spec released(map()) :: [map()]
  def released(ctx) do
    ctx.notifications
    |> newest_per_task(:task_unclaimed)
    |> Enum.filter(&released?/1)
    |> Enum.map(&released_item(&1, ctx))
  end

  @doc """
  Whether one `task_unclaimed` or `claim_expired` notification is still an
  open decision, by the rules `released/1` and `claim_expired/1` apply,
  whatever its `in_app` flag. Expects `task: :column` preloaded; any other
  event type is `false`.

  `Kanban.Push.PushWorker` asks this for a decision missing from the
  person's list, which reads only in-app rows and stops at 100 items.
  """
  @spec notification_open?(Notification.t(), DateTime.t()) :: boolean()
  def notification_open?(%Notification{event_type: :task_unclaimed} = notification, _now),
    do: released?(notification)

  def notification_open?(%Notification{event_type: :claim_expired} = notification, now),
    do: still_expired?(notification, now)

  def notification_open?(%Notification{}, _now), do: false

  defp released?(%Notification{read_at: nil, task: %Task{status: :open, column: column}}),
    do: Columns.named?(column, "Ready")

  defp released?(_notification), do: false

  defp released_item(%Notification{task: task} = notification, ctx) do
    board_id = task.column.board_id

    item(ctx, :released, "released:task:#{task.id}", %{
      since: notification.inserted_at,
      task: task,
      board_id: board_id,
      details: %{reason: notification.body, notification_id: notification.id},
      actions: [:reply] ++ move_to_backlog(ctx, board_id) ++ [:open_on_web],
      path: task_path(board_id, task.id)
    })
  end

  # -- claim_expired ---------------------------------------------------------

  @doc """
  The person's newest `claim_expired` notification per task, while the task
  is still in progress in Doing with the claim the notification was about
  expired.
  """
  @spec claim_expired(map()) :: [map()]
  def claim_expired(ctx) do
    ctx.notifications
    |> newest_per_task(:claim_expired)
    |> Enum.filter(&still_expired?(&1, ctx.now))
    |> Enum.map(&claim_expired_item(&1, ctx))
  end

  defp still_expired?(%Notification{task: %Task{status: :in_progress} = task} = notification, now) do
    Columns.named?(task.column, "Doing") and before?(task.claim_expires_at, now) and
      current_claim?(notification, task)
  end

  defp still_expired?(_notification, _now), do: false

  # The expiry sweep notifies only once a claim has expired, so a notification
  # about the current claim was sent at or after its expiry. One sent earlier
  # is about a previous claim, even one that ended in the same second the
  # current claim began.
  defp current_claim?(%Notification{inserted_at: sent_at}, %Task{
         claim_expires_at: %DateTime{} = expires_at
       }),
       do: DateTime.compare(sent_at, expires_at) != :lt

  defp current_claim?(_notification, _task), do: false

  defp claim_expired_item(%Notification{task: task}, ctx) do
    board_id = task.column.board_id

    item(ctx, :claim_expired, "claim_expired:task:#{task.id}", %{
      since: task.claim_expires_at,
      task: task,
      board_id: board_id,
      details: %{claimed_at: task.claimed_at, expired_at: task.claim_expires_at},
      actions: move_to_backlog(ctx, board_id) ++ [:open_on_web],
      path: task_path(board_id, task.id)
    })
  end

  # -- hook_failed -----------------------------------------------------------

  @doc """
  Goals on the context's boards whose last `after_goal` attempt failed and
  that no later attempt has succeeded.
  """
  @spec hook_failed(map()) :: [map()]
  def hook_failed(ctx) do
    ctx.boards
    |> Map.keys()
    |> failed_goals()
    |> Enum.map(&hook_failed_item(&1, ctx))
  end

  defp failed_goals(board_ids) do
    from(t in Task,
      join: c in assoc(t, :column),
      where: c.board_id in ^board_ids,
      where: t.type == :goal and t.after_goal_status == :pending,
      where: not is_nil(t.after_goal_result) and is_nil(t.archived_at),
      preload: [column: c]
    )
    |> Repo.all()
    |> Enum.filter(&failed_result?(&1.after_goal_result))
  end

  # `Kanban.Tasks.report_after_goal/2` treats every attempt whose exit code
  # is not `0` as a failure, a missing or non-integer one included.
  defp failed_result?(%{"exit_code" => 0}), do: false
  defp failed_result?(result), do: is_map(result)

  defp hook_failed_item(goal, ctx) do
    board_id = goal.column.board_id
    result = goal.after_goal_result

    item(ctx, :hook_failed, "hook_failed:goal:#{goal.id}", %{
      since: reported_at(result) || to_utc(goal.updated_at),
      task: goal,
      board_id: board_id,
      details: %{
        exit_code: integer_or_nil(result["exit_code"]),
        duration_ms: integer_or_nil(result["duration_ms"])
      },
      actions: [:view_attempt, :open_on_web],
      path: "/boards/#{board_id}/goals/#{goal.id}"
    })
  end

  defp reported_at(%{"reported_at" => at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp reported_at(_result), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  # -- ready_empty -----------------------------------------------------------

  @doc """
  Boards the person can write to whose Ready column is empty while Backlog
  holds work, and on which an agent worked in the last 24 hours that is
  idle now. Runs one roster query for the person and one per such board,
  and none when no board qualifies.
  """
  @spec ready_empty(map()) :: [map()]
  def ready_empty(ctx) do
    case Enum.filter(ctx.columns, &empty_ready?(&1, ctx)) do
      [] -> []
      candidates -> ready_empty_items(candidates, ctx)
    end
  end

  defp empty_ready?({board_id, %{ready: 0, backlog: backlog}}, ctx)
       when is_integer(backlog) and backlog > 0,
       do: writable?(ctx, board_id)

  defp empty_ready?(_counts, _ctx), do: false

  defp ready_empty_items(candidates, ctx) do
    idle = idle_agent_keys(ctx.scope)
    cutoff = ctx.now |> DateTime.to_naive() |> NaiveDateTime.add(-@recent_agent_seconds)

    Enum.flat_map(candidates, fn {board_id, counts} ->
      ctx
      |> idle_recent_agents(board_id, idle, cutoff)
      |> ready_empty_item(board_id, counts, ctx)
    end)
  end

  # Agents that worked on this board since `cutoff` and are idle everywhere.
  defp idle_recent_agents(ctx, board_id, idle, cutoff) do
    [scope: ctx.scope, board_id: board_id]
    |> Agents.list_agents()
    |> Enum.filter(&(recent?(&1.last_active_at, cutoff) and MapSet.member?(idle, agent_key(&1))))
  end

  defp ready_empty_item([], _board_id, _counts, _ctx), do: []

  defp ready_empty_item(agents, board_id, counts, ctx) do
    last_active = agents |> Enum.map(& &1.last_active_at) |> Enum.max(NaiveDateTime)

    [
      %{
        id: "ready_empty:board:#{board_id}",
        kind: :ready_empty,
        since: to_utc(last_active),
        task_id: nil,
        board_id: board_id,
        summary: %{
          identifier: nil,
          title: nil,
          priority: nil,
          agent: nil,
          board: board(ctx, board_id)
        },
        details: %{idle_agents: length(agents), backlog_count: counts.backlog},
        actions: [:open_backlog, :open_on_web],
        web_url: url("/boards/#{board_id}")
      }
    ]
  end

  # An agent is idle now when it holds no task in Doing or Review on any
  # board the person can see, not only on this one. Boards the person cannot
  # see are never read, so work there does not count.
  defp idle_agent_keys(scope) do
    [scope: scope]
    |> Agents.list_agents()
    |> Enum.filter(&(&1.status == :idle))
    |> MapSet.new(&agent_key/1)
  end

  defp agent_key(agent), do: {agent.name, agent.owner_key}

  defp recent?(%NaiveDateTime{} = at, cutoff), do: NaiveDateTime.compare(at, cutoff) != :lt
  defp recent?(_at, _cutoff), do: false

  # One query: unarchived work and defect tasks in each Ready and Backlog
  # column, `nil` where a board has no such column.
  defp column_counts([]), do: %{}

  defp column_counts(board_ids) do
    from(c in Column,
      left_join: t in Task,
      on: t.column_id == c.id and is_nil(t.archived_at) and t.type in ^@agent_task_types,
      where: c.board_id in ^board_ids,
      group_by: [c.board_id, c.id, c.name, c.wip_limit],
      select: {c.board_id, c.name, c.wip_limit, count(t.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, &add_column_count/2)
  end

  defp add_column_count({board_id, name, wip_limit, count}, acc) do
    acc
    |> Map.put_new(board_id, %{ready: nil, backlog: nil, backlog_full: false})
    |> Map.update!(board_id, &add_to_counts(&1, column_key(name), wip_limit, count))
  end

  defp add_to_counts(counts, nil, _wip_limit, _count), do: counts

  defp add_to_counts(counts, :backlog, wip_limit, count) do
    %{
      counts
      | backlog: (counts.backlog || 0) + count,
        backlog_full: counts.backlog_full or at_wip_limit?(wip_limit, count)
    }
  end

  defp add_to_counts(counts, key, _wip_limit, count),
    do: Map.update!(counts, key, &((&1 || 0) + count))

  # The same rule `Kanban.Tasks.Positioning` refuses a move with.
  defp at_wip_limit?(wip_limit, count) when is_integer(wip_limit) and wip_limit > 0,
    do: count >= wip_limit

  defp at_wip_limit?(_wip_limit, _count), do: false

  defp column_key(name) do
    cond do
      Columns.named?(%{name: name}, "Ready") -> :ready
      Columns.named?(%{name: name}, "Backlog") -> :backlog
      true -> nil
    end
  end

  # -- shared ----------------------------------------------------------------

  defp item(ctx, kind, id, %{task: task, board_id: board_id} = fields) do
    %{
      id: id,
      kind: kind,
      since: fields.since,
      task_id: task.id,
      board_id: board_id,
      summary: %{
        identifier: task.identifier,
        title: task.title,
        priority: task.priority,
        agent: task.completed_by_agent || task.created_by_agent,
        board: board(ctx, board_id)
      },
      details: fields.details,
      actions: fields.actions,
      web_url: url(fields.path)
    }
  end

  defp board(ctx, board_id) do
    board = Map.fetch!(ctx.boards, board_id)
    %{id: board.id, name: board.name}
  end

  # Rows arrive newest first, so the first row per task is its newest.
  defp newest_per_task(notifications, event_type) do
    notifications
    |> Enum.filter(&(&1.event_type == event_type))
    |> Enum.uniq_by(& &1.task_id)
  end

  defp move_to_backlog(ctx, board_id) do
    if writable?(ctx, board_id) and backlog?(ctx, board_id), do: [:move_to_backlog], else: []
  end

  # A Backlog column exists and is below its WIP limit, so the move would
  # be accepted.
  defp backlog?(ctx, board_id) do
    case Map.get(ctx.columns, board_id) do
      %{backlog: count, backlog_full: false} when is_integer(count) -> true
      _counts -> false
    end
  end

  defp writable?(ctx, board_id), do: Map.get(ctx.access, board_id) in @write_access

  defp before?(%DateTime{} = at, now), do: DateTime.compare(at, now) == :lt
  defp before?(_at, _now), do: false

  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(_at), do: nil

  defp task_path(board_id, task_id), do: "/boards/#{board_id}/tasks/#{task_id}/edit"

  defp url(path), do: KanbanWeb.Endpoint.url() <> path
end
