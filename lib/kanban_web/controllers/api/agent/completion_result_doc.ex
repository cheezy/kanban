defmodule KanbanWeb.API.Agent.CompletionResultDoc do
  @moduledoc """
  The `explorer_result_format`, `reviewer_result_format` and `validation_modes`
  blocks of the onboarding `api_schema`, extracted from
  `KanbanWeb.API.Agent.SchemaDoc` (D389) to keep that module under the size
  limit. Pure data, composed unchanged into `SchemaDoc.schema/0`.

  Agents build their `PATCH /api/tasks/:id/complete` payload from this text, so
  it has to describe what the server accepts, not what it once accepted. Two
  rules keep it honest:

    * The sections a dispatched review must carry come from
      `Kanban.Tasks.CompletionValidation.required_review_sections/0`, the
      review contract's own list, rather than being retyped here. A section
      added to the contract shows up as required here without an edit.
    * Both reviewer examples are tested to pass
      `KanbanWeb.API.CompletionResultGate.gate/2` in strict mode
      (`test/kanban_web/controllers/api/agent/schema_doc_test.exs`). An example
      the gate rejects fails the build.
  """

  alias Kanban.Tasks.CompletionValidation
  alias KanbanWeb.API.Agent.ReviewerResultExamples

  @doc """
  The structured sections a dispatched `reviewer_result` must carry, as strings,
  in the review contract's order.
  """
  def required_review_sections do
    Enum.map(CompletionValidation.required_review_sections(), &Atom.to_string/1)
  end

  @doc "The `explorer_result_format` block of the onboarding `api_schema`."
  def explorer_result_format do
    %{
      description:
        "Required format for explorer_result on /complete. Two accepted shapes: dispatched (subagent ran) or skip_form (not dispatched).",
      dispatched_fields: %{
        dispatched: %{type: "boolean", required: true, description: "true for this shape"},
        summary: %{
          type: "string",
          required: true,
          description:
            "What the exploration covered. Must contain at least 40 non-whitespace characters."
        },
        duration_ms: %{
          type: "integer",
          required: true,
          description: "Wall-clock time the exploration took, in milliseconds (non-negative)"
        }
      },
      skip_form: %{
        description: "Use when exploration was skipped or self-reported.",
        fields: %{
          dispatched: %{type: "boolean", required: true, description: "false for this shape"},
          reason: %{
            type: "enum",
            required: true,
            values: [
              "no_subagent_support",
              "small_task_0_1_key_files",
              "trivial_change_docs_only",
              "self_reported_exploration",
              "self_reported_review"
            ]
          },
          summary: %{
            type: "string",
            required: true,
            description:
              "Substantive explanation of what was done instead. At least 40 non-whitespace characters."
          }
        },
        example: %{
          dispatched: false,
          reason: "no_subagent_support",
          summary:
            "Read lib/foo.ex and test/foo_test.exs inline; identified the existing error-tuple pattern to mirror."
        }
      },
      example: %{
        dispatched: true,
        summary: "Explored 3 key_files and identified the existing pattern to mirror",
        duration_ms: 12_000
      }
    }
  end

  @doc "The `reviewer_result_format` block of the onboarding `api_schema`."
  def reviewer_result_format do
    sections = required_review_sections()

    %{
      description:
        "Required format for reviewer_result on /complete. Two accepted shapes: dispatched (subagent ran) or skip_form (not dispatched). " <>
          "A dispatched review (dispatched: true) MUST carry the full structured block in every validation mode, grace included: " <>
          "the five dispatched_fields, every section in required_sections (#{Enum.join(sections, ", ")}), and status or issue_counts. " <>
          "A dispatched review missing any of them is rejected with HTTP 422. The security_considerations verdict may also carry an optional considerations[] mitigation breakdown. " <>
          "The skip_form (dispatched: false) carries no structured block. " <>
          "The canonical schema of record lives in the stride plugin repo at stride/agents/task-reviewer.md; this documentation mirrors what the server validator (Kanban.Tasks.CompletionValidation) accepts.",
      required_sections: sections,
      required_one_of: ["status", "issue_counts"],
      backwards_compatibility:
        "A legacy summary-only dispatched payload (the five dispatched_fields without the structured block) is REJECTED with HTTP 422 in every mode. " <>
          "Only the skip_form omits the structured block. Unknown nested fields inside any entry are tolerated for forward compatibility.",
      dispatched_fields: dispatched_fields(),
      structured_fields: structured_fields(sections),
      skip_form: %{
        description:
          "Same skip shape as explorer_result. Use when review was skipped or self-reported. It needs no structured block. See explorer_result_format.skip_form for field details and enum values.",
        example: %{
          dispatched: false,
          reason: "self_reported_review",
          summary:
            "Walked the diff against all 5 acceptance criteria and 3 pitfalls; confirmed each criterion met and no pitfall hit."
        }
      },
      example: ReviewerResultExamples.approved(),
      structured_example: ReviewerResultExamples.changes_requested()
    }
  end

  @doc "The `validation_modes` block of the onboarding `api_schema`."
  def validation_modes do
    %{
      description:
        "Completion validation runs in one of two modes, controlled by the :strict_completion_validation application flag " <>
          "(the STRIDE_STRICT_COMPLETION_VALIDATION environment variable). Strict is the production default; development and test default to grace. " <>
          "Some rules reject with HTTP 422 in BOTH modes: a dispatched reviewer_result without the full structured block, " <>
          "a present but malformed explorer_result or reviewer_result, and a missing or failing hook result. " <>
          "The flag decides the rest: an absent explorer_result or reviewer_result, a malformed optional changed_files array, and two consistency checks. " <>
          "workflow_steps is telemetry: cast onto the task struct but not rejected when absent.",
      always_rejected: [
        "A dispatched reviewer_result missing any required_sections entry, or missing both status and issue_counts",
        "A present explorer_result or reviewer_result that is malformed (wrong shape, bad enum value, short summary)",
        "A missing, malformed or non-zero after_doing_result or before_review_result"
      ],
      grace: %{
        flag: ":strict_completion_validation = false",
        behavior:
          "An absent explorer_result or reviewer_result, a malformed changed_files array, and the acceptance-criteria count and " <>
            "security-breakdown consistency checks log a structured warning and the request succeeds. Everything in always_rejected still returns 422.",
        intended_for:
          "Development and test, or a deployment that sets STRIDE_STRICT_COMPLETION_VALIDATION=false."
      },
      strict: %{
        flag: ":strict_completion_validation = true",
        behavior:
          "An absent explorer_result or reviewer_result, a malformed changed_files array, and a failed consistency check are also rejected with HTTP 422 and a failures list. Skip forms must include a valid reason.",
        intended_for: "Production, where it is the default; enforces task-quality contracts."
      },
      example_rejection: %{
        status: 422,
        error: "completion validation failed",
        failures: [
          %{
            field: "explorer_result",
            errors: [
              %{
                field: "summary",
                message: "must be a string of at least 40 non-whitespace characters"
              }
            ]
          }
        ]
      }
    }
  end

  defp dispatched_fields do
    %{
      dispatched: %{type: "boolean", required: true, description: "true for this shape"},
      summary: %{
        type: "string",
        required: true,
        description:
          "What the review covered. Must contain at least 40 non-whitespace characters."
      },
      duration_ms: %{
        type: "integer",
        required: true,
        description: "Wall-clock time the review took, in milliseconds (non-negative)"
      },
      acceptance_criteria_checked: %{
        type: "integer",
        required: true,
        description:
          "Count of acceptance criteria lines verified (non-negative integer). Required only when dispatched=true."
      },
      issues_found: %{
        type: "integer",
        required: true,
        description:
          "Count of issues the reviewer reported (non-negative integer). Required only when dispatched=true."
      }
    }
  end

  defp structured_fields(sections) do
    required? = &(&1 in sections)

    %{
      description:
        "Required on a dispatched review: every field marked required: true (the required_sections list) must be present, " <>
          "and so must status or issue_counts. Each present field is shape-validated by the server. " <>
          "Unknown nested fields inside any entry are tolerated for forward compatibility.",
      schema_version: %{
        type: "string",
        required: required?.("schema_version"),
        description:
          "Semver-shaped string identifying the schema the agent emitted. Accepts MAJOR.MINOR (e.g. \"1.0\") and MAJOR.MINOR.PATCH with optional pre-release and build metadata (e.g. \"1.2.3-beta.1\", \"1.0+build.7\"). The validator checks shape only; it does not gate on specific versions."
      },
      status: %{
        type: "string",
        required: "one of status or issue_counts",
        description:
          "Top-level outcome flag the agent assigns. Typical values are \"approved\" or \"changes_requested\" but the server does not enumerate them — the agent prompt is the source of truth. A dispatched review must carry status, issue_counts, or both."
      },
      issue_counts: %{
        type: "object",
        required: "one of status or issue_counts",
        description:
          "Per-severity count of issues. Keys mirror the severity enum: critical, important, minor. The server does not require all keys to be present. A dispatched review must carry status, issue_counts, or both.",
        example: %{critical: 0, important: 1, minor: 2}
      },
      issues: %{
        type: "array_of_objects",
        required: required?.("issues"),
        description:
          "Must be present; [] is valid when the review found nothing. Each entry must be an object. severity and category are enum-validated when present; missing severity or missing category on an entry is rejected.",
        entry_fields: issue_entry_fields()
      },
      acceptance_criteria: %{
        type: "array_of_objects",
        required: required?.("acceptance_criteria"),
        description:
          "Per-criterion verdict, one entry per line of the task's acceptance_criteria. Each entry must be an object with a recognized status. Use the underscore enum value `not_met` — `not met` (with a space) is rejected.",
        entry_fields: %{
          criterion: %{
            type: "string",
            required: false,
            description: "Text of the acceptance criterion being assessed."
          },
          status: %{
            type: "enum",
            values: ["met", "not_met"],
            required: true,
            description:
              "Underscore form ONLY — `not met` with a space is rejected by the validator."
          },
          evidence: %{
            type: "string",
            required: false,
            description: "Where the verdict is backed up (test name, file:line, etc.)."
          }
        }
      },
      project_checks: %{
        type: "array_of_objects",
        required: required?.("project_checks"),
        description:
          "One verdict per top-level bullet of the calling project's root CODE-REVIEW.md. The key must be present and its value must be a list. " <>
            "[] is valid and means the project has no CODE-REVIEW.md. The server never sees that file, so it never judges the list's length. " <>
            "The entry fields below are the reviewer schema's shape; the server checks only that the value is a list.",
        entry_fields: %{
          check: %{type: "string", description: "The checklist bullet's text."},
          source: %{type: "string", description: "Always \"CODE-REVIEW.md\"."},
          status: %{type: "enum", values: ["met", "not_met", "not_applicable"]},
          evidence: %{type: "string", description: "file:line for met, the gap for not_met."}
        }
      },
      testing_strategy: %{
        type: "section_verdict",
        required: required?.("testing_strategy"),
        description:
          "Verdict on the testing-strategy review step. Object with a status enum and a `note` string — optional on \"passed\"/\"not_assessed\", REQUIRED and substantive on \"failed\". See section_verdict_shape below."
      },
      patterns: %{
        type: "section_verdict",
        required: required?.("patterns"),
        description:
          "Verdict on the patterns-followed review step. See section_verdict_shape below — `note` is REQUIRED and substantive on \"failed\"."
      },
      pitfalls: %{
        type: "section_verdict",
        required: required?.("pitfalls"),
        description:
          "Verdict on the pitfalls review step. See section_verdict_shape below — `note` is REQUIRED and substantive on \"failed\"."
      },
      security_considerations: %{
        type: "section_verdict",
        required: required?.("security_considerations"),
        description:
          "Verdict on the security-considerations review step (see section_verdict_shape: status enum passed/failed/not_assessed plus a `note` that is optional on \"passed\"/\"not_assessed\" and REQUIRED and substantive on \"failed\"). The verdict itself is required on a dispatched review. Beyond the shared section-verdict shape, it MAY additionally carry an OPTIONAL nested `considerations` array (see considerations_breakdown below) giving a per-item mitigation breakdown of the task's security_considerations list. An absent array carries no obligation.",
        considerations_breakdown: considerations_breakdown()
      },
      section_verdict_shape: section_verdict_shape()
    }
  end

  defp issue_entry_fields do
    %{
      severity: %{
        type: "enum",
        values: ["critical", "important", "minor"],
        required: true,
        description: "Severity classification for this finding."
      },
      category: %{
        type: "enum",
        values: [
          "acceptance_criteria",
          "pitfall",
          "pattern",
          "testing",
          "security",
          "code_quality",
          "project_check"
        ],
        required: true,
        description:
          "Which review step surfaced this issue — one of the seven recognized review categories. Use `security` for an unmitigated security consideration and `project_check` for a `not_met` project checklist bullet."
      },
      file: %{
        type: "string",
        required: false,
        description: "Repository-relative path the issue applies to."
      },
      line: %{
        type: "integer",
        required: false,
        description: "Line number inside `file` where the issue is located."
      },
      description: %{
        type: "string",
        required: false,
        description: "Human-readable explanation of the finding."
      },
      suggested_fix: %{
        type: "string",
        required: false,
        description: "Proposed remediation, when the reviewer has one."
      }
    }
  end

  defp considerations_breakdown do
    %{
      type: "array_of_objects",
      required: false,
      description:
        "Optional per-consideration mitigation breakdown, added in schema_version 1.5 (additive). Each entry documents one of the task's security considerations and how the diff addressed it. Populated only on the Claude Code reviewer path today and absent otherwise; never required. Consistency rule (fail-closed): when the array is present, any entry with status `partial` or `unmitigated` forces the parent security_considerations.status to `failed` and should be backed by a matching issues[] entry with category `security`. Keep each entry to a short evidence reference and one-line note — never embed diff contents or secrets.",
      entry_fields: %{
        consideration: %{
          type: "string",
          required: true,
          description:
            "The task's security consideration string (verbatim). Must be a non-empty string; blank/absent entries are rejected."
        },
        status: %{
          type: "enum",
          values: ["mitigated", "partial", "unmitigated"],
          required: true,
          description:
            "Per-consideration mitigation verdict. `mitigated` = fully addressed by the diff; `partial` = partially addressed; `unmitigated` = not addressed. `partial`/`unmitigated` force the section status to `failed` (see consistency rule)."
        },
        evidence: %{
          type: "string",
          required: false,
          description:
            "Short backing reference (a file:line pointer or brief note). Never the diff contents or a secret."
        },
        note: %{
          type: "string",
          required: false,
          description: "Optional one-line rationale for the per-consideration verdict."
        }
      },
      example: [
        %{
          consideration: "Agent-supplied status values are untrusted — never String.to_atom them",
          status: "mitigated",
          evidence: "lib/kanban/tasks/completion_validation.ex:718",
          note: "Decoded via String.to_existing_atom with an ArgumentError rescue."
        }
      ]
    }
  end

  defp section_verdict_shape do
    %{
      description:
        "Object shape used by testing_strategy, patterns, pitfalls, security_considerations and behaviour_test_matrix. Status is enum-validated. `note` (SINGULAR) is the rendered annotation: optional on \"passed\" and \"not_assessed\", but REQUIRED and substantive on \"failed\". Non-map values are rejected.",
      entry_fields: %{
        status: %{
          type: "enum",
          values: ["passed", "failed", "not_assessed"],
          required: true
        },
        note: %{
          type: "string",
          required: "only when status is \"failed\"",
          description:
            "Annotation explaining the verdict. Optional on \"passed\" and \"not_assessed\" (empty string allowed). On \"failed\" it is REQUIRED and must name the specific violation in at least 20 non-whitespace characters: an empty string, a bare placeholder/TODO/TBD/n-a, padding built from those words, or a note that merely restates the status is rejected with 422 naming the offending section. A plural `notes` key is tolerated for legacy payloads but is never rendered and never satisfies this requirement."
        }
      },
      example: %{status: "passed", note: "All required test cases present."},
      failed_example: %{
        status: "failed",
        note: "A direct Ecto query was introduced in the LiveView, which pitfall 1 forbids."
      }
    }
  end
end
