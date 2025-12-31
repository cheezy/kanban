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

    {:ok, %{
      name: hook_name,
      env: env,
      timeout: config.timeout,
      blocking: config.blocking
    }}
  end

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
