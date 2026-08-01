defmodule KanbanWeb.ReviewReportHelpers.ChangedFilesTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ReviewReportHelpers.ChangedFiles

  describe "changed_file_paths/1 (W1965)" do
    test "returns every entry's path, in stored order" do
      task = %{
        changed_files: [
          %{"path" => "lib/b.ex", "diff" => "+ one\n"},
          %{"path" => "lib/a.ex", "diff" => "+ two\n"},
          %{"path" => "test/a_test.exs"}
        ]
      }

      assert ChangedFiles.changed_file_paths(task) == [
               "lib/b.ex",
               "lib/a.ex",
               "test/a_test.exs"
             ]
    end

    test "drops entries whose path is missing, blank, or not a binary" do
      task = %{
        changed_files: [
          %{"path" => "lib/a.ex"},
          %{"path" => ""},
          %{"path" => nil},
          %{"diff" => "+ orphaned\n"},
          %{"path" => 42},
          "not a map",
          nil
        ]
      }

      assert ChangedFiles.changed_file_paths(task) == ["lib/a.ex"]
    end

    test "returns [] for nil, a non-list, or a task with no changed_files key" do
      assert ChangedFiles.changed_file_paths(%{changed_files: nil}) == []
      assert ChangedFiles.changed_file_paths(%{changed_files: "lib/a.ex"}) == []
      assert ChangedFiles.changed_file_paths(%{changed_files: []}) == []
      assert ChangedFiles.changed_file_paths(%{}) == []
      assert ChangedFiles.changed_file_paths(nil) == []
    end

    test "accepts an atom-keyed task map and atom-keyed entries" do
      assert ChangedFiles.changed_file_paths(%{"changed_files" => [%{"path" => "lib/a.ex"}]}) ==
               ["lib/a.ex"]

      assert ChangedFiles.changed_file_paths(%{changed_files: [%{path: "lib/b.ex"}]}) ==
               ["lib/b.ex"]
    end
  end

  describe "lookup_changed_file/2 (W1965)" do
    test "returns the whole matching entry, including diff and diff_url" do
      entry = %{
        "path" => "lib/a.ex",
        "diff" => "@@ -1 +1 @@\n-old\n+new",
        "diff_url" => "https://example.test/diff"
      }

      task = %{changed_files: [%{"path" => "lib/b.ex"}, entry]}

      assert ChangedFiles.lookup_changed_file(task, "lib/a.ex") == entry
    end

    test "returns nil for a path absent from the list — it never synthesizes a payload" do
      task = %{changed_files: [%{"path" => "lib/a.ex", "diff" => "+ x\n"}]}

      assert ChangedFiles.lookup_changed_file(task, "lib/ghost.ex") == nil
      assert ChangedFiles.lookup_changed_file(task, "") == nil
      assert ChangedFiles.lookup_changed_file(task, "../../etc/passwd") == nil
    end

    test "returns nil when changed_files is nil, empty, or not a list" do
      assert ChangedFiles.lookup_changed_file(%{changed_files: nil}, "lib/a.ex") == nil
      assert ChangedFiles.lookup_changed_file(%{changed_files: []}, "lib/a.ex") == nil
      assert ChangedFiles.lookup_changed_file(%{changed_files: "nope"}, "lib/a.ex") == nil
      assert ChangedFiles.lookup_changed_file(%{}, "lib/a.ex") == nil
      assert ChangedFiles.lookup_changed_file(nil, "lib/a.ex") == nil
    end

    test "returns nil for a non-binary path rather than raising" do
      task = %{changed_files: [%{"path" => "lib/a.ex"}]}

      assert ChangedFiles.lookup_changed_file(task, nil) == nil
      assert ChangedFiles.lookup_changed_file(task, 42) == nil
    end

    test "skips non-map entries without raising" do
      task = %{changed_files: ["lib/a.ex", nil, %{"path" => "lib/a.ex", "diff" => "+ x\n"}]}

      assert %{"path" => "lib/a.ex"} = ChangedFiles.lookup_changed_file(task, "lib/a.ex")
    end

    test "accepts a string-keyed task map and atom-keyed entries" do
      assert %{"path" => "lib/a.ex"} =
               ChangedFiles.lookup_changed_file(
                 %{"changed_files" => [%{"path" => "lib/a.ex"}]},
                 "lib/a.ex"
               )

      assert %{path: "lib/b.ex"} =
               ChangedFiles.lookup_changed_file(
                 %{changed_files: [%{path: "lib/b.ex"}]},
                 "lib/b.ex"
               )
    end
  end
end
