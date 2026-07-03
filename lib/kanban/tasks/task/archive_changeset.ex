defmodule Kanban.Tasks.Task.ArchiveChangeset do
  @moduledoc """
  The archive write-path changeset and its conditional validations for
  `Kanban.Tasks.Task`, extracted from the schema module (W1445).

  `changeset/2` casts only the archive-metadata fields and runs
  `validate_archive_fields/1`, skipping the unrelated full-task validations so
  archiving does not retroactively reject pre-existing inconsistent state on
  other fields. `Kanban.Tasks.Task.archive_changeset/2` delegates here, and
  `Kanban.Tasks.Task.changeset/2` still calls `validate_archive_fields/1`
  directly (hence it is public). Error strings are asserted verbatim by the
  schema tests and shown to API clients, so they must not drift.
  """

  import Ecto.Changeset

  @archive_reasons_requiring_note [:wontdo, :deferred, :cancelled]

  @doc """
  Focused changeset for the archive write path. Casts only the
  archive-metadata fields plus `archived_at`, runs `validate_archive_fields/1`,
  and declares the relevant FK + check constraints — but skips the unrelated
  full-task validations so archiving a task does NOT retroactively reject
  pre-existing inconsistent state on unrelated fields.

  See `Kanban.Tasks.Lifecycle.archive_task/2` for the caller.
  """
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :archived_at,
      :archive_reason,
      :archive_note,
      :archived_by_id,
      :duplicate_of_id
    ])
    |> validate_archive_fields()
    |> foreign_key_constraint(:archived_by_id)
    |> foreign_key_constraint(:duplicate_of_id)
    |> check_constraint(:duplicate_of_id,
      name: :duplicate_of_id_not_self,
      message: "must not reference the task itself"
    )
  end

  # Archive-reason conditional validations:
  #
  #   :completed                          → no extra fields required
  #   :wontdo / :deferred / :cancelled    → archive_note required
  #   :duplicate                          → duplicate_of_id required
  #   anything other than :duplicate      → duplicate_of_id forbidden
  #
  # Reason whitelist is enforced by `Ecto.Enum` on the field itself.
  @doc """
  Applies the archive-reason conditional rules. Public because
  `Kanban.Tasks.Task.changeset/2` runs it as a pipeline stage too.
  """
  def validate_archive_fields(changeset) do
    reason = get_field(changeset, :archive_reason)

    changeset
    |> validate_archive_note_required(reason)
    |> validate_duplicate_of_id_required(reason)
    |> validate_duplicate_of_id_forbidden(reason)
  end

  defp validate_archive_note_required(changeset, reason)
       when reason in @archive_reasons_requiring_note do
    if blank_string?(get_field(changeset, :archive_note)) do
      add_error(
        changeset,
        :archive_note,
        "must be set when archive_reason is :wontdo, :deferred, or :cancelled"
      )
    else
      changeset
    end
  end

  defp validate_archive_note_required(changeset, _reason), do: changeset

  defp validate_duplicate_of_id_required(changeset, :duplicate) do
    if is_nil(get_field(changeset, :duplicate_of_id)) do
      add_error(
        changeset,
        :duplicate_of_id,
        "must be set when archive_reason is :duplicate"
      )
    else
      changeset
    end
  end

  defp validate_duplicate_of_id_required(changeset, _reason), do: changeset

  defp validate_duplicate_of_id_forbidden(changeset, :duplicate), do: changeset

  defp validate_duplicate_of_id_forbidden(changeset, _reason) do
    if is_nil(get_field(changeset, :duplicate_of_id)) do
      changeset
    else
      add_error(
        changeset,
        :duplicate_of_id,
        "may only be set when archive_reason is :duplicate"
      )
    end
  end

  defp blank_string?(nil), do: true
  defp blank_string?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank_string?(_), do: true
end
