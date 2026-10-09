defmodule Kanban.Webhooks.PayloadTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Webhooks.Payload

  setup do
    board = ai_optimized_board_fixture(user_fixture(), %{name: "Roadmap"})
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    %{board: board, cols: cols, task: task_fixture(cols["Doing"], %{title: "Ship it"})}
  end

  test "build/2 returns the envelope with board and task", ctx do
    assert {:ok, envelope} = Payload.build("task.updated", ctx.task)

    assert %{
             "id" => "evt_" <> _,
             "version" => 1,
             "event" => "task.updated",
             "occurred_at" => occurred_at,
             "board" => %{"id" => board_id, "name" => "Roadmap", "url" => board_url},
             "task" => task
           } = envelope

    assert {:ok, _, 0} = DateTime.from_iso8601(occurred_at)
    assert board_id == ctx.board.id
    assert board_url == KanbanWeb.Endpoint.url() <> "/boards/#{ctx.board.id}"
    assert task["identifier"] == ctx.task.identifier
    assert task["title"] == "Ship it"
    assert task["column"] == %{"id" => ctx.cols["Doing"].id, "name" => "Doing"}
    assert task["url"] == board_url <> "/tasks/#{ctx.task.id}/edit"
  end

  test "the task part carries only the allow-listed fields", ctx do
    {:ok, task} =
      ctx.task
      |> Ecto.Changeset.change(%{
        description: "private description",
        completion_notes: "private notes",
        completion_summary: "private summary",
        review_notes: "private review"
      })
      |> Repo.update()

    {:ok, %{"task" => data}} = Payload.build("task.updated", task)

    assert Map.keys(data) |> Enum.sort() ==
             Enum.sort(["column", "url" | Enum.map(Payload.task_fields(), &Atom.to_string/1)])

    refute data |> Jason.encode!() |> String.contains?("private")
  end

  test "enums become strings and timestamps ISO8601 UTC", ctx do
    claimed_at = ~U[2026-10-09 12:00:00Z]
    {:ok, task} = ctx.task |> Ecto.Changeset.change(claimed_at: claimed_at) |> Repo.update()

    {:ok, %{"task" => data}} = Payload.build("task.claimed", task)

    assert data["type"] == "work"
    assert data["priority"] == Atom.to_string(task.priority)
    assert data["needs_review"] == task.needs_review
    assert data["claimed_at"] == "2026-10-09T12:00:00Z"
    assert data["review_status"] == nil
    assert {:ok, _, 0} = DateTime.from_iso8601(data["inserted_at"])
  end

  test "a moved task whose preloaded column is stale reports its current column", ctx do
    stale = Repo.preload(ctx.task, :column)
    assert stale.column.name == "Doing"

    {:ok, %{"task" => data}} =
      Payload.build("task.moved", %{stale | column_id: ctx.cols["Done"].id})

    assert data["column"]["name"] == "Done"
  end

  test "a task that is not on a board is {:error, :no_column}", ctx do
    assert Payload.build("task.updated", %{ctx.task | column_id: nil, column: nil}) ==
             {:error, :no_column}
  end

  test "ping/1 describes the board with no task", ctx do
    assert %{"event" => "ping", "task" => nil, "board" => %{"name" => "Roadmap"}} =
             Payload.ping(ctx.board)
  end

  test "board_url/1 takes a board or an id", ctx do
    assert Payload.board_url(ctx.board) == Payload.board_url(ctx.board.id)
  end
end
