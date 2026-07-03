defmodule Kanban.Tasks.Task.EmbedValidations do
  @moduledoc """
  Embed type-checking and error-message enhancement for the `key_files` and
  `verification_steps` embeds on `Kanban.Tasks.Task`, extracted from the schema
  module (W1445).

  `validate_embed_type/3` guards the raw attrs shape before `cast_embed`, and
  `validate_key_file_embed/2` / `validate_verification_step_embed/2` are the
  `cast_embed(:field, with: ...)` callbacks that rewrite Ecto's generic
  "can't be blank"/"is invalid" messages into the API's friendlier wording.
  The error strings are asserted verbatim by the schema tests and shown to API
  clients, so they must not drift. Changeset-in / changeset-out.
  """

  import Ecto.Changeset

  alias Kanban.Schemas.Task.KeyFile
  alias Kanban.Schemas.Task.VerificationStep

  @doc """
  Rejects a non-array value (or non-object array items) for an embed field,
  before `cast_embed` runs. `nil` and `[]` are valid (no embedded records).
  """
  def validate_embed_type(changeset, field, attrs) do
    field_str = to_string(field)

    case Map.get(attrs, field_str) || Map.get(attrs, field) do
      nil ->
        changeset

      [] ->
        # Empty arrays are valid - just means no embedded records
        changeset

      value when is_list(value) ->
        validate_embed_array_items(changeset, field, value)

      _non_list_value ->
        add_error(changeset, field, embed_type_error_message(field, :not_array))
    end
  end

  defp validate_embed_array_items(changeset, field, value) do
    if Enum.all?(value, &is_map/1) do
      changeset
    else
      add_error(changeset, field, embed_type_error_message(field, :not_objects))
    end
  end

  defp embed_type_error_message(field, error_type) do
    case {field, error_type} do
      {:key_files, :not_objects} ->
        "must be an array of objects with file_path, note, and position fields"

      {:verification_steps, :not_objects} ->
        "must be an array of objects with step_type, step_text, expected_result, and position fields"

      {_, :not_objects} ->
        "must be an array of objects"

      {:key_files, :not_array} ->
        "must be an array of objects with file_path, note, and position fields"

      {:verification_steps, :not_array} ->
        "must be an array of objects with step_type, step_text, expected_result, and position fields"

      {_, :not_array} ->
        "must be an array"
    end
  end

  @doc "cast_embed callback for `:key_files` with improved error messages."
  def validate_key_file_embed(key_file, attrs) do
    KeyFile.changeset(key_file, attrs)
    |> improve_embed_errors(:key_files)
  end

  @doc "cast_embed callback for `:verification_steps` with improved error messages."
  def validate_verification_step_embed(step, attrs) do
    VerificationStep.changeset(step, attrs)
    |> improve_embed_errors(:verification_steps)
  end

  defp improve_embed_errors(changeset, field_name) do
    # If the changeset is valid, return it as-is
    if changeset.valid? do
      changeset
    else
      # Otherwise, enhance error messages for better clarity
      case field_name do
        :key_files ->
          enhance_key_file_errors(changeset)

        :verification_steps ->
          enhance_verification_step_errors(changeset)

        _ ->
          changeset
      end
    end
  end

  defp enhance_key_file_errors(changeset) do
    changeset
    |> update_error_message(
      :file_path,
      "can't be blank",
      "is required (relative path from project root)"
    )
    |> update_error_message(:position, "can't be blank", "is required (integer starting from 0)")
  end

  defp enhance_verification_step_errors(changeset) do
    changeset
    |> update_error_message(:step_type, "can't be blank", "is required ('command' or 'manual')")
    |> update_error_message(:step_text, "can't be blank", "is required (command or instruction)")
    |> update_error_message(:position, "can't be blank", "is required (integer starting from 0)")
    |> update_error_message(:step_type, "is invalid", "must be 'command' or 'manual'")
  end

  defp update_error_message(changeset, field, old_msg, new_msg) do
    errors = changeset.errors

    updated_errors =
      Enum.map(errors, fn
        {^field, {^old_msg, opts}} -> {field, {new_msg, opts}}
        error -> error
      end)

    %{changeset | errors: updated_errors}
  end
end
