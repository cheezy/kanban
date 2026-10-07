defmodule KanbanWeb.API.TaskRequestRejections do
  @moduledoc """
  The task API's 422 rejections for requests that are malformed before any
  task is touched, split from `KanbanWeb.API.TaskController` to keep the
  controller under the module size guideline.

  It holds two groups of bodies:

    * the wrong-root-key / missing-root-key rejections of `create/2`,
      `batch_create/2` and `update/2` (`reject_malformed_request/2`), each
      carrying an `example` of the correct request shape; and
    * the `GET /api/tasks/:id?fields=…` projection rejections of `show/2`
      (W2076/W2094): unknown field names, a malformed `fields` value, and
      `fields` sent together with `response_view`.

  Like `KanbanWeb.API.TaskErrors`, these functions take `conn` and render the
  response directly (`put_status |> json`). Every body is enriched by
  `KanbanWeb.API.ErrorDocs.add_docs_to_error/2` under the same key as before;
  the status, body shape and message strings are matched by API clients and
  the request-test suite, so they must not drift.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias KanbanWeb.API.ErrorDocs
  alias KanbanWeb.API.TaskFieldsProjection

  @doc """
  Renders the 422 for a create, batch-create or update request whose body has
  the wrong root key or none at all. `docs_key` is both the
  `KanbanWeb.API.ErrorDocs` key and the selector for the body:
  `:create_invalid_root_key`, `:create_missing_task_key`,
  `:batch_create_invalid_root_key`, `:batch_create_missing_goals_key`,
  `:update_invalid_root_key` or `:update_missing_task_key`.
  """
  def reject_malformed_request(conn, docs_key) do
    error_response =
      docs_key
      |> malformed_request_body()
      |> ErrorDocs.add_docs_to_error(docs_key)

    conn
    |> put_status(:unprocessable_entity)
    |> json(error_response)
  end

  defp malformed_request_body(:create_invalid_root_key) do
    %{
      error:
        "Invalid request format. The request body key must be 'task', not 'data'. See documentation for correct format.",
      example: %{
        task: %{
          title: "Task title",
          description: "Task description",
          type: "work",
          priority: "medium"
        }
      }
    }
  end

  defp malformed_request_body(:create_missing_task_key) do
    %{
      error:
        "Invalid request format. Missing 'task' key in request body. See documentation for correct format.",
      example: %{
        task: %{
          title: "Task title",
          description: "Task description",
          type: "work",
          priority: "medium"
        }
      }
    }
  end

  defp malformed_request_body(:batch_create_invalid_root_key) do
    %{
      error:
        "Invalid request format. The root key must be 'goals', not 'tasks'. See documentation for correct format.",
      example: %{
        goals: [
          %{
            title: "Goal Title",
            type: "goal",
            tasks: [
              %{title: "Task 1", type: "work"},
              %{title: "Task 2", type: "work"}
            ]
          }
        ]
      }
    }
  end

  defp malformed_request_body(:batch_create_missing_goals_key) do
    %{
      error:
        "Invalid request format. Missing 'goals' key in request body. See documentation for correct format.",
      example: %{
        goals: [
          %{
            title: "Goal Title",
            type: "goal",
            tasks: [
              %{title: "Task 1", type: "work"},
              %{title: "Task 2", type: "work"}
            ]
          }
        ]
      }
    }
  end

  defp malformed_request_body(:update_invalid_root_key) do
    %{
      error:
        "Invalid request format. The request body key must be 'task', not 'data'. See documentation for correct format.",
      example: %{
        task: %{
          title: "Updated title",
          description: "Updated description",
          priority: "high"
        }
      }
    }
  end

  defp malformed_request_body(:update_missing_task_key) do
    %{
      error:
        "Invalid request format. Missing 'task' key in request body. See documentation for correct format.",
      example: %{
        task: %{
          title: "Updated title",
          description: "Updated description",
          priority: "high"
        }
      }
    }
  end

  # (W2094) The echo is capped: every name is still counted, but at most
  # @unknown_fields_echo_cap are reflected back. Uncapped, 1,000 unknown
  # names produced a ~93KB response from a ~7KB request — a ~13x reflected
  # amplification of attacker-influenced text.
  @unknown_fields_echo_cap 10

  @doc """
  Renders the 422 for a `fields` projection naming fields that do not exist,
  echoing at most #{@unknown_fields_echo_cap} of the `unknown` names (W2094).
  """
  def reject_unknown_fields(conn, unknown) do
    echoed = Enum.take(unknown, @unknown_fields_echo_cap)
    omitted = length(unknown) - length(echoed)

    errors =
      Enum.map(echoed, fn name ->
        %{field: name, message: TaskFieldsProjection.unknown_field_message(name)}
      end)

    errors =
      if omitted > 0 do
        errors ++
          [
            %{
              field: "fields",
              message:
                "…and #{omitted} more unknown name(s) — the echo is capped at #{@unknown_fields_echo_cap}; the request named #{length(unknown)} distinct unknown fields in total"
            }
          ]
      else
        errors
      end

    body =
      ErrorDocs.add_docs_to_error(
        %{error: "task fields rejected", failures: [%{field: "fields", errors: errors}]},
        :show_unknown_fields
      )

    conn
    |> put_status(:unprocessable_entity)
    |> json(body)
  end

  @doc """
  Renders the 422 for a `fields` value that is not a well-formed list of names.
  """
  def reject_invalid_fields_shape(conn) do
    body =
      ErrorDocs.add_docs_to_error(
        %{
          error: "task fields rejected",
          failures: [
            %{
              field: "fields",
              errors: [
                %{field: "fields", message: TaskFieldsProjection.invalid_shape_message()}
              ]
            }
          ]
        },
        :show_invalid_fields_shape
      )

    conn
    |> put_status(:unprocessable_entity)
    |> json(body)
  end

  @doc """
  Renders the 422 for a request that sends both `fields` and `response_view`.
  """
  def reject_fields_response_view_conflict(conn) do
    body =
      ErrorDocs.add_docs_to_error(
        %{error: "fields and response_view are mutually exclusive; send only one"},
        :show_fields_response_view_conflict
      )

    conn
    |> put_status(:unprocessable_entity)
    |> json(body)
  end
end
