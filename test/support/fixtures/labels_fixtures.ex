defmodule Kanban.LabelsFixtures do
  @moduledoc """
  This module defines test helpers for creating `Kanban.Labels.Label`
  entities.
  """

  alias Kanban.Labels.Label
  alias Kanban.Repo

  @doc """
  Generate a label on the given board.

  `board_id` is set on the struct (it is not castable), matching how
  `Kanban.Labels` assigns a label's board.
  """
  def label_fixture(board, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Label #{System.unique_integer([:positive])}",
        color: :blue
      })

    {:ok, label} =
      %Label{board_id: board.id}
      |> Label.changeset(attrs)
      |> Repo.insert()

    label
  end
end
