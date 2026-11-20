defmodule KanbanWeb.API.Me.PromoteParams do
  @moduledoc """
  Casts the body of `POST /api/me/boards/:id/promote` (W2759): `task_ids`, a
  list of 1 to 100 task ids (required), and `needs_review`, a boolean
  (optional). Any other key is ignored, so the app can never send an edit
  beyond `needs_review`. A failure is a changeset, rendered as `422
  {"errors": {field: [message]}}` by `KanbanWeb.API.Me.FallbackController`.
  """

  import Ecto.Changeset

  alias Kanban.Tasks.Promote

  @max_bigint 9_223_372_036_854_775_807
  @types %{task_ids: {:array, :integer}, needs_review: :boolean}

  @doc """
  Returns `{:ok, task_ids, needs_review}`, where `needs_review` is `true`,
  `false` or `nil` when it was not sent, or `{:error, changeset}`.
  """
  @spec cast(map()) :: {:ok, [pos_integer()], boolean() | nil} | {:error, Ecto.Changeset.t()}
  def cast(params) when is_map(params) do
    changeset =
      {%{}, @types}
      |> cast(params, Map.keys(@types))
      |> validate_required([:task_ids])
      |> validate_length(:task_ids, min: 1, message: "can't be blank")
      |> validate_length(:task_ids, max: Promote.max_tasks())
      |> validate_change(:task_ids, &validate_ids/2)

    case apply_action(changeset, :insert) do
      {:ok, data} -> {:ok, data.task_ids, Map.get(data, :needs_review)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp validate_ids(:task_ids, ids) do
    if Enum.all?(ids, &(is_integer(&1) and &1 > 0 and &1 <= @max_bigint)),
      do: [],
      else: [task_ids: "is invalid"]
  end
end
