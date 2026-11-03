defmodule KanbanWeb.API.TaskAttachmentsResponseTest do
  @moduledoc """
  `data.attachments` (W2516) on the responses that carry it — the full
  `GET /api/tasks/:id`, `POST /api/tasks/claim` and the MCP `stride_get_task`
  and `stride_claim_task` tools — and its absence everywhere else.
  """
  # async: false - the plan tests switch the global :plans_enforced
  # application env on through Kanban.PlansHelpers.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards.Board
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.API.TaskFieldsProjection
  alias KanbanWeb.MCP.Tools

  @moduletag capture_log: true

  @keys ~w(byte_size comment_id content_type download_url filename id sha256 uploaded_at)
  @refused [:kanban, :plan, :feature_refused]
  @hook %{"exit_code" => 0, "output" => "ok", "duration_ms" => 10}

  setup %{conn: conn} do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)

    {:ok, {api_token, plain}} =
      ApiTokens.create_api_token(user, board, %{
        "name" => "Attachments",
        "agent_capabilities" => ["code_generation"]
      })

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{plain}")

    ready = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))

    %{conn: conn, user: user, board: board, ready: ready, api_token: api_token}
  end

  defp ready_task(ctx, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        ctx.ready,
        Map.merge(
          %{
            "title" => "Attached task",
            "status" => "open",
            "created_by_id" => ctx.user.id,
            "needs_review" => false
          },
          attrs
        )
      )

    task
  end

  defp comment_on(task),
    do: Repo.insert!(%TaskComment{task_id: task.id, content: "Here is the log"})

  defp at(seconds), do: NaiveDateTime.add(~N[2026-10-01 08:00:00], seconds)

  defp ids(body), do: Enum.map(body["data"]["attachments"], & &1["id"])

  defp make_paid(%Board{id: id}) do
    workspace = org_workspace_fixture(organization_fixture())

    {1, _} =
      Board |> where([b], b.id == ^id) |> Repo.update_all(set: [workspace_id: workspace.id])

    workspace
  end

  defp mcp_conn(ctx) do
    :post
    |> Phoenix.ConnTest.build_conn("/api/mcp")
    |> Plug.Conn.assign(:current_user, ctx.user)
    |> Plug.Conn.assign(:current_board, Repo.get!(Board, ctx.board.id))
    |> Plug.Conn.assign(:api_token, ctx.api_token)
  end

  defp text_body(%{content: [%{type: "text", text: text}]}), do: Jason.decode!(text)

  describe "full show" do
    test "GET /api/tasks/:id lists task and comment attachments oldest first", ctx do
      task = ready_task(ctx)
      comment = comment_on(task)
      newest = attachment_fixture(task, %{inserted_at: at(30), filename: ~s(say "hi".txt)})
      on_comment = attachment_fixture(task, %{comment: comment, inserted_at: at(10)})
      oldest = attachment_fixture(task, %{inserted_at: at(0), filename: "résumé.txt"})
      dotted = attachment_fixture(task, %{inserted_at: at(20), filename: ".env.txt"})

      for id <- [Integer.to_string(task.id), task.identifier] do
        body = ctx.conn |> get(~p"/api/tasks/#{id}") |> json_response(200)

        assert ids(body) == [oldest.id, on_comment.id, dotted.id, newest.id]

        [first, second, third, fourth] = body["data"]["attachments"]

        for object <- [first, second, third, fourth],
            do: assert(object |> Map.keys() |> Enum.sort() == @keys)

        assert first == %{
                 "id" => oldest.id,
                 "filename" => "résumé.txt",
                 "content_type" => "text/plain",
                 "byte_size" => 12,
                 "sha256" => oldest.sha256,
                 "comment_id" => nil,
                 "uploaded_at" => "2026-10-01T08:00:00Z",
                 "download_url" => "/api/tasks/#{task.id}/attachments/#{oldest.id}"
               }

        assert second["comment_id"] == comment.id
        assert third["filename"] == ".env.txt"
        assert fourth["filename"] == ~s(say "hi".txt)
      end
    end

    test "a comment's attachments go when the comment is deleted", ctx do
      task = ready_task(ctx)
      comment = comment_on(task)
      kept = attachment_fixture(task)
      attachment_fixture(task, %{comment: comment})

      Repo.delete!(comment)

      body = ctx.conn |> get(~p"/api/tasks/#{task.id}") |> json_response(200)
      assert ids(body) == [kept.id]
    end

    test "a goal and a task at the per-task cap list every attachment in order", ctx do
      {:ok, goal} =
        Tasks.create_task(ctx.ready, %{
          "title" => "Attached goal",
          "type" => "goal",
          "created_by_id" => ctx.user.id
        })

      rows = for i <- 1..20, do: attachment_fixture(goal, %{inserted_at: at(rem(i, 3))})
      expected = rows |> Enum.sort_by(&{&1.inserted_at, &1.id}, :asc) |> Enum.map(& &1.id)

      body = ctx.conn |> get(~p"/api/tasks/#{goal.id}") |> json_response(200)
      assert ids(body) == expected
    end

    test "a task with no attachments returns an empty list", ctx do
      task = ready_task(ctx)

      body = ctx.conn |> get(~p"/api/tasks/#{task.id}") |> json_response(200)

      assert Map.has_key?(body["data"], "attachments")
      assert body["data"]["attachments"] == []
    end
  end

  describe "claim" do
    test "POST /api/tasks/claim carries data.attachments", ctx do
      task = ready_task(ctx)
      attachment = attachment_fixture(task, %{inserted_at: at(5)})
      older = attachment_fixture(task, %{comment: comment_on(task), inserted_at: at(1)})

      body =
        ctx.conn
        |> post(~p"/api/tasks/claim", %{
          "identifier" => task.identifier,
          "agent_name" => "Attachments agent",
          "before_doing_result" => @hook
        })
        |> json_response(200)

      assert body["data"]["identifier"] == task.identifier
      assert body["hook"]["name"] == "before_doing"
      assert ids(body) == [older.id, attachment.id]
      refute Map.has_key?(body, "attachments")
    end
  end

  describe "MCP" do
    test "MCP stride_get_task and stride_claim_task carry data.attachments", ctx do
      task = ready_task(ctx)
      attachment = attachment_fixture(task)
      conn = mcp_conn(ctx)

      assert {:ok, %{isError: false} = got} =
               Tools.call("stride_get_task", %{"id" => task.id}, conn)

      assert ids(text_body(got)) == [attachment.id]

      assert {:ok, %{isError: false} = claimed} =
               Tools.call(
                 "stride_claim_task",
                 %{
                   "identifier" => task.identifier,
                   "agent_name" => "MCP agent",
                   "before_doing_result" => @hook
                 },
                 conn
               )

      claimed = text_body(claimed)
      assert claimed["data"]["status"] == "in_progress"
      assert ids(claimed) == [attachment.id]
    end
  end

  describe "plan visibility" do
    setup :enforce_plans

    test "a free board under enforcement returns attachments as an empty list", ctx do
      task = ready_task(ctx)
      attachment_fixture(task)
      attach_telemetry(@refused)

      shown = ctx.conn |> get(~p"/api/tasks/#{task.id}") |> json_response(200)
      assert shown["data"]["attachments"] == []

      claimed =
        ctx.conn
        |> post(~p"/api/tasks/claim", %{
          "identifier" => task.identifier,
          "before_doing_result" => @hook
        })
        |> json_response(200)

      assert claimed["data"]["attachments"] == []
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "a paid board under enforcement lists its attachments", ctx do
      make_paid(ctx.board)
      task = ready_task(ctx)
      attachment = attachment_fixture(task)

      body = ctx.conn |> get(~p"/api/tasks/#{task.id}") |> json_response(200)
      assert ids(body) == [attachment.id]
    end

    test "a workspace token naming the board with X-Stride-Board sees the same attachments",
         ctx do
      workspace = make_paid(ctx.board)
      admin = user_fixture()

      organization_member_fixture(
        Repo.preload(workspace, :organization).organization,
        admin,
        :org_admin
      )

      {:ok, {_, plain}} =
        ApiTokens.create_workspace_api_token(admin, workspace, %{
          name: "Fleet",
          agent_capabilities: ["code_generation"]
        })

      task = ready_task(ctx)
      attachment = attachment_fixture(task, %{inserted_at: at(2)})
      older = attachment_fixture(task, %{inserted_at: at(1)})

      board_token = ctx.conn |> get(~p"/api/tasks/#{task.id}") |> json_response(200)

      workspace_token =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain}")
        |> put_req_header("x-stride-board", Integer.to_string(ctx.board.id))
        |> get(~p"/api/tasks/#{task.id}")
        |> json_response(200)

      assert ids(workspace_token) == [older.id, attachment.id]
      assert workspace_token["data"]["attachments"] == board_token["data"]["attachments"]
    end
  end

  describe "responses without attachments" do
    test "slim view, task list, tree and complete responses omit attachments", ctx do
      task = ready_task(ctx)
      attachment_fixture(task)

      slim = ctx.conn |> get(~p"/api/tasks/#{task.id}?response_view=slim") |> json_response(200)
      refute Map.has_key?(slim["data"], "attachments")

      list = ctx.conn |> get(~p"/api/tasks") |> json_response(200)
      assert list["data"] != []
      for row <- list["data"], do: refute(Map.has_key?(row, "attachments"))

      tree = ctx.conn |> get(~p"/api/tasks/#{task.id}/tree") |> json_response(200)
      refute Map.has_key?(tree["data"]["task"], "attachments")

      ctx.conn
      |> post(~p"/api/tasks/claim", %{
        "identifier" => task.identifier,
        "before_doing_result" => @hook
      })
      |> json_response(200)

      completed =
        ctx.conn
        |> patch(~p"/api/tasks/#{task.id}/complete", %{
          "completion_summary" => "Done",
          "actual_complexity" => "small",
          "actual_files_changed" => "1",
          "time_spent_minutes" => 1,
          "after_doing_result" => @hook,
          "before_review_result" => @hook
        })
        |> json_response(200)

      refute Map.has_key?(completed["data"], "attachments")
      refute Map.has_key?(completed, "attachments")
    end

    test "fields=attachments is rejected with 422 unknown fields", ctx do
      task = ready_task(ctx)
      attachment_fixture(task)

      conn = get(ctx.conn, ~p"/api/tasks/#{task.id}?fields=attachments")
      body = json_response(conn, 422)

      assert Jason.encode!(body) =~ TaskFieldsProjection.unknown_field_message("attachments")
      refute Map.has_key?(body, "data")
    end
  end
end
