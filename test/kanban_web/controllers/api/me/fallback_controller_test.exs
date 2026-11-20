defmodule KanbanWeb.API.Me.FallbackControllerTest do
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.API.Me.FallbackController

  test "a device revoked mid-request answers the plug's 401", %{conn: conn} do
    conn = FallbackController.call(conn, {:error, :revoked})
    assert json_response(conn, 401) == %{"error" => "Invalid access token"}
  end

  test "not found answers 404 with the Error shape", %{conn: conn} do
    conn = FallbackController.call(conn, {:error, :not_found})
    assert json_response(conn, 404) == %{"error" => "Not Found"}
  end

  test "a plan refusal answers 403 with the PlanRequired shape", %{conn: conn} do
    conn = FallbackController.call(conn, {:error, {:plan_required, :mobile_app}})

    assert json_response(conn, 403) == %{
             "error" => "plan_required",
             "feature" => "mobile_app",
             "message" => "The Stride app is available to boards in an Organization."
           }
  end

  test "a changeset answers 422 with the messages and no values", %{conn: conn} do
    changeset =
      {%{}, %{time_zone: :string}}
      |> Ecto.Changeset.cast(%{time_zone: "Secret/Zone"}, [:time_zone])
      |> Ecto.Changeset.validate_length(:time_zone, max: 3)

    body = conn |> FallbackController.call({:error, changeset}) |> json_response(422)

    assert body == %{"errors" => %{"time_zone" => ["should be at most 3 character(s)"]}}
  end

  describe "the promote refusals (W2759)" do
    test "read-only access answers 403 Forbidden", %{conn: conn} do
      assert conn |> FallbackController.call({:error, :forbidden}) |> json_response(403) ==
               %{"error" => "Forbidden", "message" => "This needs write access to the board."}
    end

    test "an empty or oversized selection answers 422 on task_ids", %{conn: conn} do
      assert conn |> FallbackController.call({:error, :empty_selection}) |> json_response(422) ==
               %{"errors" => %{"task_ids" => ["can't be blank"]}}

      assert build_conn()
             |> FallbackController.call({:error, :too_many_tasks})
             |> json_response(422) ==
               %{"errors" => %{"task_ids" => ["should have at most 100 item(s)"]}}
    end

    test "not_promotable names the refused tasks", %{conn: conn} do
      assert conn
             |> FallbackController.call({:error, {:not_promotable, [4, 9]}})
             |> json_response(422) == %{
               "error" => "not_promotable",
               "message" => "Only work and defect tasks in Backlog can be promoted to Ready.",
               "task_ids" => [4, 9]
             }
    end

    test "the reason-only refusals answer 422 with their reason" do
      for {reason, message} <- [
            wip_limit_reached: "Ready has no room for these tasks under its WIP limit.",
            no_ready_column: "This board has no Ready column.",
            update_failed: "The tasks could not be promoted. Try again."
          ] do
        assert build_conn() |> FallbackController.call({:error, reason}) |> json_response(422) ==
                 %{"error" => Atom.to_string(reason), "message" => message}
      end
    end

    test "a concurrent move answers 409 conflict", %{conn: conn} do
      assert conn |> FallbackController.call({:error, :conflict}) |> json_response(409) == %{
               "error" => "conflict",
               "message" => "A task was moved by someone else at the same time. Try again."
             }
    end
  end
end
