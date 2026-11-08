defmodule Kanban.Hooks.Environment do
  @moduledoc """
  Builds environment variables for hook execution.
  """

  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @doc """
  Builds environment variables map for hook execution.

  Returns a map with string keys and string values for all task/board/agent context.

  ## Options

    * `:agent_name` - Name of the agent executing the hook
    * `:hook_name` - Name of the hook being executed

  ## Examples

      iex> build(task, board, agent_name: "Claude Sonnet 4.5", hook_name: "before_doing")
      %{
        "TASK_ID" => "123",
        "TASK_IDENTIFIER" => "W21",
        "TASK_TITLE" => "Implement hooks",
        ...
      }
  """
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def build(%Task{} = task, %Board{} = board, opts \\ []) do
    task = Repo.preload(task, :column)
    agent_name = Keyword.get(opts, :agent_name, "Unknown")
    hook_name = Keyword.get(opts, :hook_name, "unknown")

    context_vars = context_env_vars(task, board, agent_name, hook_name)

    task
    |> task_env_vars()
    |> Map.merge(context_vars)
  end

  @doc """
  Builds the `GOAL_*` environment variables for the `after_goal` hook.

  The four keys are the ones the Stride plugin's `export_after_goal_env`
  reads: `GOAL_ID`, `GOAL_IDENTIFIER`, `GOAL_TITLE` and `GOAL_DESCRIPTION`.
  Values are strings; a missing identifier, title or description is `""`.

  ## Examples

      iex> goal_env_vars(%Task{id: 7, identifier: "G7", title: "Ship it", description: nil})
      %{
        "GOAL_ID" => "7",
        "GOAL_IDENTIFIER" => "G7",
        "GOAL_TITLE" => "Ship it",
        "GOAL_DESCRIPTION" => ""
      }
  """
  @spec goal_env_vars(Task.t()) :: %{String.t() => String.t()}
  def goal_env_vars(%Task{} = goal) do
    %{
      "GOAL_ID" => to_string(goal.id),
      "GOAL_IDENTIFIER" => goal.identifier || "",
      "GOAL_TITLE" => goal.title || "",
      "GOAL_DESCRIPTION" => goal.description || ""
    }
  end

  defp task_env_vars(task) do
    %{
      "TASK_ID" => to_string(task.id),
      "TASK_IDENTIFIER" => task.identifier || "",
      "TASK_TITLE" => task.title || "",
      "TASK_DESCRIPTION" => task.description || "",
      "TASK_STATUS" => to_string(task.status || "open"),
      "TASK_COMPLEXITY" => to_string(task.complexity || "medium"),
      "TASK_PRIORITY" => to_string(task.priority || 0),
      "TASK_NEEDS_REVIEW" => to_string(task.needs_review || false)
    }
  end

  defp context_env_vars(task, board, agent_name, hook_name) do
    %{
      "BOARD_ID" => to_string(board.id),
      "BOARD_NAME" => board.name || "",
      "COLUMN_ID" => to_string(task.column.id),
      "COLUMN_NAME" => task.column.name || "",
      "AGENT_NAME" => agent_name,
      "HOOK_NAME" => hook_name
    }
  end
end
