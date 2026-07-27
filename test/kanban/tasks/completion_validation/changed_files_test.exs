defmodule Kanban.Tasks.CompletionValidation.ChangedFilesTest do
  @moduledoc """
  Direct unit tests for the changed_files validator (W1953).

  The behaviour is also exercised through the
  `CompletionValidation.validate_changed_files/1` delegate in
  completion_validation_test.exs. This file pins the two things worth asserting
  at the unit: that the D114 path-safety wiring survived the move out of the
  parent module intact, and the numeric edges of the diff line cap.
  """
  use ExUnit.Case, async: true

  alias Kanban.Tasks.CompletionValidation.ChangedFiles

  defp entry(path, extra \\ %{}), do: Map.merge(%{"path" => path}, extra)

  describe "validate/1 — acceptance" do
    test "an empty array is valid" do
      assert ChangedFiles.validate([]) == {:ok, []}
    end

    test "entries with a path and no diff are valid" do
      value = [entry("lib/a.ex"), entry("test/a_test.exs")]
      assert ChangedFiles.validate(value) == {:ok, value}
    end

    test "nil is rejected — the field must be sent explicitly" do
      assert ChangedFiles.validate(nil) ==
               {:error, [{:changed_files, "must be present (send [] to clear)"}]}
    end

    test "a non-list is rejected" do
      assert ChangedFiles.validate(%{}) == {:error, [{:changed_files, "must be a list"}]}
    end
  end

  describe "validate/1 — path safety (D114)" do
    # Direct evidence that the Kanban.Tasks.PathSafety call survived the
    # extraction: each rejection below comes from that predicate, not from a
    # local re-implementation.
    test "rejects .. traversal" do
      assert {:error, errors} = ChangedFiles.validate([entry("../etc/passwd")])

      assert errors == [
               {:changed_file_path,
                "changed_files[0] \"path\" must not contain .. path traversal"}
             ]
    end

    test "rejects an absolute path" do
      assert {:error, errors} = ChangedFiles.validate([entry("/etc/passwd")])

      assert errors == [
               {:changed_file_path,
                "changed_files[0] \"path\" must be a relative path, not absolute"}
             ]
    end

    test "rejects an embedded null byte" do
      assert {:error, errors} = ChangedFiles.validate([entry("lib/a.ex\0.png")])

      assert errors == [
               {:changed_file_path, "changed_files[0] \"path\" must not contain a null byte"}
             ]
    end

    test "rejects an empty or non-string path" do
      assert {:error, [{:changed_file_path, message}]} = ChangedFiles.validate([entry("")])
      assert message == "changed_files[0] must have a non-empty string \"path\""

      assert {:error, [{:changed_file_path, ^message}]} = ChangedFiles.validate([entry(123)])
    end

    test "reports every failing entry, with its own index" do
      assert {:error, errors} =
               ChangedFiles.validate([entry("ok/a.ex"), entry("../x"), entry("/y")])

      assert [{:changed_file_path, first}, {:changed_file_path, second}] = errors
      assert first =~ "changed_files[1]"
      assert second =~ "changed_files[2]"
    end

    test "a non-map entry is rejected by index" do
      assert ChangedFiles.validate(["nope"]) ==
               {:error, [{:changed_file_entry, "changed_files[0] must be a map"}]}
    end
  end

  describe "validate/1 — diff line cap" do
    defp diff_of(lines), do: Enum.map_join(1..lines, "\n", &"+line #{&1}")

    test "a diff of exactly the cap is accepted" do
      value = [entry("lib/a.ex", %{"diff" => diff_of(500)})]
      assert ChangedFiles.validate(value) == {:ok, value}
    end

    test "one line over the cap is rejected" do
      assert {:error, [{:changed_file_diff, message}]} =
               ChangedFiles.validate([entry("lib/a.ex", %{"diff" => diff_of(501)})])

      assert message == "changed_files[0].diff exceeds the 500-line cap"
    end

    test "a trailing newline terminates rather than adds a line" do
      # 500 lines plus a trailing newline is still 500 lines, not 501.
      value = [entry("lib/a.ex", %{"diff" => diff_of(500) <> "\n"})]
      assert ChangedFiles.validate(value) == {:ok, value}
    end

    test "a non-string diff is rejected" do
      assert {:error, [{:changed_file_diff, message}]} =
               ChangedFiles.validate([entry("lib/a.ex", %{"diff" => 1})])

      assert message == "changed_files[0].diff must be a string"
    end
  end
end
