defmodule Kanban.Tasks.Task.FieldValidations do
  @moduledoc """
  Field normalisation and the single-field / cross-field changeset checks for
  `Kanban.Tasks.Task`: AI-context defaults, `technology_requirements`,
  `dependencies`, claim expiry, completion, review metadata, and the
  goal-only delivery target.

  Split from `Kanban.Tasks.Task` to keep the schema module under the project's
  module-size guideline. Each function is a changeset-in / changeset-out
  pipeline stage run by the task changesets in
  `Kanban.Tasks.Task.Changesets`. The error strings are asserted verbatim by
  the schema tests and shown to API clients, so they must not drift.
  """

  import Ecto.Changeset

  alias Kanban.Tasks.Task.MapFieldValidations

  @doc """
  Puts the empty default (`[]` or `%{}`) on the AI-context fields
  (`security_considerations`, `testing_strategy`, `integration_points`,
  `technical_details`) when neither the change nor the stored value is set.
  """
  def normalize_ai_context_fields(changeset) do
    changeset
    |> normalize_field(:security_considerations, [])
    |> normalize_field(:testing_strategy, %{})
    |> normalize_field(:integration_points, %{})
    |> normalize_field(:technical_details, %{})
  end

  defp normalize_field(changeset, field, default) do
    case get_change(changeset, field) do
      nil ->
        if is_nil(get_field(changeset, field)) do
          put_change(changeset, field, default)
        else
          changeset
        end

      _value ->
        changeset
    end
  end

  @doc "Validates `technology_requirements` is nil, empty, or a list of strings."
  def validate_technology_requirements(changeset) do
    MapFieldValidations.validate_string_list_field(changeset, :technology_requirements)
  end

  @doc """
  Validates `dependencies` is nil, empty, or a list of task identifier strings
  that does not include the task's own identifier.
  """
  def validate_dependencies(changeset) do
    case get_field(changeset, :dependencies) do
      nil ->
        changeset

      [] ->
        changeset

      deps when is_list(deps) ->
        changeset
        |> validate_dependencies_format(deps)
        |> validate_no_circular_dependencies(deps)

      _ ->
        add_error(changeset, :dependencies, "must be a list")
    end
  end

  defp validate_dependencies_format(changeset, deps) do
    if Enum.all?(deps, &is_binary/1) do
      changeset
    else
      add_error(changeset, :dependencies, "must be a list of task identifiers (strings)")
    end
  end

  defp validate_no_circular_dependencies(changeset, deps) do
    task_identifier = get_field(changeset, :identifier)

    if task_identifier && task_identifier in deps do
      add_error(changeset, :dependencies, "cannot depend on itself")
    else
      changeset
    end
  end

  @doc """
  Validates `claim_expires_at` is after `claimed_at`, and that `claimed_at` is
  set whenever `claim_expires_at` is.
  """
  def validate_claim_expiration(changeset) do
    claimed_at = get_field(changeset, :claimed_at)
    claim_expires_at = get_field(changeset, :claim_expires_at)

    case {claimed_at, claim_expires_at} do
      {nil, nil} ->
        changeset

      {%DateTime{}, %DateTime{}} ->
        if DateTime.compare(claim_expires_at, claimed_at) == :gt do
          changeset
        else
          add_error(changeset, :claim_expires_at, "must be after claimed_at")
        end

      {nil, %DateTime{}} ->
        add_error(changeset, :claimed_at, "must be set when claim_expires_at is set")

      {%DateTime{}, nil} ->
        changeset
    end
  end

  @doc "Validates `completed_at` is set when `status` is `:completed`."
  def validate_completion_fields(changeset) do
    status = get_field(changeset, :status)
    completed_at = get_field(changeset, :completed_at)

    if status == :completed and is_nil(completed_at) do
      add_error(changeset, :completed_at, "must be set when status is completed")
    else
      changeset
    end
  end

  @doc "Validates a non-nil `target_id` is only set on goal-type tasks."
  # A delivery target may only be attached to goal-type tasks. A non-nil
  # :target_id is permitted when the task's type is :goal and rejected for
  # :work and :defect. Goals without a target are the common case, so a nil
  # :target_id is always allowed.
  def validate_target_requires_goal_type(changeset) do
    if is_nil(get_field(changeset, :target_id)) or get_field(changeset, :type) == :goal do
      changeset
    else
      add_error(changeset, :target_id, "may only be set on goal-type tasks")
    end
  end

  @doc """
  Validates `reviewed_at` and `reviewed_by_id` are set whenever
  `review_status` is set to anything other than `:pending`.
  """
  def validate_review_fields(changeset) do
    review_status = get_field(changeset, :review_status)

    if review_status_requires_metadata?(review_status) do
      changeset
      |> validate_reviewed_at(review_status)
      |> validate_reviewed_by_id(review_status)
    else
      changeset
    end
  end

  defp review_status_requires_metadata?(status) do
    not is_nil(status) and status != :pending
  end

  defp validate_reviewed_at(changeset, review_status) do
    if review_status_requires_metadata?(review_status) and
         is_nil(get_field(changeset, :reviewed_at)) do
      add_error(changeset, :reviewed_at, "must be set when review_status is not pending")
    else
      changeset
    end
  end

  defp validate_reviewed_by_id(changeset, review_status) do
    if review_status_requires_metadata?(review_status) and
         is_nil(get_field(changeset, :reviewed_by_id)) do
      add_error(changeset, :reviewed_by_id, "must be set when review_status is not pending")
    else
      changeset
    end
  end
end
