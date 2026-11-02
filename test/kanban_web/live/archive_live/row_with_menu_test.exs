defmodule KanbanWeb.ArchiveLive.RowWithMenuTest do
  use Kanban.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Tasks.Task
  alias KanbanWeb.ArchiveLive.RowWithMenu

  defp task, do: %Task{id: 7, identifier: "W7", title: "Old work", type: :work}

  defp file(id, name),
    do: %TaskAttachment{
      id: id,
      task_id: 7,
      filename: name,
      content_type: "text/plain",
      byte_size: 2048,
      inserted_at: ~N[2026-10-01 10:00:00]
    }

  defp render_row(attachments),
    do: render_component(&RowWithMenu.row_with_menu/1, task: task(), attachments: attachments)

  test "renders no file list when the task has no files" do
    html = render_row([])
    assert html =~ "Old work"
    refute html =~ "archive-files-7"
  end

  test "lists the files read-only, with a download link and a pluralised count" do
    html = render_row([file(1, "a.txt"), file(2, "b.txt")])

    assert html =~ ~s(id="archive-files-7")
    assert html =~ "2 files"
    assert html =~ "/attachments/1/download"
    assert html =~ "Download b.txt"
    refute html =~ "Delete a.txt"
  end

  test "the count is translated" do
    Gettext.with_locale(KanbanWeb.Gettext, "de", fn ->
      assert render_row([file(1, "a.txt")]) =~ "1 Datei"
    end)
  end
end
