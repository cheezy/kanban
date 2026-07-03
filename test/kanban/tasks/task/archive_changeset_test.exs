defmodule Kanban.Tasks.Task.ArchiveChangesetTest do
  @moduledoc """
  Unit tests for the extracted archive changeset (W1445). The end-to-end archive
  path is covered by task_test.exs and tasks_test.exs; these lock the four
  archive-reason rules directly, including verbatim error strings.
  """
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.Task.ArchiveChangeset

  describe "changeset/2 archive-reason rules" do
    test "requires archive_note for :wontdo" do
      result = ArchiveChangeset.changeset(%Task{}, %{"archive_reason" => "wontdo"})

      assert {"must be set when archive_reason is :wontdo, :deferred, or :cancelled", _} =
               result.errors[:archive_note]
    end

    test "treats a whitespace-only archive_note as missing" do
      result =
        ArchiveChangeset.changeset(%Task{}, %{
          "archive_reason" => "deferred",
          "archive_note" => "   "
        })

      assert {"must be set when archive_reason is :wontdo, :deferred, or :cancelled", _} =
               result.errors[:archive_note]
    end

    test "requires duplicate_of_id for :duplicate" do
      result = ArchiveChangeset.changeset(%Task{}, %{"archive_reason" => "duplicate"})

      assert {"must be set when archive_reason is :duplicate", _} =
               result.errors[:duplicate_of_id]
    end

    test "forbids duplicate_of_id for a non-:duplicate reason" do
      result =
        ArchiveChangeset.changeset(%Task{}, %{
          "archive_reason" => "completed",
          "duplicate_of_id" => 5
        })

      assert {"may only be set when archive_reason is :duplicate", _} =
               result.errors[:duplicate_of_id]
    end
  end

  describe "validate_archive_fields/1" do
    test "passes :completed with no extra fields (public helper reused by Task.changeset/2)" do
      result =
        %Task{archive_reason: :completed}
        |> Changeset.change()
        |> ArchiveChangeset.validate_archive_fields()

      assert result.errors == []
    end
  end
end
