defmodule Kanban.Schemas.Task.BehaviourTestRow do
  @moduledoc """
  Embedded schema representing one row of a task's behaviour/test matrix.

  Each row pairs a behaviour to verify with the test that covers it:
  - category: One of the seven fixed categories (see `categories/0`)
  - behaviour: What the code should do (e.g. "rejects an expired claim")
  - test_name: The real test covering the behaviour, or "N/A" when waived
  - type: "unit", "integration", "manual", or a '/'-separated combination
    (e.g. "unit / manual"); whitespace around the separator is allowed
  - status: "planned", "passing", "failing", or "not_applicable"
  - na_reason: One-line reason, required when the row is not applicable
  - position: Order of the row within the matrix

  Every constrained field is a plain string validated against a fixed string
  allow-list — row values are user/agent supplied, so they are never converted
  to atoms (atom exhaustion).
  """
  use Ecto.Schema
  import Ecto.Changeset

  # The seven fixed categories. Single source of truth: matrix-level validations
  # and any UI must call `categories/0` rather than redefine this list.
  @categories [
    "Happy path",
    "Boundary",
    "Error / exception",
    "Null / empty",
    "Concurrency",
    "Lifecycle / wiring",
    "Contract / serialization"
  ]

  @statuses ~w(planned passing failing not_applicable)
  @type_tokens ~w(unit integration manual)
  @not_applicable "not_applicable"

  # Values a row uses to waive a behaviour instead of naming a real test. Not a
  # ~w sigil: "not applicable" contains a space and would be split into two
  # separate tokens.
  @na_test_names ["n/a", "na", "not applicable", "not_applicable"]

  @doc "The seven fixed behaviour/test-matrix categories, in canonical order."
  def categories, do: @categories

  @doc "The valid row statuses."
  def statuses, do: @statuses

  @doc "The valid `type` tokens. A row's type is one token or a '/'-joined combination."
  def type_tokens, do: @type_tokens

  @primary_key false
  embedded_schema do
    field :category, :string
    field :behaviour, :string
    field :test_name, :string
    field :type, :string
    field :status, :string, default: "planned"
    field :na_reason, :string
    field :position, :integer
  end

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, [:category, :behaviour, :test_name, :type, :status, :na_reason, :position])
    |> validate_required([:category, :behaviour, :status])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:status, @statuses)
    |> validate_type_combination()
    |> validate_test_name_or_na_reason()
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end

  # "unit", "unit / manual" and "unit/integration/manual" are valid; "flakey",
  # "unit / flakey" and "unit //manual" (empty middle token) are not. The value is
  # split and membership-tested against the fixed token list rather than parsed
  # into atoms.
  defp validate_type_combination(changeset) do
    validate_change(changeset, :type, fn :type, value ->
      if valid_type_combination?(value), do: [], else: [type: type_error_message()]
    end)
  end

  defp valid_type_combination?(value) when is_binary(value) do
    value
    |> String.split("/")
    |> Enum.map(&String.trim/1)
    |> Enum.all?(&(&1 in @type_tokens))
  end

  defp valid_type_combination?(_value), do: false

  defp type_error_message do
    "must be 'unit', 'integration', or 'manual', or a '/'-separated combination (e.g. 'unit / manual')"
  end

  # A row must name the test covering the behaviour, unless it is explicitly
  # waived — by status "not_applicable" or an "N/A" test name — in which case it
  # must say why instead. A row with neither is rejected.
  defp validate_test_name_or_na_reason(changeset) do
    if waived_row?(changeset) do
      validate_required(changeset, [:na_reason],
        message: "is required when the row is not applicable"
      )
    else
      validate_required(changeset, [:test_name],
        message: "is required unless the row is not applicable"
      )
    end
  end

  defp waived_row?(changeset) do
    get_field(changeset, :status) == @not_applicable or
      na_test_name?(get_field(changeset, :test_name))
  end

  defp na_test_name?(test_name) when is_binary(test_name) do
    normalized =
      test_name
      |> String.downcase()
      |> String.split()
      |> Enum.join(" ")

    normalized in @na_test_names
  end

  defp na_test_name?(_test_name), do: false
end
