defmodule KanbanWeb.API.Me.CaptureParamsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.API.Me.CaptureParams

  defp errors({:error, changeset}) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  test "casts board_id, type, title and an optional description" do
    assert CaptureParams.cast(%{"board_id" => 5, "type" => "work", "title" => "T"}) ==
             {:ok, %{board_id: 5, type: "work", title: "T", description: nil}}

    assert CaptureParams.cast(%{
             "board_id" => "5",
             "type" => "defect",
             "title" => "T",
             "description" => "D"
           }) == {:ok, %{board_id: 5, type: "defect", title: "T", description: "D"}}
  end

  test "ignores every other key" do
    assert CaptureParams.cast(%{
             "board_id" => 5,
             "type" => "work",
             "title" => "T",
             "parent_id" => 9,
             "identifier" => "W1",
             "status" => "completed",
             "column_id" => 3,
             "assigned_to_id" => 2,
             "created_via" => "web"
           }) == {:ok, %{board_id: 5, type: "work", title: "T", description: nil}}
  end

  test "requires board_id, type and title" do
    assert errors(CaptureParams.cast(%{})) == %{
             board_id: ["can't be blank"],
             type: ["can't be blank"],
             title: ["can't be blank"]
           }

    assert errors(CaptureParams.cast(%{"board_id" => 5, "type" => "work", "title" => " "})) ==
             %{title: ["can't be blank"]}
  end

  test "refuses a goal or an unknown type" do
    for type <- ["goal", "epic", "Work", 1] do
      assert errors(CaptureParams.cast(%{"board_id" => 5, "type" => type, "title" => "T"})) ==
               %{type: ["is invalid"]}
    end
  end

  test "refuses a board_id that is not a positive integer in the bigint range" do
    for board_id <- [0, -1, "x", 1.5, 9_223_372_036_854_775_808] do
      assert %{board_id: [_message]} =
               errors(
                 CaptureParams.cast(%{"board_id" => board_id, "type" => "work", "title" => "T"})
               )
    end
  end

  test "refuses a title or description that is not a string" do
    assert errors(
             CaptureParams.cast(%{
               "board_id" => 5,
               "type" => "work",
               "title" => 3,
               "description" => %{}
             })
           ) == %{title: ["is invalid"], description: ["is invalid"]}
  end
end
