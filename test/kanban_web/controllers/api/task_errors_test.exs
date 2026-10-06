defmodule KanbanWeb.API.TaskErrorsTest do
  @moduledoc """
  Unit tests for the pure helpers of the extracted error-translation module
  (W1444). The conn-rendering functions (handle_task_error/2, error_response/4,
  handle_hook_validation_error/3) are exercised end-to-end by the 245-test
  task_controller_test.exs suite; these lock the pure mapping/stringification.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  alias KanbanWeb.API.TaskErrors

  describe "mark_reviewed_error/1" do
    test "maps each known reason to its exact {message, doc_key} pair" do
      assert TaskErrors.mark_reviewed_error(:invalid_column) ==
               {"Task must be in Review column to mark as reviewed", :invalid_column_for_review}

      assert TaskErrors.mark_reviewed_error(:review_not_performed) ==
               {"Task must have a review status before being marked as reviewed",
                :review_not_performed}

      assert TaskErrors.mark_reviewed_error(:invalid_review_status) ==
               {"Invalid review status. Must be 'approved', 'changes_requested', or 'rejected'",
                :invalid_review_status}
    end

    test "falls back for an unknown reason without leaking the reason detail" do
      assert TaskErrors.mark_reviewed_error(:something_unexpected) ==
               {"Unexpected mark_reviewed error", :unexpected_mark_reviewed_error}
    end
  end

  describe "translate_changeset_errors/1" do
    test "traverses errors into a field=>messages map with interpolation applied" do
      changeset =
        {%{}, %{title: :string}}
        |> Ecto.Changeset.cast(%{title: "ab"}, [:title])
        |> Ecto.Changeset.validate_length(:title, min: 3)

      assert TaskErrors.translate_changeset_errors(changeset) == %{
               title: ["should be at least 3 character(s)"]
             }
    end

    test "stringifies a required-field error" do
      changeset =
        {%{}, %{title: :string}}
        |> Ecto.Changeset.cast(%{}, [:title])
        |> Ecto.Changeset.validate_required([:title])

      assert TaskErrors.translate_changeset_errors(changeset) == %{title: ["can't be blank"]}
    end

    test "stringifies binary and non-scalar interpolation values" do
      changeset =
        {%{}, %{title: :string}}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:title, "binary %{val}", val: "verbatim")
        |> Ecto.Changeset.add_error(:tags, "list %{val}", val: [1, 2])

      result = TaskErrors.translate_changeset_errors(changeset)

      assert result.title == ["binary verbatim"]
      assert result.tags == ["list [1, 2]"]
    end
  end

  describe "handle_task_error/2 — column_forbidden" do
    test "renders 403 for a column that does not belong to the board" do
      conn = conn(:get, "/") |> TaskErrors.handle_task_error({:error, :column_forbidden})

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"error" => "Column does not belong to this board"}
    end
  end

  describe "handle_task_error/2 — wip_limit_reached (D356)" do
    test "renders 422 with a static WIP message and documentation" do
      conn = conn(:get, "/") |> TaskErrors.handle_task_error({:error, :wip_limit_reached})

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)

      assert body["error"] =~ "WIP limit reached"
      assert body["documentation"] =~ "api/post_tasks.md#unprocessable-entity-422"
      assert [_ | _] = body["common_causes"]
      assert body |> Map.keys() |> Enum.sort() == ["common_causes", "documentation", "error"]
    end
  end

  describe "error_body/1 (W2231)" do
    test "translates the claim and complete reasons with their API error codes" do
      assert {:not_found, :no_tasks_available,
              %{error: "No tasks available in Ready column" <> _}} =
               TaskErrors.error_body(:no_next_task)

      assert {:conflict, :no_tasks_available, %{error: "No tasks available to claim" <> _}} =
               TaskErrors.error_body({:no_tasks_available, nil})

      assert {:conflict, :task_not_claimable, %{error: "Task 'W1' is not available" <> _}} =
               TaskErrors.error_body({:no_tasks_available, "W1"})

      assert {:forbidden, :assigned_to_other_user, %{error: "Task 'W1' is assigned" <> _}} =
               TaskErrors.error_body({:assigned_to_other_user, "W1"})

      assert {:forbidden, :assigned_to_other_user, %{error: "This task is assigned" <> _}} =
               TaskErrors.error_body({:assigned_to_other_user, nil})

      assert {:forbidden, :not_authorized_to_claim, _} =
               TaskErrors.error_body(:not_authorized_to_claim)

      assert {:unprocessable_entity, :invalid_status_for_complete, _} =
               TaskErrors.error_body(:invalid_status_for_complete)

      assert {:forbidden, :not_authorized_to_complete, _} =
               TaskErrors.error_body(:not_authorized_to_complete)

      assert {:bad_request, :invalid_param, %{error: "bad limit"}} =
               TaskErrors.error_body({:invalid_param, "bad limit"})

      assert {:internal_server_error, :internal_server_error, body} =
               TaskErrors.error_body(:claim_failed)

      assert body == TaskErrors.unexpected_claim_error_body()
    end

    test "a hook failure carries the required format" do
      assert {:unprocessable_entity, :hook_validation_failed, body} =
               TaskErrors.error_body({:hook_failed, "after_doing", "exit_code is required"})

      assert body.hook == "after_doing"
      assert Map.has_key?(body.required_format, "after_doing_result")
    end

    test "a changeset renders the TaskJSON validation body" do
      changeset =
        {%{}, %{content: :string}}
        |> Ecto.Changeset.cast(%{}, [:content])
        |> Ecto.Changeset.validate_required([:content])

      assert {:unprocessable_entity, :validation_error, %{errors: %{content: [_]}}} =
               TaskErrors.error_body(changeset)
    end

    test "render_error/2 renders exactly the error_body/1 status and body" do
      conn = :get |> conn("/") |> TaskErrors.render_error(:not_found)

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body) == %{"error" => "Task not found"}
    end
  end
end
