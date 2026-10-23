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
  alias KanbanWeb.API.CompletionResultGate
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

  # D389: agents build their /complete payload from the served api_schema, so
  # every example it serves has to be one the server accepts. These run the
  # examples through the real gate in strict mode, the production default, after
  # a JSON round trip, which is the form an agent actually sends.
  describe "documented completion examples pass the gate" do
    # A task that supplies the sections the cross-checks compare against, so
    # the examples are checked against a task, not only structurally.
    @task %{
      acceptance_criteria: "Validator accepts arrays\nStatus enum enforced",
      security_considerations: ["Move query scoped to the requesting user's board"],
      testing_strategy: %{"unit_tests" => ["Validator accepts arrays"]}
    }

    defp served(path), do: SchemaDoc.schema() |> get_in(path) |> as_json()

    defp as_json(term), do: term |> Jason.encode!() |> Jason.decode!()

    defp gate(reviewer, task) do
      explorer = served([:explorer_result_format, :example])

      CompletionResultGate.gate(
        %{"explorer_result" => explorer, "reviewer_result" => reviewer},
        strict: true,
        task: task
      )
    end

    test "structured reviewer_result example passes the gate" do
      structured = served([:reviewer_result_format, :structured_example])

      assert structured["project_checks"] != []
      assert gate(structured, @task) == :ok
      assert gate(structured, nil) == :ok

      # A project with no CODE-REVIEW.md sends project_checks: [] — still valid.
      assert gate(Map.put(structured, "project_checks", []), @task) == :ok
    end

    test "the plain reviewer_result example is a full review with project_checks: []" do
      example = served([:reviewer_result_format, :example])

      assert example["project_checks"] == []
      assert gate(example, @task) == :ok
    end

    @tag :capture_log
    test "the gate is live: an example without project_checks is rejected in every mode" do
      structured = served([:reviewer_result_format, :structured_example])
      thin = Map.delete(structured, "project_checks")

      for strict <- [true, false] do
        assert {:reject, body} =
                 CompletionResultGate.gate(
                   %{
                     "explorer_result" => served([:explorer_result_format, :example]),
                     "reviewer_result" => thin
                   },
                   strict: strict
                 )

        [failure] = Enum.filter(body.failures, &(&1.field == "reviewer_result"))
        assert Enum.any?(failure.errors, &(&1.field == "project_checks"))
      end
    end

    test "the skip_form example needs no structured block" do
      skip = served([:reviewer_result_format, :skip_form, :example])

      assert skip["dispatched"] == false
      refute Map.has_key?(skip, "project_checks")
      assert gate(skip, @task) == :ok
    end
  end

  describe "reviewer_result_format required sections" do
    defp required_sections,
      do: Enum.map(CompletionValidation.required_review_sections(), &Atom.to_string/1)

    test "required_sections is the review contract's list" do
      format = SchemaDoc.schema().reviewer_result_format

      assert format.required_sections == required_sections()
      assert format.required_one_of == ["status", "issue_counts"]
    end

    test "every required section is documented as required" do
      fields = SchemaDoc.schema().reviewer_result_format.structured_fields

      for section <- required_sections() do
        node = Map.fetch!(fields, String.to_existing_atom(section))
        assert node.required == true, "structured_fields.#{section} is not marked required"
      end
    end

    test "the text says a dispatched review needs the full block in every mode" do
      format = SchemaDoc.schema().reviewer_result_format

      assert format.description =~ "in every validation mode"
      assert format.backwards_compatibility =~ "REJECTED with HTTP 422 in every mode"
      assert format.structured_fields.description =~ "Required on a dispatched review"

      for section <- required_sections(), do: assert(format.description =~ section)
    end
  end

  describe "validation_modes" do
    test "names strict as the production default and lists what always rejects" do
      modes = SchemaDoc.schema().validation_modes

      assert modes.description =~ "Strict is the production default"
      assert modes.strict.intended_for =~ "Production, where it is the default"
      refute modes.grace.behavior =~ "Default rollout mode"

      # The gate grace-gates changed_files shape too (CompletionResultGate).
      assert modes.grace.behavior =~ "changed_files"
      assert modes.strict.behavior =~ "changed_files"
      assert Enum.any?(modes.always_rejected, &(&1 =~ "dispatched reviewer_result"))
      assert Enum.any?(modes.always_rejected, &(&1 =~ "malformed"))
    end

    test "no served text calls the legacy payload valid or grace the default" do
      text = SchemaDoc.schema() |> Jason.encode!()

      for stale <- [
            "fully valid",
            "All optional",
            "Default rollout mode",
            "Older clients operate"
          ] do
        refute text =~ stale, "api_schema still says #{inspect(stale)}"
      end
    end
  end

  describe "claim_task request format" do
    test "only before_doing_result is required; identifier and agent_name are optional" do
      claim = SchemaDoc.schema().request_formats.claim_task

      assert Map.keys(claim.required_body) == [:before_doing_result]
      assert Map.has_key?(claim.optional_body, :identifier)
      assert Map.has_key?(claim.optional_body, :agent_name)
    end
  end
end
