defmodule KanbanWeb.API.TaskCommentJSONTest do
  use ExUnit.Case, async: true

  alias Kanban.Accounts.User
  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.API.TaskCommentJSON

  defp comment(attrs) do
    attrs = Map.merge(%{id: 1, task_id: 2, content: "Hi"}, attrs)
    struct(TaskComment, attrs)
  end

  defp author_name(attrs),
    do: attrs |> comment() |> TaskCommentJSON.comment() |> Map.get(:author_name)

  describe "comment/1 author_name" do
    test "is the author's name" do
      assert author_name(%{author: %User{name: "Ann", email: "a@x"}}) == "Ann"
    end

    test "falls back to the author's email when the name is blank" do
      for name <- [nil, ""] do
        assert author_name(%{author: %User{name: name, email: "a@x"}}) == "a@x"
      end
    end

    test "is Unknown for a comment with no author" do
      assert author_name(%{author: nil}) == "Unknown"
      assert author_name(%{}) == "Unknown"
    end
  end

  describe "comment/1 timestamps" do
    test "renders naive inserted_at and updated_at as DateTimes in Etc/UTC" do
      rendered =
        %{inserted_at: ~N[2026-10-07 15:40:52], updated_at: ~N[2026-10-07 15:41:03]}
        |> comment()
        |> TaskCommentJSON.comment()

      assert rendered.inserted_at == ~U[2026-10-07 15:40:52Z]
      assert rendered.updated_at == ~U[2026-10-07 15:41:03Z]
      assert rendered.inserted_at.time_zone == "Etc/UTC"
    end

    test "the JSON-encoded inserted_at and updated_at end in Z" do
      encoded =
        %{inserted_at: ~N[2026-10-07 15:40:52], updated_at: ~N[2026-10-07 15:40:52]}
        |> comment()
        |> TaskCommentJSON.comment()
        |> Jason.encode!()
        |> Jason.decode!()

      assert encoded["inserted_at"] == "2026-10-07T15:40:52Z"
      assert encoded["updated_at"] == "2026-10-07T15:40:52Z"
    end

    test "passes a DateTime through unchanged" do
      rendered =
        %{inserted_at: ~U[2026-11-20 09:00:00Z], updated_at: ~U[2026-11-20 09:00:00Z]}
        |> comment()
        |> TaskCommentJSON.comment()

      assert rendered.inserted_at == ~U[2026-11-20 09:00:00Z]
      assert rendered.updated_at == ~U[2026-11-20 09:00:00Z]
    end

    test "leaves nil timestamps nil, and a never-edited comment keeps edited_at nil" do
      rendered = %{} |> comment() |> TaskCommentJSON.comment()

      assert rendered.inserted_at == nil
      assert rendered.updated_at == nil
      assert rendered.edited_at == nil
    end
  end

  test "index/1 renders data and meta" do
    meta = %{limit: 50, has_more: false}

    assert %{data: [%{id: 1}], meta: ^meta} =
             TaskCommentJSON.index(%{comments: [comment(%{})], meta: meta})
  end
end
