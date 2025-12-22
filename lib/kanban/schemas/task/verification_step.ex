defmodule Kanban.Schemas.Task.VerificationStep do
  @moduledoc """
  Embedded schema representing a verification step to confirm task completion.

  Each verification step has:
  - step_type: Either "command" (automated) or "manual" (human verification)
  - step_text: The command to run or manual instruction
  - expected_result: What should happen when the step succeeds
  - position: Order in which steps should be executed
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :step_type, :string
    field :step_text, :string
    field :expected_result, :string
    field :position, :integer
  end

  @doc false
  def changeset(step, attrs) do
    step
    |> cast(attrs, [:step_type, :step_text, :expected_result, :position])
    |> validate_required([:step_type, :step_text, :position])
    |> validate_inclusion(:step_type, ["command", "manual"])
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end
end
