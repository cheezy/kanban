defmodule Kanban.Decisions.Sources do
  @moduledoc """
  The five decision sources behind `Kanban.Decisions.build/1`, one function
  per kind, and the shared context they read.

  `context/3` loads what more than one source needs once: the boards the
  person can see (already narrowed to the plan), their access to each, the
  person's `task_unclaimed` and `claim_expired` notifications, and the
  Ready and Backlog task counts per board (`Kanban.Decisions.ColumnCounts`).
  Each source then returns plain item maps in the shape `Kanban.Decisions`
  documents.

  Actions follow the same write checks the web applies: approving, asking
  for changes and moving a task need owner or modify access; replying needs
  only membership, as `Kanban.Tasks.CommentPolicy` allows any member to
  comment. Approving also follows the app's large-change guard: a phone is
  not offered `:approve` on a change `Kanban.Reviews.MobileGuard` refuses for
  a phone, the rule the review detail's `approvable_here` and the approve
  route apply. A tablet and the web keep it.

  A task item's `:web_url` is the task's edit page for a person who can write
  to the board, and the board itself for a read-only member, because the edit
  page refuses them and sends them to the board.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Agents
  alias Kanban.Columns
  alias Kanban.Decisions.ColumnCounts
  alias Kanban.Notifications
  alias Kanban.Notifications.Notification
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Reviews.MobileGuard
  alias Kanban.Reviews.MobileReview
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskClaim

  @write_access [:owner, :modify]
  @pill_sections [:acceptance_criteria, :testing_strategy, :patterns, :security_considerations]
  @notification_types [:task_unclaimed, :claim_expired]
  @recent_agent_seconds 24 * 60 * 60

  @doc """
  Builds the context every source reads, for `boards`: the boards the
  scoped `user` can access that the plan unlocks, each with its virtual
  `:user_access` set. `device_class` is the class of the device asking,
  `:phone` or `:tablet`, or `nil` for the web.
  """
  @spec context(
          Scope.t(),
          Kanban.Accounts.User.t(),
          [Kanban.Boards.Board.t()],
          MobileGuard.device_class()
        ) :: map()
  def context(%Scope{} = scope, user, boards, device_class \\ nil) do
    board_ids = Enum.map(boards, & &1.id)

    boards
    |> board_maps()
    |> Map.merge(%{
      scope: scope,
      user: user,
      device_class: device_class,
      now: DateTime.utc_now(),
      notifications: open_task_notifications(scope, board_ids),
      columns: ColumnCounts.by_board(board_ids)
    })
  end

  defp board_maps(boards) do
    %{
      boards: Map.new(boards, &{&1.id, &1}),
      access: Map.new(boards, &{&1.id, &1.user_access})
    }
  end

  defp open_task_notifications(scope, board_ids) do
    Notifications.list_task_notifications(scope, @notification_types, board_ids,
      task_statuses: [:open, :in_progress]
    )
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
      path: task_path(ctx, board_id, task.id)
    })
  end

  defp first_failed_note(verdicts) do
    Enum.find_value(verdicts, fn
      %{status: "failed", note: note} when is_binary(note) and note != "" -> note
      _verdict -> nil
    end)
  end

  # Approval and change requests are refused for read-only members by
  # `Kanban.Reviews.DecisionChecks.decidable/4` (app) and by the write check
  # in `Kanban.Reviews.ReviewCommit` (web), so only offer them where both
  # would pass. Archived tasks never reach here: the pending-review query
  # leaves them out. Approval is also refused on a phone for a change
  # `MobileGuard` finds too large; asking for changes never is.
  defp review_actions(task, ctx, board_id) do
    if writable?(ctx, board_id),
      do: [:open_review] ++ approve(task, ctx) ++ [:request_changes, :open_on_web],
      else: [:open_on_web]
  end

  defp approve(task, ctx) do
    case MobileGuard.check(task, ctx.device_class) do
      :ok -> [:approve]
      {:error, :too_large_for_phone} -> []
    end
  end

  # -- released --------------------------------------------------------------

  @doc """
  The person's newest `task_unclaimed` notification per task, while it is
  unread, the task is still open in Ready, and the task has not been claimed
  since the notification was sent (`Kanban.Tasks.TaskClaim`): any later
  claim resolves the release, even one that ended without a release of its
  own, such as a claim that expired before the task went back to Ready.
  One claim-history query for the candidates; none when there are none.
  """
  @spec released(map()) :: [map()]
  def released(ctx) do
    ctx.notifications
    |> newest_per_task(:task_unclaimed)
    |> Enum.filter(&released?/1)
    |> reject_claimed_since()
    |> Enum.map(&released_item(&1, ctx))
  end

  defp reject_claimed_since([]), do: []

  defp reject_claimed_since(notifications) do
    latest = notifications |> Enum.map(& &1.task_id) |> TaskClaim.latest_claims()

    Enum.reject(notifications, fn n ->
      claimed_at = Map.get(latest, n.task_id)
      claimed_at != nil and DateTime.after?(claimed_at, n.inserted_at)
    end)
  end

  @doc """
  Whether one `task_unclaimed` or `claim_expired` notification is still an
  open decision, by the rules `released/1` and `claim_expired/1` apply,
  whatever its `in_app` flag: it is the person's newest notification of its
  event type for the task (those sources keep only the newest per task), the
  task is unarchived, and the kind's own rule holds. Expects `task: :column`
  preloaded; any other event type is `false`.

  A row is compared with every newer row the person has for that task and
  event type, hidden or not, so a late or retried push for a release that a
  newer notification replaced is not open, as the list would not show it.

  A `task_unclaimed` row is also closed by any claim of its task after it
  was sent, as `released/1` decides.

  `Kanban.Push.PushWorker` asks this for a decision missing from the
  person's list, which reads only in-app rows on unarchived tasks and stops
  at 100 items.
  """
  @spec notification_open?(Notification.t(), DateTime.t()) :: boolean()
  def notification_open?(%Notification{event_type: :task_unclaimed} = notification, _now) do
    released?(notification) and newest?(notification) and
      not TaskClaim.claimed_after?(notification.task_id, notification.inserted_at)
  end

  def notification_open?(%Notification{event_type: :claim_expired} = notification, now),
    do: still_expired?(notification, now) and newest?(notification)

  def notification_open?(%Notification{}, _now), do: false

  # The order `newest_per_task/2` reads rows in: newest `inserted_at`, then
  # highest id.
  defp newest?(%Notification{} = n) do
    newer =
      from(o in Notification,
        where: o.user_id == ^n.user_id and o.task_id == ^n.task_id,
        where: o.event_type == ^n.event_type,
        where:
          o.inserted_at > ^n.inserted_at or (o.inserted_at == ^n.inserted_at and o.id > ^n.id)
      )

    not Repo.exists?(newer)
  end

  defp released?(%Notification{
         read_at: nil,
         task: %Task{status: :open, archived_at: nil, column: column}
       }),
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
      path: task_path(ctx, board_id, task.id)
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

  defp still_expired?(
         %Notification{task: %Task{status: :in_progress, archived_at: nil} = task} = notification,
         now
       ) do
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
      path: task_path(ctx, board_id, task.id)
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

  # The edit page refuses a member without write access and sends them to
  # the board, so a read-only member's link is the board itself.
  defp task_path(ctx, board_id, task_id) do
    if writable?(ctx, board_id),
      do: "/boards/#{board_id}/tasks/#{task_id}/edit",
      else: "/boards/#{board_id}"
  end

  defp url(path), do: KanbanWeb.Endpoint.url() <> path
end
