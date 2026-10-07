defmodule Kanban.Tasks.Task.LengthValidations do
  @moduledoc """
  Code-point length caps for the Postgres `varchar(255)` and `varchar(255)[]`
  columns on `Kanban.Tasks.Task` (D81).

  Split from `Kanban.Tasks.Task` to keep the schema module under the project's
  module-size guideline. `Kanban.Tasks.Task.varchar_255_fields/0` and
  `Kanban.Tasks.Task.varchar_255_array_fields/0` delegate to the allow-lists
  here, and the task changesets run `validate_varchar_255_lengths/1` and
  `validate_varchar_255_array_element_lengths/1` as pipeline stages. The error
  strings and opts are asserted by the schema tests and shown to API clients, so
  they must not drift. Changeset-in / changeset-out.
  """

  import Ecto.Changeset

  # Free-text columns stored as Postgres varchar(255). Their changesets carried no
  # length bound, so oversized input bypassed validation and raised a 22001
  # (string_data_right_truncation) → HTTP 500 instead of a clean 422 (D81). The
  # enum columns (type/priority/status/complexity/actual_complexity/review_status,
  # and archive_reason — an Ecto.Enum) are varchar too but already guarded by the
  # cast/validate_inclusion, which rejects any out-of-range value long before a
  # length could matter; identifier is server-generated and bounded. None of those
  # needs a length cap here.
  @varchar_255_max 255
  @varchar_255_fields [
    :title,
    :estimated_files,
    :telemetry_event,
    :created_by_agent,
    :completed_by_agent
  ]

  # Array columns stored as Postgres varchar(255)[]. Each ELEMENT is capped at
  # 255 code points, so an oversized element raised a 22001 → HTTP 500 the same
  # way the scalar varchar(255) fields did (D81). The scalar fix above never
  # checked element length, so a long free-text security_considerations entry (or
  # an over-long dependency identifier) still slipped through to the DB. The
  # element-level cap below closes that gap on both the create and update paths.
  # (required_capabilities is also varchar(255)[] but is independently bounded to
  # the short @valid_capabilities allow-list in Kanban.Tasks.Task.Capabilities; it
  # is included here for completeness so every varchar(255)[] column is guarded
  # uniformly.)
  @varchar_255_array_fields [
    :security_considerations,
    :dependencies,
    :required_capabilities
  ]

  @doc """
  The free-text scalar varchar(255) columns guarded by a changeset length
  validator (D81). Exposed so the regression guard in the test suite (W1412)
  can assert this allow-list stays in sync with the database schema.
  """
  def varchar_255_fields, do: @varchar_255_fields

  @doc """
  The varchar(255)[] array columns whose elements are guarded by a changeset
  length validator (D81). Exposed so the regression guard in the test suite
  (W1412) can assert this allow-list stays in sync with the database schema.
  """
  def varchar_255_array_fields, do: @varchar_255_array_fields

  @doc """
  Caps the free-text varchar(255) columns so oversized input fails with a 422
  changeset error instead of reaching Postgres and raising a 22001 / 500 (D81).
  """
  # Postgres varchar(n) limits by Unicode code point. That is NOT the grapheme
  # count Ecto's `validate_length` uses by default — a multi-codepoint grapheme
  # (e.g. an emoji with modifiers, or a base char + combining mark) would pass a
  # 255-grapheme check yet still overflow the column — and it is NOT a byte count
  # either, which would wrongly reject legitimate multibyte text well under 255
  # characters. So count code points directly to match the database exactly.
  def validate_varchar_255_lengths(changeset) do
    Enum.reduce(@varchar_255_fields, changeset, fn field, acc ->
      validate_change(acc, field, fn ^field, value ->
        if is_binary(value) and codepoint_length(value) > @varchar_255_max do
          [
            {field,
             {"should be at most %{count} character(s)",
              [count: @varchar_255_max, validation: :length, kind: :max, type: :string]}}
          ]
        else
          []
        end
      end)
    end)
  end

  @doc """
  Caps each ELEMENT of the varchar(255)[] array columns at 255 code points so an
  oversized entry fails with a 422 changeset error instead of reaching Postgres
  and raising a 22001 / 500 (D81 follow-up).
  """
  # Uses the same code-point counting as the scalar check so it matches the
  # database exactly. Non-binary elements are left for the existing per-field
  # validators (validate_string_list_field, validate_dependencies,
  # validate_required_capabilities) to reject.
  def validate_varchar_255_array_element_lengths(changeset) do
    Enum.reduce(@varchar_255_array_fields, changeset, fn field, acc ->
      validate_change(acc, field, fn ^field, value ->
        if oversized_element?(value) do
          [
            {field,
             {"each entry should be at most %{count} character(s)",
              [count: @varchar_255_max, validation: :length, kind: :max, type: :string]}}
          ]
        else
          []
        end
      end)
    end)
  end

  defp oversized_element?(value) when is_list(value) do
    Enum.any?(value, fn element ->
      is_binary(element) and codepoint_length(element) > @varchar_255_max
    end)
  end

  defp oversized_element?(_value), do: false

  defp codepoint_length(value), do: value |> String.codepoints() |> length()
end
