defmodule KanbanWeb.API.TaskActions do
  @moduledoc """
  The task API's action bodies, shared by the REST controller and the MCP
  tools (W2231).

  `KanbanWeb.API.TaskController` and `KanbanWeb.MCP.Tools` both call these
  functions, so a claim or completion made over MCP runs exactly the same
  validation (hook-result validation, `CompletionResultGate`, board-write and
  assignee checks in the Tasks context) and produces exactly the same task
  state as one made over REST. Nothing here renders: every action returns

    * `{:ok, template, assigns}` — the `KanbanWeb.API.TaskJSON` template and
      the assigns REST renders it with, so REST calls `render/3` and MCP calls
      the same TaskJSON function with the same assigns; or
    * `{:error, reason}` — a reason `KanbanWeb.API.TaskErrors.error_body/1`
      translates into the REST status, error code and body.

  The `conn` is read-only context here: the token's board, user and API token
  come from its assigns (set by `KanbanWeb.Plugs.AuthenticateApiToken`), and
  the controller-level telemetry events carry its path and method.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Hooks.Validator
  alias Kanban.Tasks
  alias KanbanWeb.API.AgentAttribution
  alias KanbanWeb.API.CompletionResultGate
  alias KanbanWeb.API.TaskListParams

  require Logger

  # D360: Postgrex encodes a bigint parameter only inside the signed 64-bit
  # range and raises DBConnection.EncodeError (a 500) for anything outside it.
  # Integer.parse/1 is unbounded, so a parsed task id or column_id is checked
  # against this range before it can reach a query. Zero and negatives inside
  # the range keep their existing path (lookup, then 404).
  @bigint_range -9_223_372_036_854_775_808..9_223_372_036_854_775_807

  @doc """
  The next claimable task for the token's capabilities (`GET /api/tasks/next`).
  """
  def next_task(conn, params) do
    %{current_board: board, current_user: user, api_token: api_token} = conn.assigns

    case Tasks.get_next_task(api_token.agent_capabilities || [], board.id, user.id) do
      nil ->
        {:error, :no_next_task}

      task ->
        emit_telemetry(conn, :next_task_fetched, %{task_id: task.id, priority: task.priority})

        {:ok, :show,
         [
           task: task,
           agent_skills_version: params["skills_version"],
           response_view: view_for(params)
         ]}
    end
  end

  @doc """
  Claims a task (`POST /api/tasks/claim`): stamps the agent identity, validates
  the `before_doing_result`, then claims through `Tasks.claim_next_task/5`.
  """
  def claim(conn, params) do
    stamp_agent_identity(conn, params)

    case validate_hook(params["before_doing_result"], "before_doing") do
      :ok -> proceed_with_claim(conn, claim_agent(conn, params), params["identifier"])
      error -> error
    end
  end

  defp claim_agent(conn, params) do
    api_token = conn.assigns.api_token

    %{
      capabilities: api_token.agent_capabilities || [],
      name: params["agent_name"] || "Unknown",
      api_token: api_token,
      skills_version: params["skills_version"]
    }
  end

  defp proceed_with_claim(conn, agent, identifier) do
    %{current_board: board, current_user: user} = conn.assigns

    agent.capabilities
    |> Tasks.claim_next_task(user, board.id, identifier, agent.name)
    |> claim_result(conn, agent, identifier)
  end

  defp claim_result({:ok, task, hook_info}, conn, agent, identifier) do
    emit_telemetry(conn, :task_claimed, %{
      task_id: task.id,
      priority: task.priority,
      api_token_id: agent.api_token.id,
      specific_task: !!identifier
    })

    {:ok, :show, [task: task, hook: hook_info, agent_skills_version: agent.skills_version]}
  end

  defp claim_result({:error, :no_tasks_available}, _conn, _agent, identifier),
    do: {:error, {:no_tasks_available, identifier}}

  defp claim_result({:error, :assigned_to_other_user}, _conn, _agent, identifier),
    do: {:error, {:assigned_to_other_user, identifier}}

  defp claim_result({:error, :not_authorized}, _conn, _agent, _identifier),
    do: {:error, :not_authorized_to_claim}

  defp claim_result({:error, reason}, _conn, agent, identifier) do
    log_unexpected_claim_error(reason, task_identifier: identifier, agent_name: agent.name)
    {:error, :claim_failed}
  end

  @doc """
  Logs the underlying reason of an unexpected claim failure server-side
  (changeset internals, internal atoms, database errors, etc.). The response
  body never carries it — see `TaskErrors.unexpected_claim_error_body/0`.
  """
  def log_unexpected_claim_error(reason, metadata) do
    Logger.error(
      "claim_next_task catch-all error: #{inspect(reason)}",
      Keyword.put(metadata, :reason, inspect(reason))
    )
  end

  @doc """
  Completes a task (`PATCH /api/tasks/:id/complete`): board-scoped fetch, hook
  result validation, `CompletionResultGate`, then `Tasks.complete_task/4`.
  """
  def complete(conn, id_or_identifier, params) do
    stamp_agent_identity(conn, params)

    with {:ok, task} <- fetch_task(id_or_identifier, conn.assigns.current_board),
         :ok <- validate_complete_preconditions(task, params) do
      proceed_with_complete(conn, task, params)
    end
  end

  defp validate_complete_preconditions(task, params) do
    with :ok <- validate_hook(params["after_doing_result"], "after_doing"),
         :ok <- validate_hook(params["before_review_result"], "before_review") do
      gate_completion_results(task, params)
    end
  end

  defp gate_completion_results(task, params) do
    metadata = [task_id: task.id, agent_name: params["agent_name"]]

    case CompletionResultGate.gate(params, task: task, metadata: metadata) do
      :ok -> :ok
      {:warn, _failures} -> :ok
      {:reject, body} -> {:error, {:completion_validation_failed, body}}
    end
  end

  defp proceed_with_complete(conn, task, params) do
    api_token = conn.assigns.api_token
    agent_name = params["agent_name"] || "Unknown"
    params_with_agent = put_completed_by_agent(params, api_token, agent_name)

    task
    |> Tasks.complete_task(conn.assigns.current_user, params_with_agent, agent_name)
    |> complete_result(conn, params)
  end

  # W2059: the view is resolved from the request but applied on the success
  # path only — Tasks.complete_task/4 has already authorized and persisted the
  # completion, so the choice cannot widen what a caller reads and cannot
  # change what is validated or stored. Both templates get the SAME assigns, so
  # `hooks` (which stride-hook.sh reads for before_review and after_goal
  # detection) and the skills-version keys ride along either way.
  defp complete_result({:ok, task, hooks}, conn, params) do
    emit_telemetry(conn, :task_completed, %{
      task_id: task.id,
      time_spent_minutes: task.time_spent_minutes
    })

    template = if view_for(params) == :slim, do: :ack, else: :show
    {:ok, template, [task: task, hooks: hooks, agent_skills_version: params["skills_version"]]}
  end

  defp complete_result({:error, :invalid_status}, _conn, _params),
    do: {:error, :invalid_status_for_complete}

  defp complete_result({:error, :not_authorized}, _conn, _params),
    do: {:error, :not_authorized_to_complete}

  defp complete_result({:error, %Ecto.Changeset{} = changeset}, _conn, _params),
    do: {:error, changeset}

  defp put_completed_by_agent(params, %{agent_model: nil}, agent_name),
    do: Map.put(params, "completed_by_agent", agent_name)

  defp put_completed_by_agent(params, %{agent_model: agent_model}, _agent_name),
    do: Map.put(params, "completed_by_agent", "ai_agent:#{agent_model}")

  @doc """
  One task on the token's board (`GET /api/tasks/:id` without `fields`).
  """
  def get_task(conn, id_or_identifier, params) do
    with {:ok, task} <- fetch_task(id_or_identifier, conn.assigns.current_board) do
      {:ok, :show,
       [task: task, response_view: view_for(params), comment_count: length(task.comments)]}
    end
  end

  @doc """
  One page of the token's board tasks (`GET /api/tasks` in paginated mode,
  W2224). Every param is validated before any query runs, and the board id
  from the token is the first constraint of the page query, so neither a
  crafted cursor nor another board's parent identifier can widen the scope.
  """
  def list_page(conn, params) do
    board = conn.assigns.current_board

    with {:ok, page} <- TaskListParams.parse(params),
         {:ok, column_filter} <- page_column_filter(board, params["column_id"]) do
      {:ok, :index, task_page(conn, board, page, column_filter, view_for(params))}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, message} when is_binary(message) -> {:error, {:invalid_param, message}}
    end
  end

  defp task_page(conn, board, page, column_filter, view) do
    filters = page |> TaskListParams.filters() |> Map.merge(column_filter)
    opts = [limit: page.limit, after_id: page.cursor]
    {tasks, next_id} = Tasks.list_board_tasks_page(board.id, filters, opts)
    meta = %{next_cursor: TaskListParams.encode_cursor(next_id), limit: page.limit}

    emit_telemetry(conn, :task_listed, %{count: length(tasks)})
    [tasks: tasks, response_view: view, page_meta: meta]
  end

  defp page_column_filter(_board, nil), do: {:ok, %{}}

  defp page_column_filter(board, raw_column_id) do
    case parse_id(raw_column_id) do
      {:ok, column_id} -> board_column_filter(board, column_id)
      :error -> {:error, "Invalid column_id: must be an integer"}
    end
  end

  # Same board-scoped lookup as the legacy column_id branch, so a cross-board
  # and a nonexistent column id produce the same 404 in both modes.
  defp board_column_filter(board, column_id) do
    case column_for_board(column_id, board.id) do
      nil -> {:error, :not_found}
      column -> {:ok, %{column_id: column.id}}
    end
  end

  @doc """
  Lists a task's comments (`GET /api/tasks/:id/comments`): the `limit` most
  recent (default 50, at most 200), oldest first. The task is fetched with the
  same board-scoped lookup as every other action, so a cross-board id is a
  plain not-found. The limit is validated before any query runs.
  """
  def list_comments(conn, id_or_identifier, params) do
    with {:ok, limit} <- comment_limit(params),
         {:ok, task} <- fetch_task(id_or_identifier, conn.assigns.current_board) do
      {comments, has_more} = Tasks.list_recent_comments(task, limit)
      emit_telemetry(conn, :comments_listed, %{task_id: task.id, count: length(comments)})
      {:ok, :index, [comments: comments, meta: %{limit: limit, has_more: has_more}]}
    end
  end

  defp comment_limit(params) do
    case TaskListParams.parse_limit(params["limit"]) do
      {:ok, limit} -> {:ok, limit}
      {:error, message} -> {:error, {:invalid_param, message}}
    end
  end

  @doc """
  Adds a comment to a task on the token's board, authored by the token's user.
  This one function backs both `POST /api/tasks/:id/comments` and the MCP
  `stride_add_comment` tool, so their validation and attribution cannot drift.

  The task is fetched with the same board-scoped lookup as every other action,
  so a cross-board identifier is a plain not-found. Authorization is
  `Kanban.Tasks.CommentPolicy`, applied inside `Tasks.create_comment/4`: any
  board member may comment, read-only included, and a user with no membership
  on the board gets `{:error, :not_authorized}`. Claim and complete still need
  `authorize_board_write/2`.

  `agent_name` is display attribution only, resolved through
  `KanbanWeb.API.AgentAttribution` (token `agent_model`, then `agent_name`,
  then the token's `last_agent_name`). After a successful write the token's
  `last_agent_name` is stamped from `agent_name`, as claim and complete do.
  """
  def add_comment(conn, id_or_identifier, content, agent_name \\ nil) do
    %{current_board: board, current_user: user, api_token: api_token} = conn.assigns
    author_agent_name = AgentAttribution.resolve(api_token, agent_name)

    with {:ok, task} <- fetch_task(id_or_identifier, board),
         {:ok, comment} <- comment_as(user, task, content, author_agent_name) do
      stamp_agent_identity(conn, %{"agent_name" => agent_name})
      emit_telemetry(conn, :comment_created, %{task_id: task.id})
      {:ok, %{comment | author: user}}
    end
  end

  defp comment_as(user, task, content, author_agent_name) do
    scope = Scope.for_user(user)
    opts = [author_agent_name: author_agent_name]

    case Tasks.create_comment(scope, task, %{"content" => content}, opts) do
      {:error, :unauthorized} -> {:error, :not_authorized}
      other -> other
    end
  end

  @doc """
  `:ok` when `user` holds `:owner` or `:modify` access to `board`, else
  `{:error, :not_authorized_write}`. A live check, so a token whose user lost
  write access is refused even though the token itself still authenticates.
  """
  def authorize_board_write(board, %{id: user_id}) do
    if Boards.get_user_access(board.id, user_id) in [:owner, :modify] do
      :ok
    else
      {:error, :not_authorized_write}
    end
  end

  @doc """
  Fetches a task by numeric id or identifier, scoped to `board`.

  Returns `{:ok, task}`, `{:error, :not_found}` or `{:error, :forbidden}`.
  """
  def fetch_task(id_or_identifier, board) do
    case get_task_by_id_or_identifier(id_or_identifier, board) do
      nil -> {:error, :not_found}
      task -> verify_board_ownership(task, board)
    end
  end

  defp get_task_by_id_or_identifier(id_or_identifier, board) do
    case Integer.parse(id_or_identifier) do
      {id, ""} when id in @bigint_range ->
        # Board-scope the numeric-id lookup so a cross-board id and a
        # nonexistent id both resolve to nil → 404. Fetching globally and
        # letting verify_board_ownership distinguish them downstream returned
        # 403 for a cross-board id vs 404 for a missing one — a task-existence
        # oracle (D160), the same class W399 closed for column lookups.
        if Tasks.get_task_for_board(id, board.id), do: Tasks.get_task_for_view(id)

      {_out_of_range_id, ""} ->
        # D360: a whole number no task id can hold is simply "not found" —
        # the same nil (and so the same 404 body) as a missing in-range id,
        # decided without a query and without trying the identifier branch.
        nil

      _ ->
        get_task_by_identifier(id_or_identifier, board)
    end
  end

  # An identifier like "W14". Text PostgreSQL cannot hold as a query parameter
  # (invalid UTF-8, or a NUL character) names no task, so it is the same nil,
  # and the same 404, as a missing identifier rather than a database error.
  defp get_task_by_identifier(identifier, board) do
    if String.valid?(identifier) and not String.contains?(identifier, <<0>>) do
      column_ids = board |> Columns.list_columns() |> Enum.map(& &1.id)
      Tasks.get_task_by_identifier_for_view(identifier, column_ids)
    end
  end

  defp verify_board_ownership(%{column: %{board_id: board_id}} = task, %{id: board_id}),
    do: {:ok, task}

  defp verify_board_ownership(_, _), do: {:error, :forbidden}

  @doc """
  Validates a blocking hook result. `{:error, {:hook_failed, hook, reason}}`
  on failure.
  """
  def validate_hook(result, hook_name) do
    case Validator.validate_hook_execution(result, hook_name, blocking: true) do
      :ok -> :ok
      {:error, reason} -> {:error, {:hook_failed, hook_name, reason}}
    end
  end

  @doc """
  D137: remembers the token's last-seen agent identity from the raw request
  param — never the "Unknown" fallback the claim/complete paths default to.
  Best-effort: a failed stamp never fails the parent request.
  """
  def stamp_agent_identity(conn, params) do
    ApiTokens.stamp_last_agent_name(conn.assigns.api_token, params["agent_name"])
  end

  @doc """
  W2054: the single resolution point for the opt-in slim response view. Only
  the exact string "slim" opts in — absent, "full", malformed and
  unrecognised values all resolve to :full, because a crash on an unexpected
  param is a worse failure than a fat response. The value is
  attacker-controllable and is therefore matched as a literal string and never
  converted with String.to_atom/1, which would be an atom-exhaustion vector.
  """
  def view_for(params) do
    case params["response_view"] do
      "slim" -> :slim
      _ -> :full
    end
  end

  @doc """
  Emits `[:kanban, :api, event_name]` with the token's board and user and the
  request path and method, so a REST call and an MCP call (path `/api/mcp`)
  are distinguishable.
  """
  def emit_telemetry(conn, event_name, metadata) do
    :telemetry.execute(
      [:kanban, :api, event_name],
      %{count: 1},
      Map.merge(metadata, %{
        board_id: conn.assigns.current_board.id,
        user_id: conn.assigns.current_user.id,
        path: conn.request_path,
        method: conn.method
      })
    )
  end

  @doc """
  D360: board-scoped column lookup that answers nil, the same as a missing or
  cross-board column, for a well-formed integer outside the bigint range, so
  it 404s instead of raising in Postgrex. parse_id/1 stays unbounded on
  purpose: its :error means "not an integer" (a 400), which an out-of-range
  integer is not.
  """
  def column_for_board(column_id, board_id) when column_id in @bigint_range,
    do: Columns.get_column_for_board(column_id, board_id)

  def column_for_board(_out_of_range_column_id, _board_id), do: nil

  @doc """
  Parses an integer id from an integer or a whole-number string.
  """
  def parse_id(id) when is_integer(id), do: {:ok, id}

  def parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> {:ok, int_id}
      _ -> :error
    end
  end

  def parse_id(_), do: :error
end
