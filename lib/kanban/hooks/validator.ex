defmodule Kanban.Hooks.Validator do
  @moduledoc """
  Validates hook execution results to ensure agents execute hooks before proceeding.

  This module enforces mandatory hook execution by validating that:
  1. Hook results are provided
  2. Hook results contain required fields (exit_code, output, duration_ms)
  3. Blocking hooks have exit_code 0 (success)
  """

  @doc """
  Validates that a hook was executed and completed successfully.

  ## Parameters

    * `result` - Map containing hook execution result with keys:
      * `exit_code` - Integer exit code from hook execution
      * `output` - String output from hook execution
      * `duration_ms` - Integer duration in milliseconds
    * `hook_name` - String name of the hook being validated
    * `opts` - Keyword list of options:
      * `:blocking` - Boolean, whether this is a blocking hook (default: false)

  ## Returns

    * `:ok` if validation passes
    * `{:error, reason}` if validation fails

  ## Examples

      iex> validate_hook_execution(%{"exit_code" => 0, "output" => "success", "duration_ms" => 100}, "before_doing", blocking: true)
      :ok

      iex> validate_hook_execution(nil, "before_doing", blocking: true)
      {:error, "before_doing hook result is required"}

      iex> validate_hook_execution(%{"exit_code" => 1, "output" => "failed", "duration_ms" => 100}, "after_doing", blocking: true)
      {:error, "after_doing is a blocking hook and failed with exit code 1"}
  """
  def validate_hook_execution(nil, hook_name, _opts) do
    {:error, "#{hook_name} hook result is required"}
  end

  def validate_hook_execution(result, hook_name, opts) when is_map(result) do
    blocking = Keyword.get(opts, :blocking, false)

    with :ok <- validate_has_required_fields(result, hook_name) do
      validate_exit_code(result, hook_name, blocking)
    end
  end

  def validate_hook_execution(_result, hook_name, _opts) do
    {:error, "#{hook_name} hook result must be a map"}
  end

  defp validate_has_required_fields(%{"exit_code" => _, "output" => _, "duration_ms" => _}, _hook_name) do
    :ok
  end

  defp validate_has_required_fields(_result, hook_name) do
    {:error, "#{hook_name} hook result must include exit_code, output, and duration_ms fields"}
  end

  defp validate_exit_code(%{"exit_code" => 0}, _hook_name, _blocking), do: :ok

  defp validate_exit_code(%{"exit_code" => code}, hook_name, true) do
    {:error, "#{hook_name} is a blocking hook and failed with exit code #{code}. Fix the issues and try again."}
  end

  defp validate_exit_code(_result, _hook_name, false), do: :ok
end
