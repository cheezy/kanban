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
end
