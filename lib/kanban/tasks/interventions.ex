defmodule Kanban.Tasks.Interventions do
  @moduledoc """
  Authorization for in-page interventions on a goal.

  An intervention mutates a goal (and, in later work, its children) directly
  from the /agents page. The actor set the requirements name is "the goal's
  delivery-target owner OR the goal's board owner", and the scoped user must
  ALSO pass the same board-access guard the /agents reads use — belonging to
  the goal's board. `can_intervene?/2` is the single gate both the context
  write ops and the LiveView action guard call before mutating anything, so
  the two paths cannot drift apart.

  Ownership is delegated to the existing predicates rather than reimplemented:
  `Kanban.Targets.owner?/2` and `Kanban.Boards.owner?/2`. Board accessibility
  reuses `Kanban.Queries.BoardScope`. The predicate fails closed — a `nil`
  scope, a scope without a user, or a goal on an inaccessible board all return
  `false`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Targets
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks.Task

  @doc """
  Returns `true` when the scoped user may run an in-page intervention on `goal`.

  The user must be the owner of the goal's delivery target OR the owner of the
  goal's board, AND the goal must be on a board the scoped user can access.
  Returns `false` for a `nil` scope, a scope whose user is `nil`, a non-owner,
  or a goal on a board the user cannot access.
  """
  @spec can_intervene?(Scope.t() | nil, Task.t()) :: boolean()
  def can_intervene?(nil, _goal), do: false
  def can_intervene?(%Scope{user: nil}, _goal), do: false

  def can_intervene?(%Scope{user: user} = scope, %Task{} = goal) do
    goal = Repo.preload(goal, [:target, column: :board])

    owner?(goal, user) and accessible?(scope, goal)
  end

  defp owner?(%Task{target: %DeliveryTarget{} = target} = goal, user) do
    Targets.owner?(target, user) or Boards.owner?(goal.column.board, user)
  end

  defp owner?(%Task{} = goal, user) do
    Boards.owner?(goal.column.board, user)
  end

  defp accessible?(scope, %Task{} = goal) do
    Task
    |> where(id: ^goal.id)
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> Repo.exists?()
  end
end
