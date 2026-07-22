defmodule KanbanWeb.API.Agent.SchemaDoc do
  @moduledoc """
  The `api_schema` documentation block of the agent onboarding payload,
  extracted verbatim from `KanbanWeb.API.AgentJSON` (W1442). Pure data —
  `schema/0` is composed unchanged into the onboarding response so external
  agents see a byte-identical `api_schema` map.
  """

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
            identifier: "string (e.g. 'W47')",
            agent_name: "string",
            before_doing_result: "hook_result_format (see below)"
          }
        },
        complete_task: %{
          endpoint: "PATCH /api/tasks/:id/complete",
          required_body: %{
            agent_name: "string",
            time_spent_minutes: "integer",
            completion_notes: "string",
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
      explorer_result_format: %{
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
      },
      reviewer_result_format: %{
        description:
          "Required format for reviewer_result on /complete. Two accepted shapes: dispatched (subagent ran) or skip_form (not dispatched). Beyond the required legacy fields, the dispatched form accepts a richer structured schema (issues[], acceptance_criteria[], the testing_strategy/patterns/pitfalls/security_considerations section verdicts — where the security_considerations verdict may carry an optional nested considerations[] mitigation breakdown — and schema_version) — all optional and backwards-compatible. The canonical schema of record lives in the stride plugin repo at stride/agents/task-reviewer.md; this documentation mirrors what the server validator (Kanban.Tasks.CompletionValidation) accepts.",
        backwards_compatibility:
          "Legacy summary-only payloads (the five required dispatched_fields without any structured_fields) remain fully valid. The structured fields are additive — emitters that do not populate them stay accepted by the validator.",
        dispatched_fields: %{
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
        },
        structured_fields: %{
          description:
            "All optional. When present each field is shape-validated by the server. Unknown nested fields inside any entry are tolerated for forward compatibility.",
          schema_version: %{
            type: "string",
            required: false,
            description:
              "Semver-shaped string identifying the schema the agent emitted. Accepts MAJOR.MINOR (e.g. \"1.0\") and MAJOR.MINOR.PATCH with optional pre-release and build metadata (e.g. \"1.2.3-beta.1\", \"1.0+build.7\"). The validator checks shape only; it does not gate on specific versions."
          },
          status: %{
            type: "string",
            required: false,
            description:
              "Top-level outcome flag the agent assigns. Typical values are \"approved\" or \"changes_requested\" but the server does not enumerate them — the agent prompt is the source of truth."
          },
          issue_counts: %{
            type: "object",
            required: false,
            description:
              "Per-severity count of issues. Keys mirror the severity enum: critical, important, minor. The server does not require all keys to be present.",
            example: %{critical: 0, important: 1, minor: 2}
          },
          issues: %{
            type: "array_of_objects",
            required: false,
            description:
              "Each entry must be an object. severity and category are enum-validated when present; missing severity or missing category on an entry is rejected.",
            entry_fields: %{
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
                  "code_quality"
                ],
                required: true,
                description:
                  "Which review step surfaced this issue — mirrors the five-step review methodology."
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
          },
          acceptance_criteria: %{
            type: "array_of_objects",
            required: false,
            description:
              "Per-criterion verdict. Each entry must be an object with a recognized status. Use the underscore enum value `not_met` — `not met` (with a space) is rejected.",
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
          testing_strategy: %{
            type: "section_verdict",
            required: false,
            description:
              "Verdict on the testing-strategy review step. Object with a status enum and an optional notes string. See section_verdict_shape below."
          },
          patterns: %{
            type: "section_verdict",
            required: false,
            description: "Verdict on the patterns-followed review step."
          },
          pitfalls: %{
            type: "section_verdict",
            required: false,
            description: "Verdict on the pitfalls review step."
          },
          security_considerations: %{
            type: "section_verdict",
            required: false,
            description:
              "Verdict on the security-considerations review step (see section_verdict_shape: status enum passed/failed/not_assessed plus an optional note). Beyond the shared section-verdict shape, this verdict object MAY additionally carry an OPTIONAL nested `considerations` array (see considerations_breakdown below) giving a per-item mitigation breakdown of the task's security_considerations list. Both the verdict and the nested array are optional and backwards-compatible — an absent array carries no obligation.",
            considerations_breakdown: %{
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
                  consideration:
                    "Agent-supplied status values are untrusted — never String.to_atom them",
                  status: "mitigated",
                  evidence: "lib/kanban/tasks/completion_validation.ex:718",
                  note: "Decoded via String.to_existing_atom with an ArgumentError rescue."
                }
              ]
            }
          },
          section_verdict_shape: %{
            description:
              "Object shape used by testing_strategy, patterns, and pitfalls. Status is enum-validated; notes is an optional string (empty string allowed). Non-map values are rejected.",
            entry_fields: %{
              status: %{
                type: "enum",
                values: ["passed", "failed", "not_assessed"],
                required: true
              },
              notes: %{
                type: "string",
                required: false,
                description: "Free-form annotation explaining the verdict (empty string allowed)."
              }
            },
            example: %{status: "passed", notes: "All required test cases present."}
          }
        },
        skip_form: %{
          description:
            "Same skip shape as explorer_result. Use when review was skipped or self-reported. See explorer_result_format.skip_form for field details and enum values.",
          example: %{
            dispatched: false,
            reason: "self_reported_review",
            summary:
              "Walked the diff against all 5 acceptance criteria and 3 pitfalls; confirmed each criterion met and no pitfall hit."
          }
        },
        example: %{
          dispatched: true,
          summary: "Reviewed the diff against all acceptance criteria and pitfalls",
          duration_ms: 8_000,
          acceptance_criteria_checked: 5,
          issues_found: 0
        },
        structured_example: %{
          dispatched: true,
          summary:
            "Reviewed against 4 acceptance criteria and 5 pitfalls; one important pattern deviation surfaced.",
          duration_ms: 8_000,
          acceptance_criteria_checked: 4,
          issues_found: 1,
          schema_version: "1.5",
          status: "changes_requested",
          issue_counts: %{critical: 0, important: 1, minor: 0},
          issues: [
            %{
              severity: "important",
              category: "pattern",
              file: "lib/kanban/tasks/agent_workflow.ex",
              line: 528,
              description: "Cast list omits the new field — payload would be silently dropped.",
              suggested_fix: "Add the field to the cast/2 list and the changeset validation."
            }
          ],
          acceptance_criteria: [
            %{criterion: "Validator accepts arrays", status: "met"},
            %{criterion: "Status enum enforced", status: "not_met", evidence: "Spec case missing"}
          ],
          testing_strategy: %{
            status: "passed",
            notes: "All 5 required test cases present in the new describe block."
          },
          patterns: %{status: "passed"},
          pitfalls: %{status: "passed", notes: "None violated."},
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
      },
      workflow_steps_format: %{
        description:
          "Ordered six-entry telemetry array documenting which workflow phases executed during the task. " <>
            "Cast onto the task struct for aggregation; not currently rejected when missing.",
        type: "array_of_objects",
        step_names: [
          "explorer",
          "planner",
          "implementation",
          "reviewer",
          "after_doing",
          "before_review"
        ],
        fields: %{
          name: %{
            type: "enum",
            required: true,
            description: "One of the six step_names above, in the order listed"
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
              "Short explanation of why the step was skipped (free-form; not the explorer_result/reviewer_result enum)"
          }
        },
        example: [
          %{name: "explorer", dispatched: true, duration_ms: 12_450},
          %{name: "planner", dispatched: true, duration_ms: 8_200},
          %{name: "implementation", dispatched: true, duration_ms: 1_820_000},
          %{name: "reviewer", dispatched: true, duration_ms: 15_300},
          %{name: "after_doing", dispatched: true, duration_ms: 45_678},
          %{name: "before_review", dispatched: true, duration_ms: 2_340}
        ]
      },
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
            "Older clients operate in grace mode (warnings only) until upgraded.",
        stride: %{minimum: "1.9.0", label: "1.9.0+"},
        "stride-copilot": %{minimum: "2.5.0", label: "2.5.0+"},
        "stride-gemini": %{minimum: "1.5.0", label: "1.5.0+"},
        "stride-codex": %{minimum: "1.4.0", label: "1.4.0+"},
        "stride-opencode": %{minimum: "1.4.0", label: "1.4.0+"}
      },
      validation_modes: %{
        description:
          "Completion validation runs in one of two modes, controlled by the " <>
            ":strict_completion_validation application flag. explorer_result and reviewer_result are pre-validated by Kanban.Tasks.CompletionValidation. " <>
            "workflow_steps is telemetry — cast onto the task struct but not rejected when absent.",
        grace: %{
          flag: ":strict_completion_validation = false",
          behavior:
            "Missing or malformed explorer_result / reviewer_result log a structured warning but the request succeeds. Default rollout mode.",
          intended_for: "Plugin rollout window; older clients remain compatible."
        },
        strict: %{
          flag: ":strict_completion_validation = true",
          behavior:
            "Missing or malformed explorer_result / reviewer_result are rejected with HTTP 422 and a failures list. Skip forms must include a valid reason.",
          intended_for: "Post-rollout steady state; enforces task-quality contracts."
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
      },
      valid_capabilities: Kanban.Tasks.Task.valid_capabilities()
    }
  end
end
