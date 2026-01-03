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
    "before_review" => %{blocking: false, timeout: 60_000},
    "after_review" => %{blocking: false, timeout: 60_000}
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

  @doc """
  List all available hooks and their configurations in execution order.
  Returns a list of {name, config} tuples in the order hooks would execute.
  """
  def list_hooks do
    # Return hooks in execution order: before_doing, after_doing, before_review, after_review
    [
      {"before_doing", @hook_config["before_doing"]},
      {"after_doing", @hook_config["after_doing"]},
      {"before_review", @hook_config["before_review"]},
      {"after_review", @hook_config["after_review"]}
    ]
  end
end
