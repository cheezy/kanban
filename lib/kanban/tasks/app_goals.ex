defmodule Kanban.Tasks.AppGoals do
  @moduledoc """
  The app's Goals list and Goal screen (W2762,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.18, §6.19, §7.10),
  called as `Kanban.Tasks.Goals.list_goals_for_app/2`,
  `Kanban.Tasks.Goals.get_goal_detail_for_app/3` and
  `Kanban.Tasks.Goals.parse_goal_filter/1`.

  ## The list

  Every goal on every board the person can see, across all their workspaces
  (`Kanban.Workspaces.Policy.accessible_board_ids/1`, the boundary
  `Kanban.Queries.BoardScope` applies), less the boards the plan does not
  unlock (`Kanban.Plans.unlocked_board_ids/1`), as the app's other
  cross-board lists leave them out (design §7.10, "Plans on cross-board
  lists"). The board list is never taken from the caller. Archived goals are
  left out: they stay on the web, as archived tasks do. Newest first, 100 per
  page. The filters:

    * `:open` (the default): goals that are not completed;
    * `:done`: completed goals;
    * `:no_target`: open goals with no target, or whose target is archived.

  The page carries the count of every filter, so each filter can show its
  count (§6.19).

  ## A goal row

  Its board (id and name), its target (`nil` when it has none, or it is
  archived), its counts (`Kanban.Tasks.GoalCounts.counts/1`: the target's
  rule, D124, never counting the goal itself, as the app's Agents goal rows
  count), `waiting_on_you` (`Kanban.Tasks.GoalCounts.waiting_on_you/1`: its
  pending reviews) and `hook_failed` (`Kanban.Tasks.AfterGoalAttempt.failed?/1`,
  as the Agents rows and `GET /api/me/goals/:id/after_goal` read it).

  ## The detail

  The goal's row, the agents who worked on it, `archived_done` (its archived
  completed tasks, for the "N archived" line) and its live tasks grouped by
  column in the web's order: Backlog, Ready, Doing, Review and Done. The
  tasks are `Kanban.Tasks.list_children_for_goal/2`'s, as the web goal page
  lists them, so archived tasks are left out; the header counts include them
  by D124, so "4/9" matches the goal's row on its target. A task in a column
  with any other name goes to Backlog, as on the web.

  Each task carries the agent on it (`completed_by_agent`, else
  `created_by_agent`), `reviewable` (a pending review the person may decide,
  so the app opens the review rather than the task) and `in_column_since`:
  when it entered its column. Every move writes a `:move` row in
  `task_history`: a move on the web, a promote, a move to Backlog, and every
  agent-workflow move (`Kanban.Tasks.History.record_move/3`: a claim, an
  unclaim, a claim release, a completion, an auto-move to Done and a review).
  So when the task's latest move row moved it into the column it is in now
  (its name matched as `Kanban.Columns.named?/2` matches one), that row's
  time is the answer, and no stamp is read: a stamp can outlive the move
  that wrote it, as a return to Doing keeps the first claim's `claimed_at`.
  Otherwise (a task the agent workflow moved before it recorded its moves,
  or a column renamed since the row) it is the later of that row and the
  stamp the agent workflow writes, read only for the column the task is in
  now: `claimed_at` in Doing, `review_requested_at` in Review and
  `completed_at` in Done. A task with neither uses its insert time.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Columns
  alias Kanban.Plans
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks.AfterGoalAttempt
  alias Kanban.Tasks.GoalCounts
  alias Kanban.Tasks.History
  alias Kanban.Tasks.Queries
  alias Kanban.Tasks.Task
  alias Kanban.Workspaces.Policy

  @filters %{"open" => :open, "done" => :done, "no_target" => :no_target}
  @per_page 100
  @groups [
    {:backlog, "Backlog"},
    {:ready, "Ready"},
    {:doing, "Doing"},
    {:review, "Review"},
    {:done, "Done"}
  ]

  @entry_stamps [
    {"Doing", :claimed_at},
    {"Review", :review_requested_at},
    {"Done", :completed_at}
  ]

  @type filter :: :open | :done | :no_target

  @type entry :: %{
          goal: Task.t(),
          board: %{id: integer(), name: String.t()},
          target: DeliveryTarget.t() | nil,
          counts: GoalCounts.counts(),
          waiting_on_you: non_neg_integer(),
          hook_failed: boolean()
        }

  @type page :: %{
          goals: [entry()],
          filter: filter(),
          filters: %{
            open: non_neg_integer(),
            done: non_neg_integer(),
            no_target: non_neg_integer()
          },
          page: pos_integer(),
          per_page: pos_integer(),
          total: non_neg_integer(),
          next_page: pos_integer() | nil
        }

  @type task_entry :: %{
          task: Task.t(),
          agent: String.t() | nil,
          reviewable: boolean(),
          in_column_since: DateTime.t()
        }

  @type detail :: %{
          goal: entry(),
          agents: [String.t()],
          archived_done: non_neg_integer(),
          groups: [%{status: :backlog | :ready | :doing | :review | :done, tasks: [task_entry()]}]
        }

  @doc "The goals list's page size."
  @spec per_page() :: pos_integer()
  def per_page, do: @per_page

  @doc """
  Reads the `filter` param: `nil` is `:open`; `"open"`, `"done"` and
  `"no_target"` are their filter. Anything else is `{:error, changeset}`
  with "is invalid" on `filter`.
  """
  @spec parse_filter(term()) :: {:ok, filter()} | {:error, Ecto.Changeset.t()}
  def parse_filter(nil), do: {:ok, :open}

  def parse_filter(value) when is_binary(value) and is_map_key(@filters, value),
    do: {:ok, Map.fetch!(@filters, value)}

  def parse_filter(_value) do
    {:error,
     {%{}, %{filter: :string}}
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(:filter, "is invalid", validation: :inclusion)}
  end

  @doc """
  One page of the person's goals, as `t:page/0`. Options: `:filter` (default
  `:open`) and `:page` (default 1). A scope with no user lists nothing.
  """
  @spec list(Scope.t() | nil, keyword()) :: page()
  def list(scope, opts \\ [])

  def list(%Scope{user: %User{} = user} = scope, opts) do
    filter = Keyword.get(opts, :filter, :open)
    page = Keyword.get(opts, :page, 1)

    case unlocked_board_ids(user) do
      [] -> empty_page(filter, page)
      board_ids -> build_page(scope, board_ids, filter, page)
    end
  end

  def list(_scope, opts),
    do: empty_page(Keyword.get(opts, :filter, :open), Keyword.get(opts, :page, 1))

  @doc """
  The Goal screen for `goal`, which the caller found on `board` through
  `Kanban.Tasks.get_goal_for_app/2`, as `t:detail/0`.
  """
  @spec detail(Scope.t(), Task.t(), Board.t()) :: detail()
  def detail(%Scope{user: user} = scope, %Task{type: :goal} = goal, %Board{} = board) do
    goal = Repo.preload(goal, [:target, :column])
    all = [goal.id] |> GoalCounts.children_by_goal() |> Map.get(goal.id, [])
    children = Queries.list_children_for_goal(user, goal.id)

    %{
      goal: entry(goal, board, all),
      agents: agents([goal | children]),
      archived_done: GoalCounts.archived_done(all),
      groups: children |> task_entries(Reviews.can_review?(scope, goal)) |> group()
    }
  end

  @doc """
  Goal rows, as `t:entry/0`, for goals the caller already read through a
  board-scoped path (the app's Target screen reads its member goals from
  `Kanban.Targets.get_target_progress/3`). It keeps their order and reads
  their counts in one query; no goals is no rows.
  """
  @spec rows([Task.t()]) :: [entry()]
  def rows([]), do: []

  def rows(goals) when is_list(goals) do
    goals = Repo.preload(goals, [:target, column: :board])
    children = goals |> Enum.map(& &1.id) |> GoalCounts.children_by_goal()
    Enum.map(goals, &entry(&1, &1.column.board, Map.get(children, &1.id, [])))
  end

  defp task_entries(children, can_review) do
    moves = children |> Enum.map(& &1.id) |> History.latest_move_by_task()
    Enum.map(children, &task_entry(&1, moves, can_review))
  end

  defp unlocked_board_ids(%User{id: user_id}) do
    from(a in subquery(Policy.accessible_board_ids(user_id)), select: a.board_id)
    |> Repo.all()
    |> Plans.unlocked_board_ids()
    |> MapSet.to_list()
  end

  defp build_page(scope, board_ids, filter, page) do
    base = base_query(scope, board_ids)
    filters = filter_counts(base)
    total = Map.fetch!(filters, filter)

    %{
      goals: page_entries(base, filter, page),
      filter: filter,
      filters: filters,
      page: page,
      per_page: @per_page,
      total: total,
      next_page: next_page(page, total)
    }
  end

  defp page_entries(base, filter, page) do
    goals = page_goals(base, filter, page)
    children = goals |> Enum.map(& &1.id) |> GoalCounts.children_by_goal()
    Enum.map(goals, &entry(&1, &1.column.board, Map.get(children, &1.id, [])))
  end

  defp page_goals(base, filter, page) do
    base
    |> where(^filter_where(filter))
    |> order_by([g], desc: g.inserted_at, desc: g.id)
    |> limit(@per_page)
    |> offset(^((page - 1) * @per_page))
    |> preload([column: c, target: t], column: {c, :board}, target: t)
    |> Repo.all()
  end

  defp next_page(page, total) when page * @per_page < total, do: page + 1
  defp next_page(_page, _total), do: nil

  defp empty_page(filter, page) do
    %{
      goals: [],
      filter: filter,
      filters: %{open: 0, done: 0, no_target: 0},
      page: page,
      per_page: @per_page,
      total: 0,
      next_page: nil
    }
  end

  defp base_query(scope, board_ids) do
    from(g in Task,
      join: c in assoc(g, :column),
      as: :column,
      left_join: t in assoc(g, :target),
      as: :target,
      where: g.type == :goal and is_nil(g.archived_at) and c.board_id in ^board_ids
    )
    |> BoardScope.apply_board_scope(scope)
  end

  # The three counts and filter_where/1 state the same predicates; the
  # goals_test "lists goals across workspaces, newest first, with filters"
  # checks every filter's count equals its total, which keeps them agreeing.
  defp filter_counts(base) do
    base
    |> select([g, target: t], %{
      open: filter(count(g.id), g.status != :completed),
      done: filter(count(g.id), g.status == :completed),
      no_target:
        filter(
          count(g.id),
          g.status != :completed and (is_nil(g.target_id) or not is_nil(t.archived_at))
        )
    })
    |> Repo.one()
  end

  defp filter_where(:open), do: dynamic([g], g.status != :completed)
  defp filter_where(:done), do: dynamic([g], g.status == :completed)

  defp filter_where(:no_target) do
    dynamic(
      [g, target: t],
      g.status != :completed and (is_nil(g.target_id) or not is_nil(t.archived_at))
    )
  end

  defp entry(%Task{} = goal, board, children) do
    %{
      goal: goal,
      board: %{id: board.id, name: board.name},
      target: live_target(goal.target),
      counts: GoalCounts.counts(children),
      waiting_on_you: GoalCounts.waiting_on_you(children),
      hook_failed: AfterGoalAttempt.failed?(goal)
    }
  end

  defp live_target(%DeliveryTarget{archived_at: nil} = target), do: target
  defp live_target(_target), do: nil

  defp task_entry(%Task{} = task, moves, can_review) do
    %{
      task: task,
      agent: task.completed_by_agent || task.created_by_agent,
      reviewable: can_review and Reviews.pending_review?(task),
      in_column_since: in_column_since(task, moves)
    }
  end

  # The latest move row into the task's current column is when it entered
  # it. Without one (an agent move made before the workflow recorded its
  # moves, or a renamed column), the stamp the agent workflow writes for the
  # current column counts too, and the later of the two wins.
  defp in_column_since(%Task{} = task, moves), do: since(task, Map.get(moves, task.id))

  defp since(%Task{column: column} = task, %{at: at, to_column: to_column}) do
    if Columns.named?(column, to_column),
      do: utc(at),
      else: latest([at, entry_stamp(task)], task)
  end

  defp since(%Task{} = task, nil), do: latest([entry_stamp(task)], task)

  defp latest(times, %Task{} = task) do
    times
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&utc/1)
    |> Enum.max(DateTime, fn -> utc(task.inserted_at) end)
  end

  defp entry_stamp(%Task{column: column} = task) do
    Enum.find_value(@entry_stamps, fn {name, field} ->
      if Columns.named?(column, name), do: Map.get(task, field)
    end)
  end

  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp utc(%DateTime{} = at), do: at

  defp group(tasks) do
    by_group = Enum.group_by(tasks, &group_for(&1.task))

    Enum.map(@groups, fn {status, _name} ->
      %{status: status, tasks: Map.get(by_group, status, [])}
    end)
  end

  defp group_for(%Task{column: column}) do
    Enum.find_value(@groups, :backlog, fn {status, name} ->
      if Columns.named?(column, name), do: status
    end)
  end

  defp agents(tasks) do
    tasks
    |> Enum.flat_map(&[&1.created_by_agent, &1.completed_by_agent])
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> Enum.uniq()
  end
end
