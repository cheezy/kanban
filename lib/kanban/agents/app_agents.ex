defmodule Kanban.Agents.AppAgents do
  @moduledoc """
  The app's Agents tab (`GET /api/me/agents`, W2761,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.10, §7.10). Called as
  `Kanban.Agents.list_agents_for_app/2`.

  It returns two lists:

    * `agents` — the roster `/agents` shows by default: `Kanban.Agents.Roster`
      over the same task set (`Kanban.Agents.fetch_tasks/1`, the person's
      boards, every time range), less the tasks on boards the plan does not
      unlock (`Kanban.Plans.unlocked_board_ids/1`), as the app's other
      cross-board lists leave them out (design §7.10, "Plans on cross-board
      lists"). An agent that works on two boards is one agent, as on `/agents`;
    * `goals` — the open goals that have an agent on them now: the parents of
      the roster's unarchived tasks in Doing or Review, when the goal is
      neither archived nor completed and sits on one of those same boards.
      Newest first. An archived task left in Doing or Review does not keep
      its goal on the list.

  A goal's `counts` are its own tasks only. The goal tree counts
  (`Kanban.Tasks.Goals.get_task_tree/2`) include the goal itself
  (`total = 1 + children`), so they are not used. `total` and `completed`
  count the goal's tasks as the `/agents` goal rows do (D124): a live task
  counts, an archived completed task counts as done work, and an archived
  task that was not completed is removed work and counts in neither. `doing`,
  `review` and `blocked` count the live tasks in the Doing and Review
  columns, and with the blocked status. A goal with no tasks has every count
  at 0. The rule lives in `Kanban.Tasks.GoalCounts`, which the app's Goals
  list and Goal screen share. `hook_failed` is `Kanban.Tasks.AfterGoalAttempt.failed?/1`.

  Every query here is scoped to the boards the person can already see.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Agents
  alias Kanban.Agents.Agent
  alias Kanban.Plans
  alias Kanban.Repo
  alias Kanban.Tasks.AfterGoalAttempt
  alias Kanban.Tasks.GoalCounts
  alias Kanban.Tasks.Task

  @type goal_entry :: %{
          goal: Task.t(),
          board_id: integer(),
          counts: GoalCounts.counts(),
          hook_failed: boolean()
        }

  @type t :: %{agents: [Agent.t()], goals: [goal_entry()]}

  @doc """
  The person's agents and the open goals they work on, as `t:t/0`. Options:
  `:timezone` (default `"Etc/UTC"`), the zone the roster's "today" and "last
  7 days" counts are taken in, as `/agents` takes them in the viewer's.

  A scope with no user sees no agents: the task fetch is only ever made for a
  person.
  """
  @spec overview(Scope.t() | nil, keyword()) :: t()
  def overview(scope, opts \\ [])

  def overview(%Scope{user: %User{}} = scope, opts) do
    timezone = Keyword.get(opts, :timezone) || "Etc/UTC"
    tasks = [scope: scope, timezone: timezone] |> Agents.fetch_tasks() |> on_unlocked_boards()

    %{agents: Agents.list_agents_from(tasks, timezone), goals: goals(tasks)}
  end

  def overview(_scope, _opts), do: %{agents: [], goals: []}

  defp on_unlocked_boards([]), do: []

  defp on_unlocked_boards(tasks) do
    unlocked = tasks |> Enum.map(& &1.board_id) |> Enum.uniq() |> Plans.unlocked_board_ids()
    Enum.filter(tasks, &MapSet.member?(unlocked, &1.board_id))
  end

  defp goals(tasks) do
    case goal_ids(tasks) do
      [] -> []
      goal_ids -> goal_ids |> open_goals(board_ids(tasks)) |> with_counts()
    end
  end

  # The goals the roster's agents hold a live task under in Doing or Review.
  # An archived task left in either column is no agent on its goal now.
  defp goal_ids(tasks) do
    tasks
    |> Enum.filter(&(agent_task?(&1) and active?(&1) and live_child?(&1)))
    |> Enum.map(& &1.parent_id)
    |> Enum.uniq()
  end

  defp agent_task?(task), do: not is_nil(task.created_by_agent || task.completed_by_agent)

  defp active?(task), do: Agents.doing?(task) or Agents.in_review?(task)

  defp live_child?(task), do: is_nil(task.archived_at) and not is_nil(task.parent_id)

  defp board_ids(tasks), do: tasks |> Enum.map(& &1.board_id) |> Enum.uniq()

  # The goal must be on one of the boards the roster was read from, so a
  # parent on any other board never appears.
  defp open_goals(goal_ids, board_ids) do
    from(g in Task,
      join: c in assoc(g, :column),
      where: g.id in ^goal_ids and g.type == :goal,
      where: c.board_id in ^board_ids,
      where: is_nil(g.archived_at) and g.status != :completed,
      order_by: [desc: g.inserted_at, desc: g.id],
      preload: [column: c]
    )
    |> Repo.all()
  end

  defp with_counts([]), do: []

  defp with_counts(goals) do
    children = goals |> Enum.map(& &1.id) |> GoalCounts.children_by_goal()

    Enum.map(goals, fn goal ->
      %{
        goal: goal,
        board_id: goal.column.board_id,
        counts: GoalCounts.counts(Map.get(children, goal.id, [])),
        hook_failed: AfterGoalAttempt.failed?(goal)
      }
    end)
  end
end
