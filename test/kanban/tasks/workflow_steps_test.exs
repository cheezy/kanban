defmodule Kanban.Tasks.WorkflowStepsTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.WorkflowSteps

  # A bare changeset over a schemaless map is enough: validate_shape/2 only ever
  # reads the params it is handed and adds errors to :workflow_steps.
  defp changeset do
    Ecto.Changeset.change({%{workflow_steps: []}, %{workflow_steps: {:array, :map}}})
  end

  defp validate(params), do: WorkflowSteps.validate_shape(changeset(), params)

  defp errors(cs), do: Enum.map(cs.errors, fn {field, {msg, _}} -> {field, msg} end)

  describe "skip_reason_codes/0" do
    test "is the six-value vocabulary derived from persisted data (D239)" do
      assert WorkflowSteps.skip_reason_codes() == [
               :decision_matrix_skip,
               :ran_inline,
               :hook_body_empty,
               :subsumed_by_task_spec,
               :folded_into_prior_step,
               :matrix_deviation
             ]
    end

    test "shares no value with the explorer/reviewer skip enum" do
      # The two vocabularies were derived for different decisions and cover
      # different phases. Overlap would mean one of them was reused rather than
      # derived, which the task explicitly warned against.
      codes = MapSet.new(WorkflowSteps.skip_reason_codes())
      explorer_reviewer = MapSet.new(Kanban.Tasks.CompletionValidation.skip_reasons())

      shared = MapSet.intersection(codes, explorer_reviewer)

      assert MapSet.size(shared) == 0
    end
  end

  describe "canonical_step_names/0" do
    test "lists the six steps in workflow order" do
      assert WorkflowSteps.canonical_step_names() == [
               "explorer",
               "planner",
               "implementation",
               "reviewer",
               "after_doing",
               "before_review"
             ]
    end
  end

  describe "validate_shape/2 — back-compat" do
    test "a nil param leaves the changeset untouched" do
      assert validate(%{}).errors == []
    end

    test "accepts a skipped step carrying only free-text prose, as agents wrote before D239" do
      params = %{
        "workflow_steps" => [
          %{
            "name" => "planner",
            "dispatched" => false,
            "reason" =>
              "Planned inline: the explorer returned a concrete two-site fix, so there was no design space left."
          }
        ]
      }

      assert validate(params).errors == []
    end

    test "accepts a dispatched step with duration_ms and no reason_code" do
      params = %{
        "workflow_steps" => [
          %{"name" => "explorer", "dispatched" => true, "duration_ms" => 12_450}
        ]
      }

      assert validate(params).errors == []
    end

    test "accepts a step whose name is not one of the six canonical values" do
      # Deliberately NOT constrained (D239): persisted data carries a second
      # step vocabulary from another runtime, and rejecting it would 422 that
      # runtime's completions mid-flight.
      params = %{
        "workflow_steps" => [
          %{"name" => "Implement", "dispatched" => true, "duration_ms" => 10}
        ]
      }

      assert validate(params).errors == []
    end
  end

  describe "validate_shape/2 — reason_code" do
    test "accepts every code in the canonical vocabulary" do
      for code <- WorkflowSteps.skip_reason_codes() do
        params = %{
          "workflow_steps" => [
            %{
              "name" => "planner",
              "dispatched" => false,
              "reason" => "prose",
              "reason_code" => to_string(code)
            }
          ]
        }

        assert validate(params).errors == [], "expected #{code} to be accepted"
      end
    end

    test "rejects an unrecognised code rather than silently dropping it" do
      params = %{
        "workflow_steps" => [
          %{
            "name" => "planner",
            "dispatched" => false,
            "reason" => "prose",
            "reason_code" => "because_i_felt_like_it"
          }
        ]
      }

      assert [{:workflow_steps, msg}] = errors(validate(params))
      assert msg =~ "reason_code must be one of"
      assert msg =~ "decision_matrix_skip"
    end

    test "rejects a code that is a known atom elsewhere but not in this enum" do
      # `small_task_0_1_key_files` is a real atom (the explorer/reviewer enum),
      # so String.to_existing_atom/1 succeeds and only the membership test
      # rejects it. This is the case a naive rescue-only guard would let through.
      params = %{
        "workflow_steps" => [
          %{
            "name" => "explorer",
            "dispatched" => false,
            "reason" => "prose",
            "reason_code" => "small_task_0_1_key_files"
          }
        ]
      }

      assert [{:workflow_steps, msg}] = errors(validate(params))
      assert msg =~ "reason_code must be one of"
    end

    test "an unrecognised code does not mint a new atom" do
      code = "d239_definitely_not_an_atom_yet"

      validate(%{
        "workflow_steps" => [
          %{"name" => "planner", "dispatched" => false, "reason" => "p", "reason_code" => code}
        ]
      })

      assert_raise ArgumentError, fn -> String.to_existing_atom(code) end
    end

    test "accepts an atom-keyed step with an atom reason_code" do
      params = %{
        "workflow_steps" => [
          %{name: "planner", dispatched: false, reason: "prose", reason_code: :ran_inline}
        ]
      }

      assert validate(params).errors == []
    end

    test "rejects a reason_code of the wrong type" do
      params = %{
        "workflow_steps" => [
          %{"name" => "planner", "dispatched" => false, "reason" => "p", "reason_code" => 42}
        ]
      }

      assert [{:workflow_steps, msg}] = errors(validate(params))
      assert msg =~ "reason_code must be one of"
    end
  end

  describe "validate_shape/2 — existing shape rules still hold" do
    test "rejects a non-list value" do
      assert [{:workflow_steps, "must be a list of step maps"}] =
               errors(validate(%{"workflow_steps" => "nope"}))
    end

    test "rejects a skipped step with no reason" do
      params = %{"workflow_steps" => [%{"name" => "planner", "dispatched" => false}]}
      assert [{:workflow_steps, msg}] = errors(validate(params))
      assert msg =~ "each entry must be a map"
    end

    test "rejects a dispatched step with no duration_ms" do
      params = %{"workflow_steps" => [%{"name" => "planner", "dispatched" => true}]}
      assert [{:workflow_steps, msg}] = errors(validate(params))
      assert msg =~ "each entry must be a map"
    end

    test "reports the shape error, not the reason_code error, when both are wrong" do
      # Shape is checked first so the message names the more fundamental
      # problem rather than a secondary one.
      params = %{
        "workflow_steps" => [
          %{"name" => "planner", "dispatched" => false, "reason_code" => "nonsense"}
        ]
      }

      assert [{:workflow_steps, msg}] = errors(validate(params))
      assert msg =~ "each entry must be a map"
    end
  end
end
