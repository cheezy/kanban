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
end
