defmodule KanbanWeb.API.Agent.SchemaDocTest do
  @moduledoc """
  Cross-surface drift guard for the reviewer **issue-category** enum (W1940).

  Four surfaces restate the `reviewer_result.issues[].category` values by hand
  instead of deriving them: the published API schema, the 422 error docs, and
  the two markdown API references. Before W1940 they had already drifted — the
  schema published five values while separately instructing clients to send
  `category: security`, a value the validator rejected with a hard 422.

  Every assertion here anchors on `CompletionValidation.issue_categories/0` so
  the source of truth stays the validator, never a literal duplicated into a
  test.

  Note: this is the *issue* category enum. It is unrelated to
  `Kanban.Schemas.Task.BehaviourTestRow.categories/0`, which is a coincidentally
  also-seven-value taxonomy ("Happy path", "Boundary", ...) for behaviour-test
  matrix rows and collides with this one in grep results.
  """
  use ExUnit.Case, async: true

  alias Kanban.Tasks.CompletionValidation
  alias KanbanWeb.API.Agent.SchemaDoc
  alias KanbanWeb.API.ErrorDocs

  defp category_node do
    SchemaDoc.schema()
    |> get_in([:reviewer_result_format, :structured_fields, :issues, :entry_fields, :category])
  end

  describe "issue-category enum publication" do
    test "publishes all seven issue categories, in the validator's order" do
      expected = Enum.map(CompletionValidation.issue_categories(), &to_string/1)

      assert length(expected) == 7
      assert category_node()[:values] == expected
    end

    test "no longer describes the category list as five" do
      refute category_node()[:description] =~ ~r/\bfive\b/i
    end

    test "the 422 error docs name the same seven categories" do
      cause =
        ErrorDocs.get_docs(:completion_validation_failed, [])
        |> Map.fetch!(:common_causes)
        |> Enum.find(&(&1 =~ "missing severity or category"))

      assert cause, "expected a common_causes entry describing the issues[] enum"

      for category <- CompletionValidation.issue_categories() do
        assert cause =~ to_string(category),
               "422 error docs omit the #{category} issue category"
      end
    end

    test "the markdown API references name the same seven categories" do
      for doc <- ["docs/api/README.md", "docs/api/patch_tasks_id_complete.md"] do
        contents = File.cwd!() |> Path.join(doc) |> File.read!()

        for category <- CompletionValidation.issue_categories() do
          assert contents =~ to_string(category),
                 "#{doc} omits the #{category} issue category"
        end

        refute contents =~ "acceptance_criteria|pitfall|pattern|testing|code_quality",
               "#{doc} still publishes the old five-value pipe list"

        refute contents =~ "`testing`, `code_quality` |",
               "#{doc} still publishes the old five-value table row"
      end
    end
  end
end
