defmodule Kanban.Decisions.DecisionAction do
  @moduledoc """
  A decision a person has first acted on: the decision's id
  (`"review:task:12"`, `"ready_empty:board:3"`), the moment it started
  waiting, and its board and task.

  `Kanban.Decisions.ActedOn` is the only writer. It inserts with
  `on_conflict: :nothing` on the unique `(decision_key, since)` index, so of
  any number of actions on one decision only the first records a row, and
  only that action is counted. Rows carry no user and are deleted with their
  board or task.
  """

  use Ecto.Schema

  schema "decision_actions" do
    field :decision_key, :string
    field :since, :utc_datetime_usec

    belongs_to :board, Kanban.Boards.Board
    belongs_to :task, Kanban.Tasks.Task

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
