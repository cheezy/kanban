defmodule KanbanWeb.API.BoardReadAccessTest do
  @moduledoc """
  A board token's reads re-check its user's live access to the board on every
  request. The access is lost here by editing the rows directly, the way an
  access-loss path that does not revoke the token would leave them.
  """
  use KanbanWeb.ConnCase

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.User
  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.AuditLog
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Tasks
  alias KanbanWeb.API.BoardReadAccess
  alias KanbanWeb.API.TaskErrors

  @moduletag capture_log: true

  # The public routes and the 405-only GET /api/mcp read no board.
  @not_board_reads ["/api/agent/onboarding", "/api/openapi.json", "/api/mcp"]

  setup do
    owner = user_fixture()
    member = user_fixture()
    board = ai_optimized_board_fixture(owner)
    Repo.insert!(%BoardUser{board_id: board.id, user_id: member.id, access: :modify})
    task = ready_task(board, owner)

    %{owner: owner, member: member, board: board, task: task}
  end

  describe "a board token whose user was removed from the board" do
    setup %{conn: conn, board: board, member: member} do
      conn = authed(conn, board_token(member, board))
      remove_board_user(board, member)
      %{conn: conn}
    end

    test "is refused with the documented 403 on every task read", %{conn: conn, task: task} do
      for path <- task_read_paths(task) do
        assert conn |> get(path) |> json_response(403) == not_authorized_body(), path
      end
    end

    test "is refused on GET /api/boards", %{conn: conn} do
      assert conn |> get(~p"/api/boards") |> json_response(403) == not_authorized_body()
    end

    test "is refused on every authenticated GET route in the router", %{conn: conn, task: task} do
      paths = authenticated_get_paths(task)

      assert length(paths) >= 9

      for path <- paths do
        assert conn |> get(path) |> json_response(403) == not_authorized_body(), path
      end
    end

    test "records a permission_denied audit event", %{conn: conn, member: member} do
      conn |> get(~p"/api/tasks/next") |> json_response(403)

      assert [event] = AuditLog.list_events(action: :permission_denied, actor_user_id: member.id)
      assert event.metadata["gate"] == "api_board_read"
    end

    test "gets the 403 as an isError result from every MCP read tool", %{conn: conn, task: task} do
      for {name, args} <- [
            {"stride_next_task", %{}},
            {"stride_get_task", %{"id" => task.identifier}},
            {"stride_list_tasks", %{}}
          ] do
        assert {true, body} = call_tool(conn, name, args)
        assert body["http_status"] == 403, name
        assert body["error_code"] == "not_authorized", name
        assert body["error"] == "Not authorized — board membership required", name
      end
    end

    test "keeps the write endpoints' own documented refusals", %{conn: conn, task: task} do
      assert %{"error" => "Not authorized — board write access (owner or modify) required"} =
               conn
               |> post(~p"/api/tasks", %{"task" => %{"title" => "New"}})
               |> json_response(403)

      assert {true, %{"error_code" => "not_authorized_to_claim", "http_status" => 403}} =
               call_tool(conn, "stride_claim_task", %{
                 "identifier" => task.identifier,
                 "before_doing_result" => %{
                   "exit_code" => 0,
                   "output" => "ok",
                   "duration_ms" => 1
                 }
               })
    end
  end

  describe "a board token of an org-admin with derived access" do
    setup %{conn: conn} do
      organization = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(organization, admin, :org_admin)
      board = workspace_board(org_workspace_fixture(organization))
      task = ready_task(board, admin)

      %{conn: authed(conn, board_token(admin, board)), admin: admin, task: task}
    end

    test "reads while the user is org-admin", %{conn: conn, task: task} do
      for path <- task_read_paths(task) do
        assert conn |> get(path) |> response(200), path
      end
    end

    test "is refused once the user is no longer org-admin", %{
      conn: conn,
      admin: admin,
      task: task
    } do
      {1, _} =
        from(m in OrganizationMember, where: m.user_id == ^admin.id)
        |> Repo.update_all(set: [role: :member])

      for path <- task_read_paths(task) do
        assert conn |> get(path) |> json_response(403) == not_authorized_body(), path
      end

      assert {true, %{"http_status" => 403}} = call_tool(conn, "stride_list_tasks", %{})
    end

    test "is refused once the user left the Organization", %{conn: conn, admin: admin} do
      {1, _} = OrganizationMember |> where(user_id: ^admin.id) |> Repo.delete_all()

      assert conn |> get(~p"/api/tasks") |> json_response(403) == not_authorized_body()
    end
  end

  describe "a board token whose user was disabled" do
    test "is refused with the generic 401 on reads", %{conn: conn, board: board, member: member} do
      conn = authed(conn, board_token(member, board))

      {1, _} =
        from(u in User, where: u.id == ^member.id)
        |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

      for path <- [~p"/api/tasks", ~p"/api/tasks/next", ~p"/api/boards"] do
        assert conn |> get(path) |> json_response(401) == %{"error" => "Invalid API token"}
      end
    end
  end

  describe "a board token whose user still has access" do
    test "reads with modify access", %{conn: conn, board: board, member: member, task: task} do
      conn = authed(conn, board_token(member, board))

      for path <- task_read_paths(task), do: assert(conn |> get(path) |> response(200), path)
      assert conn |> get(~p"/api/boards") |> json_response(200)
      assert {false, _} = call_tool(conn, "stride_get_task", %{"id" => task.identifier})
    end

    test "reads with read-only access", %{conn: conn, board: board, member: member, task: task} do
      conn = authed(conn, board_token(member, board))

      {1, _} =
        from(bu in BoardUser, where: bu.board_id == ^board.id and bu.user_id == ^member.id)
        |> Repo.update_all(set: [access: :read_only])

      for path <- task_read_paths(task), do: assert(conn |> get(path) |> response(200), path)
      assert {false, _} = call_tool(conn, "stride_list_tasks", %{})
    end

    test "writes no audit event", %{conn: conn, board: board, owner: owner} do
      conn |> authed(board_token(owner, board)) |> get(~p"/api/tasks") |> json_response(200)

      assert AuditLog.list_events(action: :permission_denied, actor_user_id: owner.id) == []
    end
  end

  describe "workspace tokens" do
    setup %{conn: conn} do
      organization = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(organization, admin, :org_admin)
      workspace = org_workspace_fixture(organization)
      board = workspace_board(workspace)
      task = ready_task(board, admin)

      {:ok, {_, plain}} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "Fleet"})

      %{conn: authed(conn, plain), board: board, task: task}
    end

    test "read a selected board as before", %{conn: conn, board: board, task: task} do
      conn = put_req_header(conn, "x-stride-board", Integer.to_string(board.id))

      for path <- task_read_paths(task), do: assert(conn |> get(path) |> response(200), path)
      assert {false, _} = call_tool(conn, "stride_list_tasks", %{})
    end

    test "list their boards without a selector", %{conn: conn, board: board} do
      assert %{"data" => [%{"id" => id}]} = conn |> get(~p"/api/boards") |> json_response(200)
      assert id == board.id
    end
  end

  describe "authorize/1" do
    test "passes a board token whose user has access", %{board: board, member: member} do
      conn = token_conn(%ApiToken{workspace_id: nil}, board, member)
      assert BoardReadAccess.authorize(conn) == :ok
    end

    test "refuses a board token whose user has no access", %{board: board} do
      outsider = user_fixture()

      conn = token_conn(%ApiToken{workspace_id: nil}, board, outsider)
      assert BoardReadAccess.authorize(conn) == {:error, :not_authorized}
    end

    test "passes a workspace token without checking a board", %{board: board} do
      outsider = user_fixture()

      conn = token_conn(%ApiToken{workspace_id: 1}, board, outsider)
      assert BoardReadAccess.authorize(conn) == :ok

      no_board =
        :get |> Plug.Test.conn("/") |> Plug.Conn.assign(:api_token, %ApiToken{workspace_id: 1})

      assert BoardReadAccess.authorize(no_board) == :ok
    end

    test "refuses a request without a token" do
      conn = Plug.Test.conn(:get, "/")
      assert BoardReadAccess.authorize(conn) == {:error, :not_authorized}
    end
  end

  describe "call/2" do
    test "halts with the documented 403 body when refused", %{board: board} do
      conn =
        %ApiToken{workspace_id: nil}
        |> token_conn(board, user_fixture())
        |> Phoenix.Controller.put_format("json")
        |> BoardReadAccess.call(BoardReadAccess.init([]))

      assert conn.halted
      assert json_response(conn, 403) == not_authorized_body()
    end

    test "lets an authorized request through", %{board: board, member: member} do
      conn =
        %ApiToken{workspace_id: nil}
        |> token_conn(board, member)
        |> BoardReadAccess.call([])

      refute conn.halted
      refute conn.state == :sent
    end
  end

  defp task_read_paths(task) do
    [
      ~p"/api/tasks",
      ~p"/api/tasks?limit=10",
      ~p"/api/tasks/#{task.id}",
      ~p"/api/tasks/#{task.id}?fields=title",
      ~p"/api/tasks/next",
      ~p"/api/tasks/#{task.id}/dependencies",
      ~p"/api/tasks/#{task.id}/dependents",
      ~p"/api/tasks/#{task.id}/tree",
      ~p"/api/tasks/#{task.id}/after_goal_status",
      ~p"/api/tasks/#{task.id}/comments"
    ]
  end

  # Every GET route behind the token plug, so a read endpoint added later
  # without the check fails here.
  defp authenticated_get_paths(task) do
    id = Integer.to_string(task.id)

    KanbanWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.flat_map(&api_get_path/1)
    |> Enum.map(&String.replace(&1, ":id", id))
  end

  defp api_get_path(%{verb: :get, path: "/api/" <> _ = path}),
    do: if(path in @not_board_reads, do: [], else: [path])

  defp api_get_path(_route), do: []

  defp not_authorized_body do
    {:forbidden, :not_authorized, body} = TaskErrors.error_body(:not_authorized)
    body |> Jason.encode!() |> Jason.decode!()
  end

  defp token_conn(api_token, board, user) do
    Plug.Test.conn(:get, "/")
    |> Plug.Conn.assign(:api_token, api_token)
    |> Plug.Conn.assign(:current_board, board)
    |> Plug.Conn.assign(:current_user, user)
  end

  defp board_token(user, board) do
    {:ok, {_, plain}} = ApiTokens.create_api_token(user, board, %{name: "Agent"})
    plain
  end

  defp authed(conn, plain) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{plain}")
  end

  defp remove_board_user(board, user) do
    {1, _} = BoardUser |> where(board_id: ^board.id, user_id: ^user.id) |> Repo.delete_all()
  end

  defp call_tool(conn, name, args) do
    result =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => name, "arguments" => args}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")

    [%{"type" => "text", "text" => text}] = result["content"]
    {result["isError"], Jason.decode!(text)}
  end

  defp ready_task(board, user) do
    ready = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))

    {:ok, task} =
      Tasks.create_task(ready, %{
        "title" => "A task",
        "status" => "open",
        "created_by_id" => user.id,
        "needs_review" => false
      })

    task
  end

  defp workspace_board(workspace) do
    board = ai_optimized_board_fixture(user_fixture())

    {1, _} =
      from(b in Board, where: b.id == ^board.id)
      |> Repo.update_all(set: [workspace_id: workspace.id])

    Repo.reload!(board)
  end
end
