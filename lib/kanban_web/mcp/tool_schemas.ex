defmodule KanbanWeb.MCP.ToolSchemas do
  @moduledoc """
  The MCP tool definitions (W2231): name, title, description, JSON Schema
  `inputSchema` and annotations for each tool. Data only.

  Argument names and types follow the REST API's OpenAPI document
  (`priv/openapi/stride-api.json`): the list tool takes the `GET /api/tasks`
  query parameters, the claim and complete tools take the request bodies of
  `POST /api/tasks/claim` and `PATCH /api/tasks/:id/complete`. The status,
  type and priority enums are read from the `Kanban.Tasks.Task` schema at
  compile time so they cannot drift from it.
  """

  alias Kanban.Tasks.Task

  @status_values Task |> Ecto.Enum.dump_values(:status)
  @type_values Task |> Ecto.Enum.dump_values(:type)
  @priority_values Task |> Ecto.Enum.dump_values(:priority)

  @task_id %{
    "type" => ["string", "integer"],
    "description" => "Task identifier (for example W14) or numeric task id."
  }

  @response_view %{
    "type" => "string",
    "enum" => ["slim", "full"],
    "description" => "slim selects the compact view; full (the default) the whole task."
  }

  @hook_result %{
    "type" => "object",
    "description" =>
      "Hook execution result: {exit_code: integer, output: string, duration_ms: integer >= 0}."
  }

  @read_only %{"readOnlyHint" => true, "destructiveHint" => false, "openWorldHint" => false}
  @mutating %{"readOnlyHint" => false, "destructiveHint" => false, "openWorldHint" => false}

  @tools [
    %{
      "name" => "stride_next_task",
      "title" => "Next task",
      "description" =>
        "Returns the next claimable task in the Ready column of the token's board that matches the token's capabilities (GET /api/tasks/next). Does not claim it.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "skills_version" => %{"type" => "string"},
          "response_view" => @response_view
        },
        "additionalProperties" => false
      },
      "annotations" => @read_only
    },
    %{
      "name" => "stride_claim_task",
      "title" => "Claim task",
      "description" =>
        "Claims a task (POST /api/tasks/claim): the named identifier, or the next available task when omitted. Requires the before_doing hook result. Returns the task and the before_doing hook to run.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "identifier" => %{
            "type" => "string",
            "description" => "Task to claim. Omit to claim the next available task."
          },
          "agent_name" => %{"type" => "string"},
          "skills_version" => %{"type" => "string"},
          "before_doing_result" => @hook_result
        },
        "required" => ["before_doing_result"],
        "additionalProperties" => false
      },
      "annotations" => @mutating
    },
    %{
      "name" => "stride_complete_task",
      "title" => "Complete task",
      "description" =>
        "Completes a claimed task (PATCH /api/tasks/:id/complete) with exactly the same validation as the REST endpoint. Pass the hook results, explorer_result, reviewer_result and completion fields documented in docs/api/patch_tasks_id_complete.md. Returns the compact acknowledgement with the hooks to run; pass response_view full for the whole task.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "id" => @task_id,
          "after_doing_result" => @hook_result,
          "before_review_result" => @hook_result,
          "explorer_result" => %{"type" => "object"},
          "reviewer_result" => %{"type" => "object"},
          "workflow_steps" => %{"type" => "array"},
          "agent_name" => %{"type" => "string"},
          "skills_version" => %{"type" => "string"},
          "time_spent_minutes" => %{"type" => "integer"},
          "completion_summary" => %{"type" => "string"},
          "completion_notes" => %{"type" => "string", "maxLength" => 65_535},
          "actual_complexity" => %{"type" => "string", "enum" => ["small", "medium", "large"]},
          "actual_files_changed" => %{"type" => "string"},
          "review_report" => %{"type" => "string"},
          "response_view" =>
            Map.put(
              @response_view,
              "description",
              "slim (the default here) returns the compact acknowledgement, which still carries hooks; full returns the whole task."
            )
        },
        "required" => ["id", "after_doing_result", "before_review_result", "reviewer_result"],
        "additionalProperties" => true
      },
      "annotations" => @mutating
    },
    %{
      "name" => "stride_get_task",
      "title" => "Get task",
      "description" => "Returns one task on the token's board (GET /api/tasks/:id).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"id" => @task_id, "response_view" => @response_view},
        "required" => ["id"],
        "additionalProperties" => false
      },
      "annotations" => @read_only
    },
    %{
      "name" => "stride_list_tasks",
      "title" => "List tasks",
      "description" =>
        "Lists one page of the token's board tasks (GET /api/tasks in paginated mode), slim summaries by default. Pass meta.next_cursor back as cursor for the next page; it is null on the last page.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 200,
            "description" => "Page size, 1-200 (default 50)."
          },
          "cursor" => %{
            "type" => "string",
            "description" => "meta.next_cursor of the previous page."
          },
          "status" => %{"type" => "string", "enum" => @status_values},
          "type" => %{"type" => "string", "enum" => @type_values},
          "priority" => %{"type" => "string", "enum" => @priority_values},
          "assigned_to_id" => %{"type" => "integer", "minimum" => 1},
          "parent" => %{
            "type" => "string",
            "maxLength" => 255,
            "description" => "Goal identifier: only that goal's children."
          },
          "updated_since" => %{
            "type" => "string",
            "description" => "ISO 8601 timestamp: only tasks updated at or after it."
          },
          "column_id" => %{"type" => "integer"},
          "response_view" =>
            Map.put(
              @response_view,
              "description",
              "full returns whole tasks; slim is the default."
            )
        },
        "additionalProperties" => false
      },
      "annotations" => @read_only
    },
    %{
      "name" => "stride_add_comment",
      "title" => "Add comment",
      "description" =>
        "Adds a comment to a task on the token's board. Requires owner or modify access to the board.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "id" => @task_id,
          "content" => %{"type" => "string", "minLength" => 1, "maxLength" => 10_000}
        },
        "required" => ["id", "content"],
        "additionalProperties" => false
      },
      "annotations" => @mutating
    }
  ]

  @by_name Map.new(@tools, &{&1["name"], &1})

  @doc "Every tool definition, in a stable order."
  def all, do: @tools

  @doc "The definition for `name`, or nil. Matched as a string, never an atom."
  def fetch(name) when is_binary(name), do: Map.get(@by_name, name)
  def fetch(_name), do: nil
end
