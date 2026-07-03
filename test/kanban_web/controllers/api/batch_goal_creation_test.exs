defmodule KanbanWeb.API.BatchGoalCreationTest do
  @moduledoc """
  Unit tests for the batch failure-response rendering (W1444/W1448). The success
  path and the full create pipeline are covered end-to-end by
  task_controller_test.exs; these pin the two terminal failure shapes directly,
  including the WIP-limit branch the controller suite did not exercise.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  alias KanbanWeb.API.BatchGoalCreation

  describe "handle_batch_result/2 — failure responses" do
    test "renders 422 for a WIP-limit failure with the goal index" do
      conn =
        BatchGoalCreation.handle_batch_result({:error, 2, :wip_limit_reached}, conn(:get, "/"))

      assert conn.status == 422

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "WIP limit reached while creating goal at index 2",
               "index" => 2
             }
    end

    test "renders 422 for a changeset failure with per-index details" do
      changeset =
        {%{}, %{title: :string}}
        |> Ecto.Changeset.cast(%{}, [:title])
        |> Ecto.Changeset.validate_required([:title])

      conn = BatchGoalCreation.handle_batch_result({:error, 0, changeset}, conn(:get, "/"))

      assert conn.status == 422

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Failed to create goal at index 0"
      assert body["index"] == 0
      assert body["details"] == %{"title" => ["can't be blank"]}
    end
  end
end
