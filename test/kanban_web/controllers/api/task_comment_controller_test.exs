defmodule KanbanWeb.API.TaskCommentControllerTest do
  use KanbanWeb.ConnCase

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.TaskComment

  setup %{conn: conn} do
    user = user_fixture(%{name: "Owner Person"})
    board = ai_optimized_board_fixture(user)

    {:ok, {token, plain_token}} =
      ApiTokens.create_api_token(user, board, %{"name" => "Comment token"})

    ready = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))
    {:ok, task} = Tasks.create_task(ready, %{"title" => "Commented", "created_by_id" => user.id})

    %{
      conn: authed(conn, plain_token),
      user: user,
      board: board,
      token: token,
      task: task
    }
  end

  defp authed(conn, plain_token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> plain_token)
  end

  defp token_conn(user, board, attrs \\ %{}) do
    {:ok, {_token, plain}} =
      ApiTokens.create_api_token(user, board, Map.merge(%{"name" => "Other"}, attrs))

    authed(build_conn(), plain)
  end

  # Identifiers are numbered per board, so the other board's first task would
  # share our task's identifier. Its second task has an identifier our board
  # does not hold, which makes the identifier lookup a genuine cross-board probe.
  defp other_board_task(own_task) do
    other_user = user_fixture()
    other_board = ai_optimized_board_fixture(other_user)
    ready = other_board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))

    tasks =
      for title <- ["Other 1", "Other 2"] do
        {:ok, task} =
          Tasks.create_task(ready, %{"title" => title, "created_by_id" => other_user.id})

        task
      end

    task = List.last(tasks)
    assert task.identifier != own_task.identifier
    task
  end

  # Inserts a comment with a fixed inserted_at so ordering is deterministic.
  defp comment_at(task, user, content, seconds_ago) do
    inserted_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-seconds_ago)
      |> NaiveDateTime.truncate(:second)

    Repo.insert!(%TaskComment{
      task_id: task.id,
      author_user_id: user && user.id,
      content: content,
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end

  defp post_comment(conn, id, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/tasks/#{id}/comments", Jason.encode!(body))
  end

  describe "GET /api/tasks/:id/comments" do
    test "lists comments oldest first by identifier and by numeric id",
         %{conn: conn, task: task, user: user} do
      comment_at(task, user, "second", 10)
      comment_at(task, user, "first", 20)

      for id <- [task.identifier, Integer.to_string(task.id)] do
        body = conn |> get(~p"/api/tasks/#{id}/comments") |> json_response(200)
        assert Enum.map(body["data"], & &1["content"]) == ["first", "second"]
        assert body["meta"] == %{"limit" => 50, "has_more" => false}
      end
    end

    test "renders every documented field", %{conn: conn, task: task, user: user} do
      comment_at(task, user, "hello", 5)

      [comment] =
        conn
        |> get(~p"/api/tasks/#{task.identifier}/comments")
        |> json_response(200)
        |> Map.fetch!("data")

      assert Map.keys(comment) |> Enum.sort() ==
               ~w(author_agent_name author_name content edited_at id inserted_at mentioned_user_ids task_id updated_at)

      assert comment["author_name"] == "Owner Person"
      assert comment["author_agent_name"] == nil
      assert comment["mentioned_user_ids"] == []
      assert comment["edited_at"] == nil
    end

    test "a comment with no author renders author_name Unknown", %{conn: conn, task: task} do
      comment_at(task, nil, "legacy", 5)

      [comment] =
        conn
        |> get(~p"/api/tasks/#{task.identifier}/comments")
        |> json_response(200)
        |> Map.fetch!("data")

      assert comment["author_name"] == "Unknown"
    end

    test "a task with no comments returns an empty list", %{conn: conn, task: task} do
      body = conn |> get(~p"/api/tasks/#{task.identifier}/comments") |> json_response(200)
      assert body["data"] == []
      assert body["meta"]["has_more"] == false
    end

    test "limit keeps the most recent comments, still oldest first",
         %{conn: conn, task: task, user: user} do
      for n <- 1..5, do: comment_at(task, user, "c#{n}", 100 - n)

      body = conn |> get(~p"/api/tasks/#{task.identifier}/comments?limit=2") |> json_response(200)

      assert Enum.map(body["data"], & &1["content"]) == ["c4", "c5"]
      assert body["meta"] == %{"limit" => 2, "has_more" => true}
    end

    test "ties on inserted_at are broken by id", %{conn: conn, task: task, user: user} do
      a = comment_at(task, user, "a", 10)
      b = comment_at(task, user, "b", 10)

      body = conn |> get(~p"/api/tasks/#{task.identifier}/comments?limit=1") |> json_response(200)

      assert [%{"id" => id}] = body["data"]
      assert id == max(a.id, b.id)
    end

    test "limit 200 is accepted", %{conn: conn, task: task} do
      body =
        conn |> get(~p"/api/tasks/#{task.identifier}/comments?limit=200") |> json_response(200)

      assert body["meta"]["limit"] == 200
    end

    test "an invalid limit is a 400", %{conn: conn, task: task} do
      for limit <- ["0", "-1", "abc", "", "201", "1.5"] do
        body =
          conn
          |> get(~p"/api/tasks/#{task.identifier}/comments?limit=#{limit}")
          |> json_response(400)

        assert body["error"] =~ "Invalid limit", "limit=#{inspect(limit)}"
      end
    end

    test "a task on another board is a 404 by identifier and by numeric id",
         %{conn: conn, task: task} do
      other = other_board_task(task)

      for id <- [other.identifier, Integer.to_string(other.id)] do
        assert conn |> get(~p"/api/tasks/#{id}/comments") |> json_response(404) ==
                 %{"error" => "Task not found"}
      end
    end

    test "an id with a NUL character or invalid UTF-8 is a 404, not a server error",
         %{conn: conn} do
      for id <- ["%00", "W1%00", "%FF"] do
        assert conn |> get("/api/tasks/#{id}/comments") |> json_response(404) ==
                 %{"error" => "Task not found"},
               id

        assert conn |> get("/api/tasks/#{id}") |> json_response(404) ==
                 %{"error" => "Task not found"},
               id
      end
    end

    test "a revoked token is a 401", %{conn: conn, token: token, task: task} do
      {:ok, _} = ApiTokens.revoke_api_token(token)
      assert conn |> get(~p"/api/tasks/#{task.identifier}/comments") |> json_response(401)
    end

    # W2215: the 401 bodies documented in docs/api/get_tasks_id_comments.md.
    test "a revoked token's 401 carries the invalid-token body",
         %{conn: conn, token: token, task: task} do
      {:ok, _} = ApiTokens.revoke_api_token(token)

      assert conn |> get(~p"/api/tasks/#{task.identifier}/comments") |> json_response(401) ==
               %{"error" => "Invalid API token"}
    end

    test "a missing Authorization header is a 401 with the missing-header body",
         %{task: task} do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/tasks/#{task.identifier}/comments")

      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end
  end

  describe "POST /api/tasks/:id/comments" do
    test "creates a comment authored by the token's user and returns 201",
         %{conn: conn, task: task, user: user} do
      body =
        conn
        |> post_comment(task.identifier, %{"content" => "From the API", "agent_name" => "Claude"})
        |> json_response(201)

      assert body["data"]["content"] == "From the API"
      assert body["data"]["task_id"] == task.id
      assert body["data"]["author_name"] == "Owner Person"
      assert body["data"]["author_agent_name"] == "Claude"

      assert [%{author_user_id: author_id, author_agent_name: "Claude"}] =
               Tasks.list_comments(task)

      assert author_id == user.id
    end

    test "ignores an author id in the body", %{conn: conn, task: task, user: user} do
      other = user_fixture()

      conn
      |> post_comment(task.identifier, %{"content" => "x", "author_user_id" => other.id})
      |> json_response(201)

      assert [%{author_user_id: author_id}] = Tasks.list_comments(task)
      assert author_id == user.id
    end

    test "the token's agent_model wins over agent_name", %{user: user, board: board, task: task} do
      body =
        user
        |> token_conn(board, %{"agent_model" => "claude-x"})
        |> post_comment(task.identifier, %{"content" => "x", "agent_name" => "Param"})
        |> json_response(201)

      assert body["data"]["author_agent_name"] == "ai_agent:claude-x"
    end

    test "falls back to the token's last agent name, then to none",
         %{conn: conn, token: token, task: task} do
      body = conn |> post_comment(task.identifier, %{"content" => "plain"}) |> json_response(201)
      assert body["data"]["author_agent_name"] == nil

      ApiTokens.stamp_last_agent_name(token, "Remembered")

      body =
        conn
        |> post_comment(task.identifier, %{"content" => "again", "agent_name" => "Unknown"})
        |> json_response(201)

      assert body["data"]["author_agent_name"] == "Remembered"
    end

    test "stamps the token's last agent name after the write",
         %{conn: conn, token: token, task: task} do
      conn
      |> post_comment(task.identifier, %{"content" => "x", "agent_name" => "Stamped"})
      |> json_response(201)

      assert ApiTokens.get_api_token!(token.id).last_agent_name == "Stamped"
    end

    test "blank, missing and oversized content are 422", %{conn: conn, task: task} do
      for body <- [%{"content" => ""}, %{}, %{"content" => String.duplicate("a", 10_001)}] do
        response = conn |> post_comment(task.identifier, body) |> json_response(422)
        assert Map.has_key?(response["errors"], "content")
      end

      assert Tasks.list_comments(task) == []
    end

    test "content with a NUL character, or only invisible characters, is 422",
         %{conn: conn, task: task} do
      response =
        conn |> post_comment(task.identifier, %{"content" => "a\u0000b"}) |> json_response(422)

      assert response["errors"]["content"] == ["is invalid"]

      response =
        conn
        |> post_comment(task.identifier, %{"content" => "\u200b\u200e"})
        |> json_response(422)

      assert response["errors"]["content"] == ["can't be blank"]

      assert Tasks.list_comments(task) == []
    end

    test "an invisible or NUL-bearing agent name is ignored and not stamped",
         %{conn: conn, token: token, task: task} do
      for name <- ["\u200b", "Bot\u0000"] do
        body =
          conn
          |> post_comment(task.identifier, %{"content" => "x", "agent_name" => name})
          |> json_response(201)

        assert body["data"]["author_agent_name"] == nil
      end

      assert ApiTokens.get_api_token!(token.id).last_agent_name == nil
    end

    test "an agent name over 255 characters is 422, not a server error",
         %{conn: conn, task: task} do
      response =
        conn
        |> post_comment(task.identifier, %{
          "content" => "x",
          "agent_name" => String.duplicate("a", 256)
        })
        |> json_response(422)

      assert Map.has_key?(response["errors"], "author_agent_name")
      assert Tasks.list_comments(task) == []
    end

    test "a task on another board is a 404 by identifier and by numeric id",
         %{conn: conn, task: task} do
      other = other_board_task(task)

      for id <- [other.identifier, Integer.to_string(other.id)] do
        assert conn |> post_comment(id, %{"content" => "x"}) |> json_response(404) ==
                 %{"error" => "Task not found"}
      end

      assert Tasks.list_comments(other) == []
    end

    test "a token whose user has lost board membership gets 403",
         %{user: owner, board: board, task: task} do
      member = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, member, :modify, owner)
      conn = token_conn(member, board)

      BoardUser
      |> where([bu], bu.board_id == ^board.id and bu.user_id == ^member.id)
      |> Repo.delete_all()

      body = conn |> post_comment(task.identifier, %{"content" => "x"}) |> json_response(403)
      assert body["error"] =~ "board membership required"
      assert Tasks.list_comments(task) == []
    end

    test "a read-only member may comment", %{user: owner, board: board, task: task} do
      reader = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      reader
      |> token_conn(board)
      |> post_comment(task.identifier, %{"content" => "observing"})
      |> json_response(201)
    end

    test "stores mentions of board members only", %{
      conn: conn,
      user: owner,
      board: board,
      task: task
    } do
      member = user_fixture(%{name: "Member"})
      {:ok, _} = Kanban.Boards.add_user_to_board(board, member, :modify, owner)
      outsider = user_fixture(%{name: "Outsider"})

      content = "@[Member](user:#{member.id}) and @[Outsider](user:#{outsider.id})"
      body = conn |> post_comment(task.identifier, %{"content" => content}) |> json_response(201)

      assert body["data"]["mentioned_user_ids"] == [member.id]
    end

    test "a mention notification names the posting agent as its actor", %{
      conn: conn,
      user: owner,
      board: board,
      task: task
    } do
      member = user_fixture(%{name: "Member"})
      {:ok, _} = Kanban.Boards.add_user_to_board(board, member, :modify, owner)

      body =
        conn
        |> post_comment(task.identifier, %{
          "content" => "@[Member](user:#{member.id}) please look",
          "agent_name" => "Claude"
        })
        |> json_response(201)

      notifications =
        Kanban.Notifications.Notification
        |> where(event_type: :mentioned)
        |> Repo.all()

      assert [
               %{
                 user_id: user_id,
                 actor_name: "Claude (Owner Person)",
                 task_id: task_id,
                 metadata: metadata
               }
             ] =
               notifications

      assert user_id == member.id
      assert task_id == task.id
      assert metadata == %{"comment_id" => body["data"]["id"]}
    end

    test "a posted comment is returned by GET", %{conn: conn, task: task} do
      created =
        conn
        |> post_comment(task.identifier, %{"content" => "round trip", "agent_name" => "Agent"})
        |> json_response(201)

      body = conn |> get(~p"/api/tasks/#{task.identifier}/comments") |> json_response(200)
      assert body["data"] == [created["data"]]
    end

    # W2215: the 401 bodies documented in docs/api/post_tasks_id_comments.md.
    test "a revoked token is a 401 with the invalid-token body and saves nothing",
         %{conn: conn, token: token, task: task} do
      {:ok, _} = ApiTokens.revoke_api_token(token)

      assert conn |> post_comment(task.identifier, %{"content" => "x"}) |> json_response(401) ==
               %{"error" => "Invalid API token"}

      assert Tasks.list_comments(task) == []
    end

    test "a missing Authorization header is a 401 with the missing-header body",
         %{task: task} do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post_comment(task.identifier, %{"content" => "x"})

      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
      assert Tasks.list_comments(task) == []
    end
  end

  describe "GET /api/tasks/:id comment_count" do
    test "the full view carries comment_count; slim and fields do not",
         %{conn: conn, task: task, user: user} do
      comment_at(task, user, "one", 10)
      comment_at(task, user, "two", 5)

      full = conn |> get(~p"/api/tasks/#{task.identifier}") |> json_response(200)
      assert full["comment_count"] == 2
      refute Map.has_key?(full["data"], "comment_count")

      slim =
        conn |> get(~p"/api/tasks/#{task.identifier}?response_view=slim") |> json_response(200)

      refute Map.has_key?(slim, "comment_count")

      projected =
        conn |> get(~p"/api/tasks/#{task.identifier}?fields=title") |> json_response(200)

      refute Map.has_key?(projected, "comment_count")
    end

    test "is zero for a task with no comments", %{conn: conn, task: task} do
      body = conn |> get(~p"/api/tasks/#{task.identifier}") |> json_response(200)
      assert body["comment_count"] == 0
    end
  end
end
