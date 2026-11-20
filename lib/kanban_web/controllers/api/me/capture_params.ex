defmodule KanbanWeb.API.Me.CaptureParams do
  @moduledoc """
  Casts the body of `POST /api/me/tasks` (W2760, the app's quick capture,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.11): `board_id`, the
  board to capture into (required); `type`, `"work"` or `"defect"`
  (required, so a goal is refused); `title` (required); and `description`
  (optional), the fields the app's form has.

  Any other key is ignored: a `parent_id`, `identifier`, `status`,
  `column_id`, `assigned_to_id`, `created_via` or any other task field never
  reaches the task. A failure is a changeset, rendered as `422 {"errors":
  {field: [message]}}` by `KanbanWeb.API.Me.FallbackController`; the title's
  length and the description's are checked by the task schema itself.
  """

  import Ecto.Changeset

  @max_bigint 9_223_372_036_854_775_807
  @types %{board_id: :integer, type: :string, title: :string, description: :string}

  @type t :: %{
          board_id: pos_integer(),
          type: String.t(),
          title: String.t(),
          description: String.t() | nil
        }

  @doc """
  Returns `{:ok, %{board_id:, type:, title:, description:}}`, where
  `description` is `nil` when it was not sent or was blank, or
  `{:error, changeset}`.
  """
  @spec cast(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(params) when is_map(params) do
    changeset =
      {%{}, @types}
      |> cast(params, Map.keys(@types))
      |> validate_required([:board_id, :type, :title])
      |> validate_number(:board_id, greater_than: 0, less_than_or_equal_to: @max_bigint)
      |> validate_inclusion(:type, ["work", "defect"])

    case apply_action(changeset, :insert) do
      {:ok, data} ->
        {:ok,
         %{
           board_id: data.board_id,
           type: data.type,
           title: data.title,
           description: Map.get(data, :description)
         }}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
