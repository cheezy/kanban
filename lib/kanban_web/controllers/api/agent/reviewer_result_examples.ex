defmodule KanbanWeb.API.Agent.ReviewerResultExamples do
  @moduledoc """
  The two dispatched `reviewer_result` examples the onboarding `api_schema`
  serves as `reviewer_result_format.example` and `.structured_example`, split
  from `KanbanWeb.API.Agent.CompletionResultDoc` (D389) to keep that module
  under the size limit. Pure data.

  Agents copy these, so both must be payloads the server accepts: each carries
  every section the review contract requires, and
  `test/kanban_web/controllers/api/agent/schema_doc_test.exs` runs both through
  `KanbanWeb.API.CompletionResultGate.gate/2` in strict mode. Values are
  placeholders only — the onboarding endpoint is public.
  """

  @doc "A passing dispatched review for a project with no CODE-REVIEW.md."
  def approved do
    %{
      dispatched: true,
      summary:
        "Reviewed the diff against both acceptance criteria, the task's pitfalls and its patterns; nothing to fix.",
      duration_ms: 8_000,
      acceptance_criteria_checked: 2,
      issues_found: 0,
      schema_version: "1.5",
      status: "approved",
      issue_counts: %{critical: 0, important: 0, minor: 0},
      issues: [],
      acceptance_criteria: [
        %{criterion: "Validator accepts arrays", status: "met", evidence: "test/foo_test.exs:12"},
        %{criterion: "Status enum enforced", status: "met", evidence: "test/foo_test.exs:30"}
      ],
      project_checks: [],
      testing_strategy: %{status: "passed", note: "Both listed unit tests are present."},
      patterns: %{status: "passed"},
      pitfalls: %{status: "passed"},
      security_considerations: %{
        status: "passed",
        note: "Board-scoped query; no new input surface."
      }
    }
  end

  @doc """
  A dispatched review that found problems, with a project checklist and a
  security breakdown. Every `not_met` verdict and `failed` section has its
  paired issue.
  """
  def changes_requested do
    %{
      dispatched: true,
      summary:
        "Reviewed against 2 acceptance criteria and 5 pitfalls; one criterion unmet and one pattern deviation surfaced.",
      duration_ms: 8_000,
      acceptance_criteria_checked: 2,
      issues_found: 2,
      schema_version: "1.5",
      status: "changes_requested",
      issue_counts: %{critical: 0, important: 2, minor: 0},
      issues: [
        %{
          severity: "important",
          category: "pattern",
          file: "lib/kanban/tasks/agent_workflow.ex",
          line: 528,
          description: "Cast list omits the new field — payload would be silently dropped.",
          suggested_fix: "Add the field to the cast/2 list and the changeset validation."
        },
        %{
          severity: "important",
          category: "acceptance_criteria",
          file: "test/kanban/tasks_test.exs",
          description: "No test covers the status enum.",
          suggested_fix: "Add a case that sends an unknown status and expects a 422."
        }
      ],
      acceptance_criteria: [
        %{criterion: "Validator accepts arrays", status: "met", evidence: "test/foo_test.exs:12"},
        %{criterion: "Status enum enforced", status: "not_met", evidence: "See issues[1]"}
      ],
      project_checks: [
        %{
          check: "Every new public function has a unit test",
          source: "CODE-REVIEW.md",
          status: "met",
          evidence: "test/kanban/tasks_test.exs:88"
        }
      ],
      testing_strategy: %{
        status: "passed",
        note: "All 5 required test cases present in the new describe block."
      },
      patterns: %{
        status: "failed",
        note: "The cast list skips the new field, so the changeset drops it (issues[0])."
      },
      pitfalls: %{status: "passed", note: "None violated."},
      security_considerations: %{
        status: "passed",
        note: "Board-scoped query; no new input surface.",
        considerations: [
          %{
            consideration: "Move query scoped to the requesting user's board",
            status: "mitigated",
            evidence: "lib/kanban/tasks.ex:142",
            note: "Query filters by current_scope.user.id."
          }
        ]
      }
    }
  end
end
