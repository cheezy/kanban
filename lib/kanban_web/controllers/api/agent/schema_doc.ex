defmodule KanbanWeb.API.Agent.SchemaDoc do
  @moduledoc """
  The `api_schema` documentation block of the agent onboarding payload,
  extracted verbatim from `KanbanWeb.API.AgentJSON` (W1442). Pure data —
  `schema/0` is composed unchanged into the onboarding response so external
  agents see a byte-identical `api_schema` map.

  The `explorer_result_format`, `reviewer_result_format` and `validation_modes`
  blocks live in `KanbanWeb.API.Agent.CompletionResultDoc` (D389), which derives
  the required reviewer sections from the review contract.

  The `workflow_steps_format` block sources its step names and skip-reason
  codes from `Kanban.Tasks.WorkflowSteps` rather than re-listing them, so the
  published contract cannot drift from what the validator actually enforces.
  """

  alias Kanban.Tasks.WorkflowSteps
  alias KanbanWeb.API.Agent.CompletionResultDoc

  @doc "The API schema documentation map embedded in the onboarding payload."
  def schema do
    %{
      description:
        "Field reference for Stride API. Consult this before constructing API requests to avoid validation errors.",
      request_formats: %{
        create_task: %{
          endpoint: "POST /api/tasks",
          root_key: "task",
          example: %{task: %{title: "Add login endpoint", type: "work", priority: "medium"}}
        },
        batch_create: %{
          endpoint: "POST /api/tasks/batch",
          root_key: "goals",
          note: "Root key MUST be 'goals', NOT 'tasks'",
          example: %{
            goals: [
              %{title: "Auth System", type: "goal", tasks: [%{title: "Schema", type: "work"}]}
            ]
          }
        },
        claim_task: %{
          endpoint: "POST /api/tasks/claim",
          required_body: %{
            before_doing_result: "hook_result_format (see below)"
          },
          optional_body: %{
            identifier:
              "string (e.g. 'W47') — claim this task; omit it to claim the next available task",
            agent_name: "string — recorded on the claim; defaults to \"Unknown\"",
            skills_version: "string — the plugin's skills version"
          }
        },
        complete_task: %{
          endpoint: "PATCH /api/tasks/:id/complete",
          required_body: %{
            agent_name: "string",
            time_spent_minutes: "integer",
            completion_notes:
              "string — OPTIONAL: long-form narrative; persisted, returned by the API, and rendered on the Review queue",
            completion_summary: "string (brief summary for tracking)",
            actual_complexity: "enum: 'small', 'medium', 'large'",
            actual_files_changed:
              "string (comma-separated file paths, NOT an array — e.g. 'lib/foo.ex, lib/bar.ex')",
            after_doing_result: "hook_result_format (see below)",
            before_review_result: "hook_result_format (see below)",
            explorer_result:
              "explorer_result_format (see below) — required; use dispatched shape or skip_form",
            reviewer_result:
              "reviewer_result_format (see below) — required; use dispatched shape or skip_form",
            workflow_steps:
              "workflow_steps_format (see below) — six-entry telemetry array, one entry per phase"
          }
        }
      },
      hook_result_format: %{
        description: "Required format for all hook execution results",
        fields: %{
          exit_code: %{
            type: "integer",
            required: true,
            description: "0 for success, non-zero for failure"
          },
          output: %{
            type: "string",
            required: true,
            description: "stdout/stderr output from hook execution"
          },
          duration_ms: %{
            type: "integer",
            required: true,
            description: "How long the hook took to execute in milliseconds"
          }
        },
        example: %{exit_code: 0, output: "All tests passed", duration_ms: 1234}
      },
      explorer_result_format: CompletionResultDoc.explorer_result_format(),
      reviewer_result_format: CompletionResultDoc.reviewer_result_format(),
      workflow_steps_format: workflow_steps_format(),
      task_fields: %{
        title: %{type: "string", required: true, description: "Short task description"},
        type: %{type: "enum", values: ["work", "defect", "goal"], required: true},
        priority: %{type: "enum", values: ["low", "medium", "high", "critical"], required: true},
        complexity: %{type: "enum", values: ["small", "medium", "large"], required: false},
        needs_review: %{type: "boolean", required: false, default: false},
        description: %{type: "string", required: false, description: "WHY + WHAT + WHERE"},
        acceptance_criteria: %{
          type: "string",
          required: false,
          description: "Newline-separated string"
        },
        patterns_to_follow: %{
          type: "string",
          required: false,
          description: "Newline-separated string"
        },
        why: %{type: "string", required: false},
        what: %{type: "string", required: false},
        where_context: %{type: "string", required: false},
        dependencies: %{
          type: "array_of_strings",
          required: false,
          description:
            "Task identifiers like [\"W45\", \"W46\"] for existing tasks, or array indices [0, 1] within a goal"
        },
        pitfalls: %{type: "array_of_strings", required: false},
        technology_requirements: %{type: "array_of_strings", required: false},
        security_considerations: %{type: "array_of_strings", required: false},
        out_of_scope: %{type: "array_of_strings", required: false},
        technical_details: %{
          type: "object",
          required: false,
          description:
            "Free-form JSON object for any additional technical information an agent wants to record. Unlike testing_strategy, it has no fixed keys — any keys and values are accepted."
        }
      },
      embedded_objects: %{
        key_files: %{
          type: "array_of_objects",
          required_fields: %{
            file_path: "string (relative path, no leading / or ..)",
            position: "integer >= 0"
          },
          optional_fields: %{note: "string"},
          example: %{file_path: "lib/kanban/tasks.ex", note: "Add query function", position: 0}
        },
        verification_steps: %{
          type: "array_of_objects",
          "⚠️_NOT_strings": "This MUST be an array of objects, NOT an array of strings",
          required_fields: %{
            step_type: "string ('command' or 'manual' only)",
            step_text: "string (the command or instruction)",
            position: "integer >= 0"
          },
          optional_fields: %{expected_result: "string"},
          example: %{
            step_type: "command",
            step_text: "mix test",
            expected_result: "All tests pass",
            position: 0
          }
        },
        testing_strategy: %{
          type: "object",
          description: "JSON object with string or array-of-strings values",
          valid_keys: [
            "unit_tests",
            "integration_tests",
            "manual_tests",
            "edge_cases",
            "coverage_target"
          ],
          example: %{
            unit_tests: ["Test valid login", "Test invalid login"],
            edge_cases: ["Empty password", "SQL injection attempt"],
            coverage_target: "100% for auth module"
          }
        },
        technical_details: %{
          type: "object",
          description:
            "Free-form JSON object for arbitrary technical information. Unlike testing_strategy, it has NO fixed valid_keys — any keys and values are accepted.",
          example: %{
            db_migration: "Adds a technical_details :map column",
            rollback: %{steps: ["Drop the column"]},
            notes: "Mirror the integration_points wiring"
          }
        }
      },
      plugin_versions: %{
        description:
          "Minimum plugin versions that emit the G65 explorer_result / reviewer_result / workflow_steps fields. " <>
            "A client that omits them is rejected in strict mode, the production default, and a dispatched " <>
            "reviewer_result without the structured block is rejected in every mode.",
        stride: %{minimum: "1.9.0", label: "1.9.0+"},
        "stride-copilot": %{minimum: "2.5.0", label: "2.5.0+"},
        "stride-gemini": %{minimum: "1.5.0", label: "1.5.0+"},
        "stride-codex": %{minimum: "1.4.0", label: "1.4.0+"},
        "stride-opencode": %{minimum: "1.4.0", label: "1.4.0+"}
      },
      validation_modes: CompletionResultDoc.validation_modes(),
      valid_capabilities: Kanban.Tasks.Task.valid_capabilities()
    }
  end

  defp workflow_steps_format do
    %{
      description:
        "Ordered six-entry telemetry array documenting which workflow phases executed during the task. " <>
          "Cast onto the task struct for aggregation; not currently rejected when missing.",
      type: "array_of_objects",
      step_names: WorkflowSteps.canonical_step_names(),
      skip_reason_codes: skip_reason_code_strings(),
      fields: workflow_steps_fields(),
      example: [
        %{name: "explorer", dispatched: true, duration_ms: 12_450},
        %{
          name: "planner",
          dispatched: false,
          reason_code: "decision_matrix_skip",
          reason: "Step 3 matrix row 'small, 2+ key_files' gives Plan = Skip"
        },
        %{name: "implementation", dispatched: true, duration_ms: 1_820_000},
        %{name: "reviewer", dispatched: true, duration_ms: 15_300},
        %{name: "after_doing", dispatched: true, duration_ms: 45_678},
        %{name: "before_review", dispatched: true, duration_ms: 2_340}
      ]
    }
  end

  defp skip_reason_code_strings do
    Enum.map(WorkflowSteps.skip_reason_codes(), &to_string/1)
  end

  defp workflow_steps_fields do
    %{
      name: %{
        type: "string",
        required: true,
        description:
          "One of the six step_names above, in the order listed. Advisory, not enforced: " <>
            "`name` is deliberately NOT constrained (D239), because persisted data carries a " <>
            "second step vocabulary from another runtime and rejecting it would 422 that " <>
            "runtime's completions mid-flight. An unrecognized name still aggregates as its own row."
      },
      dispatched: %{
        type: "boolean",
        required: true,
        description: "true if the step ran; false if intentionally skipped"
      },
      duration_ms: %{
        type: "integer",
        required_when: "dispatched=true",
        description: "Wall-clock time the step took, in milliseconds"
      },
      reason: %{
        type: "string",
        required_when: "dispatched=false",
        description:
          "Free-form explanation of why the step was skipped. Still required when dispatched=false, " <>
            "still unconstrained, and still rendered verbatim on the task detail page. " <>
            "Not the explorer_result/reviewer_result enum."
      },
      reason_code: %{
        type: "enum",
        required: false,
        enum: skip_reason_code_strings(),
        description:
          "Optional machine-readable skip category, used ONLY when dispatched=false (D239). " <>
            "Supply it alongside `reason`, never instead of it: the code is what the compliance " <>
            "dashboard aggregates, the prose is what a human reads. Omitting it is always valid — " <>
            "payloads that predate this field are accepted unchanged. A code outside the enum is " <>
            "rejected rather than silently bucketed."
      }
    }
  end
end
