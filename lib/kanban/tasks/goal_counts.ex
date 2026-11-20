defmodule Kanban.Tasks.GoalCounts do
  @moduledoc """
  A goal's task counts, as the app's goal rows show them (W2761, W2762,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.10, §6.18, §6.19).

  One home for the counting rule, so the app's Agents goal rows
  (`Kanban.Agents.AppAgents`), its Goals list and Goal screen
  (`Kanban.Tasks.AppGoals`) and target progress (`Kanban.Targets.Progress`)
  cannot drift apart:

    * the goal itself is never counted. The goal tree counts
      (`Kanban.Tasks.Goals.get_task_tree/2`) include it (`total = 1 +
      children`), so they are not used;
    * `total` and `completed` follow D124 (`credited?/1`): a live task counts,
      an archived completed task counts as done work, and an archived task
      that was not completed is removed work and counts in neither;
    * `doing`, `review` and `blocked` count the live tasks in the Doing and
      Review columns, and with the blocked status.

  A goal with no tasks has every count at 0.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Tasks.Task

  @type child :: %{
          required(:parent_id) => integer(),
          required(:status) => atom(),
          required(:archived_at) => term(),
          required(:needs_review) => boolean() | nil,
          required(:review_status) => atom() | nil,
          required(:column) => %{name: String.t()},
          optional(atom()) => term()
        }

  @type counts :: %{
          total: non_neg_integer(),
          completed: non_neg_integer(),
          doing: non_neg_integer(),
          review: non_neg_integer(),
          blocked: non_neg_integer()
        }

  @doc """
  Whether a child counts toward its goal's `total` and `completed` (D124): a
  live child always does, an archived child only when it was completed.
  """
  @spec credited?(%{archived_at: term(), status: atom()}) :: boolean()
  def credited?(%{archived_at: nil}), do: true
  def credited?(%{status: status}), do: status == :completed

  @doc """
  Every task of the goals in `goal_ids`, archived ones included, grouped by
  goal id, in one query. A task counts only when it sits on its goal's own
  board, so a parent link that crosses boards never counts another board's
  task. A goal with no tasks has no key. `[]` makes no query.
  """
  @spec children_by_goal([integer()]) :: %{integer() => [child()]}
  def children_by_goal([]), do: %{}

  def children_by_goal(goal_ids) when is_list(goal_ids) do
    from(t in Task,
      join: c in assoc(t, :column),
      join: g in Task,
      on: g.id == t.parent_id,
      join: gc in assoc(g, :column),
      where: t.parent_id in ^goal_ids and c.board_id == gc.board_id,
      select: %{
        parent_id: t.parent_id,
        status: t.status,
        archived_at: t.archived_at,
        needs_review: t.needs_review,
        review_status: t.review_status,
        column: %{name: c.name}
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.parent_id)
  end

  @doc "The goal's counts, as `t:counts/0`, from all of its children."
  @spec counts([child()]) :: counts()
  def counts(children) when is_list(children) do
    credited = Enum.filter(children, &credited?/1)
    live = Enum.filter(children, &is_nil(&1.archived_at))

    %{
      total: length(credited),
      completed: with_status(credited, :completed),
      doing: in_column(live, "Doing"),
      review: in_column(live, "Review"),
      blocked: with_status(live, :blocked)
    }
  end

  defp with_status(children, status), do: Enum.count(children, &(&1.status == status))

  defp in_column(children, name), do: Enum.count(children, &Columns.named?(&1.column, name))

  @doc """
  The number of the goal's tasks waiting on a person: its pending reviews,
  by `Kanban.Reviews.pending_review?/1`.
  """
  @spec waiting_on_you([child()]) :: non_neg_integer()
  def waiting_on_you(children) when is_list(children),
    do: Enum.count(children, &Reviews.pending_review?/1)

  @doc "The number of the goal's archived tasks that were completed."
  @spec archived_done([child()]) :: non_neg_integer()
  def archived_done(children) when is_list(children),
    do: Enum.count(children, &(not is_nil(&1.archived_at) and &1.status == :completed))
end
