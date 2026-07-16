defmodule KanbanWeb.API.TaskParamFilterTest do
  @moduledoc """
  Unit tests for the extracted mass-assignment param filter (W1443). Pins the
  forbidden-field stripping, the fail-closed column-change detection, and the
  exact monitored audit log message strings.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias KanbanWeb.API.TaskParamFilter

  describe "filter_forbidden_update_fields/1" do
    test "strips forbidden fields and reports them, keeping allowed fields" do
      params = %{
        "title" => "New title",
        "status" => "done",
        "column_id" => "5",
        "identifier" => "W1"
      }

      {safe, rejected} = TaskParamFilter.filter_forbidden_update_fields(params)

      assert safe == %{"title" => "New title"}
      assert "status" in rejected
      assert "column_id" in rejected
      assert "identifier" in rejected
      refute "title" in rejected
    end

    test "reports no rejections when only allowed fields are present" do
      {safe, rejected} =
        TaskParamFilter.filter_forbidden_update_fields(%{"title" => "x", "description" => "y"})

      assert safe == %{"title" => "x", "description" => "y"}
      assert rejected == []
    end
  end

  describe "filter_forbidden_create_fields/1" do
    test "strips create-forbidden fields but keeps column_id" do
      params = %{"title" => "x", "status" => "done", "column_id" => "5", "position" => 3}
      {safe, rejected} = TaskParamFilter.filter_forbidden_create_fields(params)

      assert safe["title"] == "x"
      assert safe["column_id"] == "5"
      refute Map.has_key?(safe, "status")
      assert "status" in rejected
      assert "position" in rejected
    end

    test "passes a non-map through unchanged with no rejections" do
      assert TaskParamFilter.filter_forbidden_create_fields("not a map") == {"not a map", []}
    end

    test "strips a client-supplied parent_id (D153)" do
      params = %{"title" => "x", "parent_id" => 42}
      {safe, rejected} = TaskParamFilter.filter_forbidden_create_fields(params)

      refute Map.has_key?(safe, "parent_id")
      assert "parent_id" in rejected
    end
  end

  describe "filter_child_tasks/1" do
    test "filters each child and deduplicates rejected field names across children" do
      children = [
        %{"title" => "a", "status" => "done"},
        %{"title" => "b", "status" => "open", "position" => 2}
      ]

      {safe, rejected} = TaskParamFilter.filter_child_tasks(children)

      assert safe == [%{"title" => "a"}, %{"title" => "b"}]
      assert Enum.sort(rejected) == ["position", "status"]
    end

    test "passes a non-list through unchanged" do
      assert TaskParamFilter.filter_child_tasks(nil) == {nil, []}
    end

    test "strips parent_id from child tasks (D153)" do
      children = [%{"title" => "a", "parent_id" => 7}]
      {safe, rejected} = TaskParamFilter.filter_child_tasks(children)

      assert safe == [%{"title" => "a"}]
      assert "parent_id" in rejected
    end
  end

  describe "column_change_attempted?/2" do
    test "true when the requested column differs from the task's column" do
      assert TaskParamFilter.column_change_attempted?(%{"column_id" => "5"}, %{column_id: 3})
    end

    test "false when the requested column matches" do
      refute TaskParamFilter.column_change_attempted?(%{"column_id" => "3"}, %{column_id: 3})
    end

    test "true (fail closed) when the column_id is unparseable" do
      assert TaskParamFilter.column_change_attempted?(%{"column_id" => "abc"}, %{column_id: 3})
    end

    test "false when no column_id is present" do
      refute TaskParamFilter.column_change_attempted?(%{"title" => "x"}, %{column_id: 3})
    end
  end

  describe "audit logging (monitored message strings)" do
    setup do
      prev = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev) end)
      :ok
    end

    test "log_update_mass_assignment logs the exact rejection message when fields were rejected" do
      log =
        capture_log(fn ->
          TaskParamFilter.log_update_mass_assignment(42, ["status", "identifier"], 7)
        end)

      assert log =~ "API mass-assignment attempt rejected"
    end

    test "log_update_mass_assignment is a no-op when nothing was rejected" do
      log =
        capture_log(fn -> assert TaskParamFilter.log_update_mass_assignment(42, [], 7) == :ok end)

      refute log =~ "mass-assignment"
    end

    test "log_create_mass_assignment logs the exact create rejection message" do
      log =
        capture_log(fn ->
          TaskParamFilter.log_create_mass_assignment(["status"], ["position"], 7)
        end)

      assert log =~ "API mass-assignment attempt rejected on create"
    end

    test "log_create_mass_assignment is a no-op when nothing was rejected" do
      log =
        capture_log(fn -> assert TaskParamFilter.log_create_mass_assignment([], [], 7) == :ok end)

      refute log =~ "mass-assignment"
    end
  end
end
