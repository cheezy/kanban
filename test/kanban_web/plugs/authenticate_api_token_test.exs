defmodule KanbanWeb.Plugs.AuthenticateApiTokenTest do
  use KanbanWeb.ConnCase

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Repo
  alias KanbanWeb.Plugs.AuthenticateApiToken

  setup do
    user = user_fixture()
    board = board_fixture(user)

    {:ok, {api_token, plain_text_token}} =
      ApiTokens.create_api_token(user, board, %{
        name: "Test Token"
      })

    %{user: user, board: board, api_token: api_token, plain_text_token: plain_text_token}
  end

  describe "call/2" do
    test "authenticates valid Bearer token and assigns current_user and api_token", %{
      conn: conn,
      user: user,
      api_token: api_token,
      plain_text_token: plain_text_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{plain_text_token}")
        |> AuthenticateApiToken.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.api_token.id == api_token.id
    end

    test "returns 401 for missing Authorization header", %{conn: conn} do
      conn = AuthenticateApiToken.call(conn, [])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "missing token emits auth_failed", %{conn: conn} do
      attach_telemetry([:kanban, :api, :auth_failed])

      conn = AuthenticateApiToken.call(conn, [])

      assert conn.status == 401

      assert_receive {:telemetry_event, [:kanban, :api, :auth_failed], %{count: 1}, metadata}
      assert %{reason: "missing_token", path: _path, method: _method} = metadata
      assert metadata |> Map.keys() |> Enum.sort() == [:method, :path, :reason]
    end

    test "a non-Bearer Authorization header also reports missing_token", %{conn: conn} do
      attach_telemetry([:kanban, :api, :auth_failed])

      conn
      |> put_req_header("authorization", "InvalidFormat token123")
      |> AuthenticateApiToken.call([])

      assert_receive {:telemetry_event, [:kanban, :api, :auth_failed], _,
                      %{reason: "missing_token"}}
    end

    test "returns 401 for invalid token format", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "InvalidFormat token123")
        |> AuthenticateApiToken.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 for non-existent token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token_12345")
        |> AuthenticateApiToken.call([])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401) == %{"error" => "Invalid API token"}
    end

    test "returns the uniform 401 body for a revoked token", %{
      conn: conn,
      api_token: api_token,
      plain_text_token: plain_text_token
    } do
      {:ok, _revoked} = ApiTokens.revoke_api_token(api_token)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{plain_text_token}")
        |> AuthenticateApiToken.call([])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401) == %{"error" => "Invalid API token"}
    end

    test "not_found, revoked, and expired all return an identical 401 body", %{
      conn: base_conn,
      user: user,
      board: board,
      api_token: api_token,
      plain_text_token: plain_text_token
    } do
      # not_found
      not_found_conn =
        base_conn
        |> put_req_header("authorization", "Bearer does_not_exist")
        |> AuthenticateApiToken.call([])

      # revoked
      {:ok, _} = ApiTokens.revoke_api_token(api_token)

      revoked_conn =
        base_conn
        |> put_req_header("authorization", "Bearer #{plain_text_token}")
        |> AuthenticateApiToken.call([])

      # expired (fresh token pushed past its expiry)
      {:ok, {expired_token, expired_plain}} =
        ApiTokens.create_api_token(user, board, %{name: "Expiring Token"})

      expire_token(expired_token)

      expired_conn =
        base_conn
        |> put_req_header("authorization", "Bearer #{expired_plain}")
        |> AuthenticateApiToken.call([])

      uniform = %{"error" => "Invalid API token"}
      assert json_response(not_found_conn, 401) == uniform
      assert json_response(revoked_conn, 401) == uniform
      assert json_response(expired_conn, 401) == uniform
    end

    test "telemetry still carries the distinct reason for each failure mode", %{
      conn: base_conn,
      user: user,
      board: board,
      api_token: api_token,
      plain_text_token: plain_text_token
    } do
      test_pid = self()
      handler_id = "auth-failed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:kanban, :api, :auth_failed],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:auth_failed, metadata.reason})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      base_conn
      |> put_req_header("authorization", "Bearer does_not_exist")
      |> AuthenticateApiToken.call([])

      assert_receive {:auth_failed, "token_not_found"}

      {:ok, _} = ApiTokens.revoke_api_token(api_token)

      base_conn
      |> put_req_header("authorization", "Bearer #{plain_text_token}")
      |> AuthenticateApiToken.call([])

      assert_receive {:auth_failed, "token_revoked"}

      {:ok, {expired_token, expired_plain}} =
        ApiTokens.create_api_token(user, board, %{name: "Expiring Token"})

      expire_token(expired_token)

      base_conn
      |> put_req_header("authorization", "Bearer #{expired_plain}")
      |> AuthenticateApiToken.call([])

      assert_receive {:auth_failed, "token_expired"}
    end

    # The response must stay the generic invalid-token error rather than report
    # the owner's account state back to the caller.
    test "returns 401 for a valid token whose owner is disabled", %{
      conn: conn,
      user: user,
      plain_text_token: plain_text_token
    } do
      {:ok, _} = Kanban.Accounts.disable_user(user, admin_fixture())

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{plain_text_token}")
        |> AuthenticateApiToken.call([])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401) == %{"error" => "Invalid API token"}
      refute conn.assigns[:current_user]
    end

    test "authenticates again once a disabled owner is re-enabled", %{
      conn: conn,
      user: user,
      plain_text_token: plain_text_token
    } do
      {:ok, disabled} = Kanban.Accounts.disable_user(user, admin_fixture())
      {:ok, _} = Kanban.Accounts.enable_user(disabled, admin_fixture())

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{plain_text_token}")
        |> AuthenticateApiToken.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "updates last_used_at timestamp on successful authentication", %{
      conn: conn,
      api_token: api_token,
      plain_text_token: plain_text_token
    } do
      assert api_token.last_used_at == nil

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{plain_text_token}")
        |> AuthenticateApiToken.call([])

      refute conn.halted

      updated_token = ApiTokens.get_api_token!(api_token.id)
      assert updated_token.last_used_at != nil
    end
  end

  # Pushes a token past its expiry directly in the DB — create_api_token offers
  # no way to backdate expires_at.
  defp expire_token(api_token) do
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    query = from(t in Kanban.ApiTokens.ApiToken, where: t.id == ^api_token.id)
    {1, _} = Kanban.Repo.update_all(query, set: [expires_at: past])

    :ok
  end

  describe "workspace tokens (W2220)" do
    setup do
      organization = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(organization, admin, :org_admin)
      workspace = org_workspace_fixture(organization)
      board_a = workspace_board(workspace)
      board_b = workspace_board(workspace)

      {:ok, {api_token, plain}} =
        ApiTokens.create_workspace_api_token(admin, workspace, %{name: "Fleet"})

      %{
        organization: organization,
        admin: admin,
        workspace: workspace,
        board_a: board_a,
        board_b: board_b,
        ws_token: api_token,
        ws_plain: plain
      }
    end

    test "the X-Stride-Board header selects a board in the workspace", ctx do
      conn = call_with(ctx.conn, ctx.ws_plain, header: "#{ctx.board_a.id}")

      refute conn.halted
      assert conn.assigns.current_board.id == ctx.board_a.id
      assert conn.assigns.current_board.workspace.id == ctx.workspace.id
      assert conn.assigns.current_user.id == ctx.admin.id
      assert conn.assigns.api_token.id == ctx.ws_token.id
    end

    test "the board_id param selects a board, as an integer or a string", ctx do
      for value <- [
            ctx.board_b.id,
            "#{ctx.board_b.id}",
            " #{ctx.board_b.id} ",
            "00#{ctx.board_b.id}"
          ] do
        conn = call_with(ctx.conn, ctx.ws_plain, param: value)

        refute conn.halted
        assert conn.assigns.current_board.id == ctx.board_b.id
      end
    end

    test "a header and a param naming the same board are accepted", ctx do
      conn = call_with(ctx.conn, ctx.ws_plain, header: "#{ctx.board_a.id}", param: ctx.board_a.id)

      refute conn.halted
      assert conn.assigns.current_board.id == ctx.board_a.id
    end

    test "a header and a param that disagree get 400", ctx do
      conn = call_with(ctx.conn, ctx.ws_plain, header: "#{ctx.board_a.id}", param: ctx.board_b.id)

      assert conn.halted

      assert %{"error" => "Conflicting board selectors", "message" => _} =
               json_response(conn, 400)

      refute Map.has_key?(conn.assigns, :current_board)
    end

    test "a repeated X-Stride-Board header gets 400", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer #{ctx.ws_plain}")
        |> Map.update!(:req_headers, fn headers ->
          headers ++
            [{"x-stride-board", "#{ctx.board_a.id}"}, {"x-stride-board", "#{ctx.board_a.id}"}]
        end)
        |> AuthenticateApiToken.call([])

      assert %{"error" => "Conflicting board selectors"} = json_response(conn, 400)
    end

    test "no board selector gets 400 with an explanatory message", ctx do
      for opts <- [[], [header: "  "], [param: ""]] do
        conn = call_with(ctx.conn, ctx.ws_plain, opts)

        assert conn.halted
        body = json_response(conn, 400)
        assert body["error"] == "Board selector required"
        assert body["message"] =~ "X-Stride-Board"
        assert body["message"] =~ "GET /api/boards"
        refute Map.has_key?(conn.assigns, :current_board)
      end
    end

    test "every board the token may not use gets the same 404 body", ctx do
      outsider = user_fixture()

      foreign_org = organization_fixture()
      foreign_board = workspace_board(org_workspace_fixture(foreign_org))
      other_workspace_board = workspace_board(org_workspace_fixture(ctx.organization))
      personal_board = ai_optimized_board_fixture(outsider)
      plain_board = place_board_in_workspace(ctx.workspace)

      selectors = [
        foreign_board.id,
        other_workspace_board.id,
        personal_board.id,
        plain_board.id,
        999_999_999,
        "abc",
        "W2220",
        "-1",
        "99999999999999999999",
        %{"id" => ctx.board_a.id}
      ]

      bodies =
        for selector <- selectors do
          conn = call_with(ctx.conn, ctx.ws_plain, param: selector)
          assert conn.halted
          refute Map.has_key?(conn.assigns, :current_board)
          json_response(conn, 404)
        end

      assert Enum.uniq(bodies) == [%{"error" => "Board not found"}]
    end

    test "a board in an archived workspace is not found", ctx do
      from(w in Kanban.Workspaces.Workspace, where: w.id == ^ctx.workspace.id)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now(:second)])

      conn = call_with(ctx.conn, ctx.ws_plain, header: "#{ctx.board_a.id}")

      assert json_response(conn, 404) == %{"error" => "Board not found"}
    end

    test "a token whose user stops being an org-admin keeps only explicit board access", ctx do
      Repo.insert!(%Kanban.Boards.BoardUser{
        board_id: ctx.board_a.id,
        user_id: ctx.admin.id,
        access: :modify
      })

      Repo.insert!(%Kanban.Boards.BoardUser{
        board_id: ctx.board_b.id,
        user_id: ctx.admin.id,
        access: :read_only
      })

      from(m in Kanban.Organizations.OrganizationMember, where: m.user_id == ^ctx.admin.id)
      |> Repo.update_all(set: [role: :member])

      conn = call_with(build_conn(), ctx.ws_plain, header: "#{ctx.board_a.id}")
      refute conn.halted
      assert conn.assigns.current_board.id == ctx.board_a.id

      conn = call_with(build_conn(), ctx.ws_plain, header: "#{ctx.board_b.id}")
      assert json_response(conn, 404) == %{"error" => "Board not found"}
    end

    test "a board moved into the workspace after the token was created is reachable", ctx do
      later = ai_optimized_board_fixture(user_fixture())
      conn = call_with(ctx.conn, ctx.ws_plain, header: "#{later.id}")
      assert json_response(conn, 404) == %{"error" => "Board not found"}

      from(b in Kanban.Boards.Board, where: b.id == ^later.id)
      |> Repo.update_all(set: [workspace_id: ctx.workspace.id])

      conn = call_with(build_conn(), ctx.ws_plain, header: "#{later.id}")
      refute conn.halted
      assert conn.assigns.current_board.id == later.id
    end

    test "a board token ignores board selectors", %{conn: conn, board: board} = ctx do
      conn = call_with(conn, ctx.plain_text_token, header: "#{ctx.board_a.id}", param: "nope")

      refute conn.halted
      assert conn.assigns.current_board.id == board.id
    end

    test "a board-optional route takes a workspace token without a selector", ctx do
      conn =
        ctx.conn
        |> put_private(:stride_board_selector, :optional)
        |> call_with(ctx.ws_plain, [])

      refute conn.halted
      assert conn.assigns.api_token.id == ctx.ws_token.id
      refute Map.has_key?(conn.assigns, :current_board)
    end

    test "selector failures emit auth_failed with their reason and audit a 404", ctx do
      attach_telemetry([:kanban, :api, :auth_failed])

      call_with(ctx.conn, ctx.ws_plain, [])

      assert_receive {:telemetry_event, [:kanban, :api, :auth_failed], _,
                      %{reason: "board_selector_missing"}}

      call_with(build_conn(), ctx.ws_plain, header: "1", param: "2")

      assert_receive {:telemetry_event, [:kanban, :api, :auth_failed], _,
                      %{reason: "board_selector_conflict"}}

      call_with(build_conn(), ctx.ws_plain, param: "999999999")
      assert_receive {:telemetry_event, [:kanban, :api, :auth_failed], _, metadata}
      assert metadata.reason == "board_not_found"
      assert metadata |> Map.keys() |> Enum.sort() == [:method, :path, :reason]

      assert from(e in Kanban.AuditLog.AuditEvent,
               where: e.action == "permission_denied" and e.actor_user_id == ^ctx.admin.id
             )
             |> Repo.exists?()
    end

    test "selector failures do not count toward the failed-authentication rate limit", ctx do
      original = Application.get_env(:kanban, Kanban.RateLimit)
      Application.put_env(:kanban, Kanban.RateLimit, enabled: true)
      on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

      ip = {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}

      for _ <- 1..25 do
        conn = call_with(%{build_conn() | remote_ip: ip}, ctx.ws_plain, param: "999999999")
        assert conn.status == 404
      end

      assert :ok = Kanban.RateLimit.peek(:api_token, ip: ip)
    end
  end

  defp call_with(conn, plain, opts) do
    conn = put_req_header(conn, "authorization", "Bearer #{plain}")

    conn =
      case Keyword.fetch(opts, :header) do
        {:ok, value} -> put_req_header(conn, "x-stride-board", value)
        :error -> conn
      end

    conn =
      case Keyword.fetch(opts, :param) do
        {:ok, value} -> %{conn | params: %{"board_id" => value}}
        :error -> %{conn | params: %{}}
      end

    AuthenticateApiToken.call(conn, [])
  end

  # An AI Optimized board, owned by a new user, moved into `workspace`.
  defp workspace_board(workspace) do
    board = ai_optimized_board_fixture(user_fixture())

    {1, _} =
      from(b in Kanban.Boards.Board, where: b.id == ^board.id)
      |> Repo.update_all(set: [workspace_id: workspace.id])

    Repo.reload!(board)
  end
end
