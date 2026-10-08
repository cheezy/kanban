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

  test "index/1 renders data and meta" do
    meta = %{limit: 50, has_more: false}

    assert %{data: [%{id: 1}], meta: ^meta} =
             TaskCommentJSON.index(%{comments: [comment(%{})], meta: meta})
  end
end
