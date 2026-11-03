defmodule KanbanWeb.API.TaskAttachmentJSONTest do
  @moduledoc """
  The eight-key attachment object (W2516) and the `TaskJSON.show/1` clauses
  that carry it in `data.attachments`.
  """
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.API.TaskAttachmentJSON
  alias KanbanWeb.API.TaskJSON

  @keys ~w(id filename content_type byte_size sha256 comment_id uploaded_at download_url)a

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    task = task_fixture(column)
    %{user: user, task: task}
  end

  defp comment_fixture(task),
    do: Repo.insert!(%TaskComment{task_id: task.id, content: "See the log"})

  describe "attachment/1" do
    test "renders exactly the eight contract keys", %{task: task} do
      rendered = task |> attachment_fixture() |> TaskAttachmentJSON.attachment()

      assert rendered |> Map.keys() |> Enum.sort() == Enum.sort(@keys)
    end

    test "comment_id is null for a task-level attachment and the comment id otherwise", %{
      task: task
    } do
      comment = comment_fixture(task)
      task_level = attachment_fixture(task)
      on_comment = attachment_fixture(task, %{comment: comment})

      assert TaskAttachmentJSON.attachment(task_level).comment_id == nil
      assert TaskAttachmentJSON.attachment(on_comment).comment_id == comment.id
    end

    test "equal uploaded_at values are ordered by id in the view loaders", %{task: task} do
      same = ~N[2026-01-01 00:00:00]
      first = attachment_fixture(task, %{inserted_at: same, updated_at: same})
      second = attachment_fixture(task, %{inserted_at: same, updated_at: same})
      oldest = attachment_fixture(task, %{inserted_at: ~N[2025-12-31 23:59:59]})

      # Rewriting `first` moves its row behind `second` on disk, so an
      # unordered or inserted_at-only read would tend to return it last.
      {1, _} =
        TaskAttachment
        |> where([a], a.id == ^first.id)
        |> Repo.update_all(set: [filename: first.filename])

      expected = [oldest.id, first.id, second.id]

      assert Enum.map(Tasks.get_task_for_view!(task.id).attachments, & &1.id) == expected
      assert Enum.map(Tasks.get_task_for_view(task.id).attachments, & &1.id) == expected

      by_identifier =
        Tasks.get_task_by_identifier_for_view(task.identifier, [task.column_id])

      assert Enum.map(by_identifier.attachments, & &1.id) == expected
    end

    test "renders sha256 as lowercase hex, byte_size as an integer and uploaded_at as ISO 8601 UTC",
         %{task: task} do
      attachment =
        attachment_fixture(task, %{byte_size: 2048, inserted_at: ~N[2026-11-01 09:30:05]})

      rendered = TaskAttachmentJSON.attachment(attachment)

      assert rendered.sha256 =~ ~r/\A[0-9a-f]{64}\z/
      assert rendered.byte_size == 2048
      assert rendered.uploaded_at == "2026-11-01T09:30:05Z"
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(rendered.uploaded_at)
    end

    test "download_url is /api/tasks/<task id>/attachments/<id> built from integer ids", %{
      task: task
    } do
      attachment = attachment_fixture(task, %{filename: "../../etc/passwd.txt"})
      rendered = TaskAttachmentJSON.attachment(attachment)

      assert rendered.download_url == "/api/tasks/#{task.id}/attachments/#{attachment.id}"
      refute rendered.download_url =~ task.identifier
      refute rendered.download_url =~ "passwd"
    end

    test "never renders storage keys or uploader fields", %{task: task, user: user} do
      attachment = attachment_fixture(task, %{uploaded_by: user})
      rendered = TaskAttachmentJSON.attachment(attachment)
      encoded = Jason.encode!(rendered)

      for key <- [:storage_key, :uploaded_by, :uploaded_by_id, :task_id, :updated_at] do
        refute Map.has_key?(rendered, key), "rendered #{key}"
      end

      refute encoded =~ attachment.storage_key
      refute encoded =~ user.email
    end

    test "attachments/1 keeps the given order", %{task: task} do
      a = attachment_fixture(task)
      b = attachment_fixture(task)

      assert [b, a] |> TaskAttachmentJSON.attachments() |> Enum.map(& &1.id) == [b.id, a.id]
      assert TaskAttachmentJSON.attachments([]) == []
    end
  end

  describe "TaskJSON.show/1" do
    test "TaskJSON.show/1 adds data.attachments only when the attachments assign is threaded",
         %{task: task} do
      attachment = attachment_fixture(task)
      expected = [TaskAttachmentJSON.attachment(attachment)]

      full = TaskJSON.show(%{task: task, attachments: [attachment]})
      assert full.data.attachments == expected
      refute Map.has_key?(full, :attachments)

      claim = TaskJSON.show(%{task: task, hook: %{}, attachments: [attachment]})
      assert claim.data.attachments == expected

      assert TaskJSON.show(%{task: task, attachments: []}).data.attachments == []

      refute Map.has_key?(TaskJSON.show(%{task: task}).data, :attachments)
      refute Map.has_key?(TaskJSON.show(%{task: task, hook: %{}}).data, :attachments)
    end

    test "slim, fields and complete views never carry it", %{task: task} do
      assigns = %{task: task, attachments: [attachment_fixture(task)]}

      for {key, value} <- [response_view: :slim, fields: ["title"], hooks: []] do
        body = assigns |> Map.put(key, value) |> TaskJSON.show()
        refute Map.has_key?(body.data, :attachments), "#{key} view carried attachments"
        refute Map.has_key?(body.data, "attachments"), "#{key} view carried attachments"
        refute Map.has_key?(body, :attachments), "#{key} view carried attachments"
      end
    end
  end
end
