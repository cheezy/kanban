defmodule Kanban.Hooks do
  @moduledoc """
  Context for providing hook metadata to agents.
  Fixed hooks: before_doing, after_doing, before_review, after_review

  The server does NOT execute hooks. Instead, it provides hook metadata
  (name, environment variables, timeout, blocking status) to the agent,
  which executes the hook locally by reading .stride.md from the project.
  """

  alias Kanban.Boards.Board
  alias Kanban.Hooks.Environment
  alias Kanban.Tasks.Task

  @hook_config %{
    "before_doing" => %{blocking: true, timeout: 60_000},
    "after_doing" => %{blocking: true, timeout: 120_000},
    "before_review" => %{blocking: true, timeout: 60_000},
    "after_review" => %{blocking: true, timeout: 60_000},
    "after_goal" => %{blocking: true, timeout: 60_000}
  }

  @doc """
  Get hook metadata for a task.
  Hook name must be one of: before_doing, after_doing, before_review, after_review

  Returns hook information that the agent can use to execute the hook locally.

  ## Examples

      iex> get_hook_info(task, board, "before_doing", "Claude Sonnet 4.5")
      {:ok, %{
        name: "before_doing",
        env: %{"TASK_ID" => "123", ...},
        timeout: 60_000,
        blocking: true
      }}

      iex> get_hook_info(task, board, "invalid_hook", "Claude")
      ** (ArgumentError) Invalid hook name: invalid_hook
  """
  def get_hook_info(%Task{} = task, %Board{} = board, hook_name, agent_name) do
    config = Map.get(@hook_config, hook_name)

    unless config do
      raise ArgumentError,
            "Invalid hook name: #{hook_name}. Must be one of: #{Map.keys(@hook_config) |> Enum.join(", ")}"
    end

    env = Environment.build(task, board, hook_name: hook_name, agent_name: agent_name)

    {:ok,
     %{
       name: hook_name,
       env: env,
       timeout: config.timeout,
       blocking: config.blocking,
       execute_before: execution_timing(hook_name, :before),
       execute_after: execution_timing(hook_name, :after),
       description: hook_description(hook_name)
     }}
  end

  defp hook_description("before_doing"),
    do: "Setup and preparation before starting work on the task"

  defp hook_description("after_doing"),
    do:
      "Quality checks and validation after completing work (tests, linting, formatting, security)"

  defp hook_description("before_review"),
    do: "Prepare task for review (create PR, generate documentation)"

  defp hook_description("after_review"),
    do: "Finalize task after approval (deploy, merge, notify stakeholders)"

  defp hook_description("after_goal"),
    do:
      "Finalize the parent goal after its final child task completes (project-level rollups, notifications, archival)"

  defp execution_timing("before_doing", :before), do: "Claiming the task"
  defp execution_timing("before_doing", :after), do: "Executing the before_doing hook"

  defp execution_timing("after_doing", :before),
    do: "Calling the /complete endpoint - EXECUTE THIS FIRST!"

  defp execution_timing("after_doing", :after), do: "Executing the after_doing hook successfully"

  defp execution_timing("before_review", :before),
    do: "Executing the after_doing hook successfully"

  defp execution_timing("before_review", :after), do: "Executing the before_review hook"

  defp execution_timing("after_review", :before),
    do:
      "AFTER calling /mark_reviewed endpoint with approved status (or immediately after executing before_review if needs_review=false)"

  defp execution_timing("after_review", :after), do: "Task marked as done"

  defp execution_timing("after_goal", :before),
    do:
      "Reporting after_goal exit code on the next /complete or /mark_reviewed call — only returned when this completion finished the parent goal's last open child"

  defp execution_timing("after_goal", :after), do: "Parent goal marked as done"

  @doc """
  List all available hooks and their configurations in execution order.
  Returns a list of {name, config} tuples in the order hooks would execute.

  `after_goal` is included at the end of the list — it runs only when the
  current completion finishes the parent goal's final open child, but it
  is part of the documented hook vocabulary regardless of whether any
  given task triggers it.
  """
  def list_hooks do
    # Return hooks in execution order:
    # before_doing → after_doing → before_review → after_review → after_goal
    [
      {"before_doing", @hook_config["before_doing"]},
      {"after_doing", @hook_config["after_doing"]},
      {"before_review", @hook_config["before_review"]},
      {"after_review", @hook_config["after_review"]},
      {"after_goal", @hook_config["after_goal"]}
    ]
  end
end
