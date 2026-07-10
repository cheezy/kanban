defmodule Kanban.ChangedFiles.BackfillTest do
  use ExUnit.Case, async: true

  alias Kanban.ChangedFiles.Backfill
  alias KanbanWeb.API.ChangedFilesTransport

  describe "needs_backfill?/1" do
    test "true only for an empty changed_files (nil or [])" do
      assert Backfill.needs_backfill?(nil)
      assert Backfill.needs_backfill?([])
    end

    test "false when a changed_files value already exists (never overwrite)" do
      refute Backfill.needs_backfill?([%{"path" => "lib/a.ex", "diff" => "+ x"}])
      refute Backfill.needs_backfill?([%{"path" => "lib/a.ex"}])
    end
  end

  describe "build_entries/2" do
    test "maps each path through the diff_fun into a changed_files entry" do
      diff_fun = fn
        "lib/a.ex" -> {:ok, "+ added\n- removed\n"}
        "assets/logo.png" -> :binary
        "lib/gone.ex" -> :error
        "lib/empty.ex" -> {:ok, "   \n"}
      end

      entries =
        Backfill.build_entries(
          ["lib/a.ex", "assets/logo.png", "lib/gone.ex", "lib/empty.ex"],
          diff_fun
        )

      assert entries == [
               %{"path" => "lib/a.ex", "diff" => "+ added\n- removed\n"},
               %{"path" => "assets/logo.png", "diff" => Backfill.binary_placeholder()},
               # diff could not be computed → path-only entry, no "diff" key.
               %{"path" => "lib/gone.ex"},
               # empty/whitespace diff → path-only entry, not a blank diff.
               %{"path" => "lib/empty.ex"}
             ]
    end

    test "one entry per path, in order" do
      entries = Backfill.build_entries(["a", "b", "c"], fn _ -> :error end)
      assert Enum.map(entries, & &1["path"]) == ["a", "b", "c"]
    end
  end

  describe "truncate_diff/1" do
    test "leaves a diff at or under the cap unchanged" do
      diff = Enum.map_join(1..500, "\n", &"+ line #{&1}")
      assert Backfill.truncate_diff(diff) == diff
    end

    test "truncates an over-cap diff to exactly 500 lines ending with the marker" do
      diff = Enum.map_join(1..900, "\n", &"+ line #{&1}")

      truncated = Backfill.truncate_diff(diff)
      lines = String.split(truncated, "\n")

      assert length(lines) == 500
      assert List.last(lines) == Backfill.truncation_marker()
      # First 499 content lines are preserved.
      assert Enum.at(lines, 0) == "+ line 1"
      assert Enum.at(lines, 498) == "+ line 499"
    end
  end

  describe "encode_envelope/1 + transport round-trip" do
    test "produces a base64 envelope that decodes and validates back to the entries" do
      entries = [%{"path" => "lib/a.ex", "diff" => "+ added\n"}]
      envelope = Backfill.encode_envelope(entries)

      assert %{"encoding" => "base64", "data" => data} = envelope
      assert is_binary(data)

      # The real endpoint validator accepts the backfill's envelope unchanged —
      # no second validation path.
      assert {:ok, decoded} = ChangedFilesTransport.decode_and_validate_changed_files(envelope)
      assert decoded == entries
    end

    test "the transport validator refuses backfilled ../ traversal paths" do
      envelope = Backfill.encode_envelope([%{"path" => "../../etc/passwd", "diff" => "+ x\n"}])

      assert {:error, {:completion_validation_failed, _body}} =
               ChangedFilesTransport.decode_and_validate_changed_files(envelope)
    end

    test "the transport validator refuses backfilled absolute paths" do
      envelope = Backfill.encode_envelope([%{"path" => "/etc/passwd", "diff" => "+ x\n"}])

      assert {:error, {:completion_validation_failed, _body}} =
               ChangedFilesTransport.decode_and_validate_changed_files(envelope)
    end
  end
end
