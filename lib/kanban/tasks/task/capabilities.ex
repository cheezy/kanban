defmodule Kanban.Tasks.Task.Capabilities do
  @moduledoc """
  The capability vocabulary for the `required_capabilities` field on
  `Kanban.Tasks.Task` and the changeset validation that enforces it.

  Split from `Kanban.Tasks.Task` to keep the schema module under the project's
  module-size guideline. `Kanban.Tasks.Task.valid_capabilities/0` delegates to
  `valid_capabilities/0` here, and the task changesets run
  `validate_required_capabilities/1` as a pipeline stage. The error strings are
  shown to API clients, so they must not drift. Changeset-in / changeset-out.
  """

  import Ecto.Changeset

  @doc """
  Valid capability strings for the `required_capabilities` field.

  Capabilities determine which agents can claim tasks. An agent must have ALL
  required capabilities to see and claim a task.

  ## Available Capabilities

  - `api_design` - REST/GraphQL API design
  - `code_generation` - Writing new code
  - `code_review` - Reviewing code changes
  - `database_design` - Database schema design and migrations
  - `debugging` - Finding and fixing bugs
  - `devops` - CI/CD, Docker, deployment pipelines
  - `documentation` - Writing docs, comments, guides
  - `file_operations` - File processing, data import/export
  - `git` - Branch management, commit workflows, git automation
  - `performance_optimization` - Performance tuning and optimization
  - `refactoring` - Improving code structure
  - `security_analysis` - Security audits and vulnerability fixes
  - `testing` - Writing and running tests
  - `ui_design` - UI/UX design, wireframes, design systems
  - `ui_implementation` - User interface implementation
  - `web_browsing` - Web scraping, browser automation, web testing

  ## Examples

      # Single capability
      required_capabilities: ["code_generation"]

      # Multiple capabilities
      required_capabilities: ["code_generation", "testing", "security_analysis"]

      # No requirements (any agent can claim)
      required_capabilities: []
  """
  @valid_capabilities [
    "api_design",
    "code_generation",
    "code_review",
    "database_design",
    "debugging",
    "devops",
    "documentation",
    "file_operations",
    "git",
    "performance_optimization",
    "refactoring",
    "security_analysis",
    "testing",
    "ui_design",
    "ui_implementation",
    "web_browsing"
  ]

  def valid_capabilities, do: @valid_capabilities

  @doc """
  Validates `required_capabilities` is nil, empty, or a list of strings drawn
  from `valid_capabilities/0`, naming any invalid entries in the error.
  """
  def validate_required_capabilities(changeset) do
    case get_field(changeset, :required_capabilities) do
      nil ->
        changeset

      [] ->
        changeset

      caps when is_list(caps) ->
        validate_capability_list(changeset, caps)

      _ ->
        add_error(changeset, :required_capabilities, "must be a list")
    end
  end

  defp validate_capability_list(changeset, caps) do
    if Enum.all?(caps, &is_binary/1) do
      invalid_caps = Enum.reject(caps, &(&1 in @valid_capabilities))
      add_capability_errors(changeset, invalid_caps)
    else
      add_error(changeset, :required_capabilities, "must be a list of strings")
    end
  end

  defp add_capability_errors(changeset, []), do: changeset

  defp add_capability_errors(changeset, [single]) do
    add_error(
      changeset,
      :required_capabilities,
      "invalid capability: '#{single}'. Must be one of: #{Enum.join(@valid_capabilities, ", ")}"
    )
  end

  defp add_capability_errors(changeset, multiple) do
    add_error(
      changeset,
      :required_capabilities,
      "invalid capabilities: #{Enum.join(multiple, ", ")}. Must be one of: #{Enum.join(@valid_capabilities, ", ")}"
    )
  end
end
