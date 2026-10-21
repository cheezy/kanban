defmodule Kanban.Workspaces.Export.Importer.RepairsTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.TaskComment
  alias Kanban.Workspaces.Export.Importer.Repairs

  @max TaskComment.content_max_length()

  describe "comment_content/1" do
    test "leaves a comment at the cap unchanged" do
      content = String.duplicate("x", @max)
      assert Repairs.comment_content(content) == {content, :ok}
    end

    test "shortens a longer comment to the cap and reports its length" do
      content = String.duplicate("ab", @max)

      assert {shortened, {:shortened, length}} = Repairs.comment_content(content)
      assert length == 2 * @max
      assert String.length(shortened) == @max
      assert String.starts_with?(content, shortened)
    end

    test "counts codepoints, as the comment changeset does" do
      # "é" written as e + combining accent: one grapheme, two codepoints.
      content = String.duplicate("é", div(@max, 2) + 1)

      assert {shortened, {:shortened, length}} = Repairs.comment_content(content)
      assert length == @max + 2
      assert shortened |> String.codepoints() |> length() == @max
      assert %Ecto.Changeset{valid?: true} = comment_changeset(shortened)
    end

    test "leaves text that is not valid UTF-8 for the changeset to refuse" do
      content = String.duplicate("x", @max) <> <<0xFF>>
      assert Repairs.comment_content(content) == {content, :ok}
    end

    test "leaves anything that is not a string unchanged" do
      for value <- [nil, 42, ["x"], %{"x" => 1}] do
        assert Repairs.comment_content(value) == {value, :ok}
      end
    end
  end

  describe "capabilities/1" do
    test "keeps a list of known capabilities as it is" do
      assert Repairs.capabilities(["testing", "code_review"]) == {["testing", "code_review"], 0}
      assert Repairs.capabilities([]) == {[], 0}
    end

    test "drops unknown capabilities, keeping the others in order" do
      assert Repairs.capabilities(["pubsub", "testing", "forms", "git"]) ==
               {["testing", "git"], 2}

      assert Repairs.capabilities(["pubsub_integration"]) == {[], 1}
    end

    test "leaves anything other than a list of strings unchanged" do
      for value <- [nil, "testing", ["testing", 1], %{"a" => "testing"}] do
        assert Repairs.capabilities(value) == {value, 0}
      end
    end
  end

  defp comment_changeset(content),
    do: TaskComment.changeset(%TaskComment{task_id: 1}, %{"content" => content})
end
