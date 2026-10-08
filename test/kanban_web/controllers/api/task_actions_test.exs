defmodule KanbanWeb.API.TaskActionsTest do
  use Kanban.DataCase, async: true

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.API.TaskActions

  setup do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)

    {:ok, {api_token, _plain}} =
      ApiTokens.create_api_token(user, board, %{"name" => "Actions", "agent_capabilities" => []})

    conn =
      :post
      |> Phoenix.ConnTest.build_conn("/api/mcp")
      |> Plug.Conn.assign(:current_user, user)
      |> Plug.Conn.assign(:current_board, board)
      |> Plug.Conn.assign(:api_token, api_token)

    columns = Columns.list_columns(board)

    %{
      conn: conn,
      user: user,
      board: board,
      ready: Enum.find(columns, &(&1.name == "Ready")),
      doing: Enum.find(columns, &(&1.name == "Doing"))
    }
  end

  defp hook, do: %{"exit_code" => 0, "output" => "ok", "duration_ms" => 1}

  describe "fetch_task/2" do
    test "finds a task by identifier and by numeric id on the board", %{
      board: board,
      user: user,
      ready: ready
    } do
      {:ok, task} = Tasks.create_task(ready, %{"title" => "T", "created_by_id" => user.id})

      assert {:ok, %{id: id}} = TaskActions.fetch_task(task.identifier, board)
      assert id == task.id
      assert {:ok, %{id: ^id}} = task.id |> Integer.to_string() |> TaskActions.fetch_task(board)
    end

    test "a cross-board, missing or out-of-range id is not_found", %{board: board} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_ready = other_board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))

      {:ok, other} =
        Tasks.create_task(other_ready, %{"title" => "O", "created_by_id" => other_user.id})

      assert other.id |> Integer.to_string() |> TaskActions.fetch_task(board) ==
               {:error, :not_found}

      assert TaskActions.fetch_task("W99999999", board) == {:error, :not_found}
      assert TaskActions.fetch_task("99999999999999999999999", board) == {:error, :not_found}
    end
  end

  describe "claim/2" do
    test "returns the show template with the claimed task and hook", %{
      conn: conn,
      user: user,
      ready: ready
    } do
      {:ok, task} = Tasks.create_task(ready, %{"title" => "T", "created_by_id" => user.id})

      assert {:ok, :show, assigns} =
               TaskActions.claim(conn, %{
                 "identifier" => task.identifier,
                 "before_doing_result" => hook()
               })

      assert assigns[:task].id == task.id
      assert assigns[:hook].name == "before_doing"
    end

    test "a failed before_doing result stops before claiming", %{
      conn: conn,
      user: user,
      ready: ready
    } do
      {:ok, task} = Tasks.create_task(ready, %{"title" => "T", "created_by_id" => user.id})

      assert {:error, {:hook_failed, "before_doing", _}} =
               TaskActions.claim(conn, %{"identifier" => task.identifier})

      assert Tasks.get_task!(task.id).status == :open
    end

    test "maps no task to {:no_tasks_available, identifier}", %{conn: conn} do
      assert TaskActions.claim(conn, %{"before_doing_result" => hook()}) ==
               {:error, {:no_tasks_available, nil}}

      assert TaskActions.claim(conn, %{"identifier" => "W1", "before_doing_result" => hook()}) ==
               {:error, {:no_tasks_available, "W1"}}
    end
  end

  describe "complete/3" do
    test "a task on another board is not found", %{conn: conn} do
      assert TaskActions.complete(conn, "W99999999", %{}) == {:error, :not_found}
    end

    test "missing hook results are rejected before the gate", %{
      conn: conn,
      user: user,
      doing: doing
    } do
      {:ok, task} =
        Tasks.create_task(doing, %{
          "title" => "T",
          "status" => "in_progress",
          "assigned_to_id" => user.id,
          "created_by_id" => user.id
        })

      assert {:error, {:hook_failed, "after_doing", _}} =
               TaskActions.complete(conn, task.identifier, %{})
    end
  end

  describe "add_comment/3" do
    test "adds a comment for a writer", %{conn: conn, user: user, ready: ready} do
      {:ok, task} = Tasks.create_task(ready, %{"title" => "T", "created_by_id" => user.id})

      assert {:ok, comment} = TaskActions.add_comment(conn, task.identifier, "hello")
      assert comment.task_id == task.id
      assert comment.content == "hello"
      assert comment.author_user_id == user.id
    end

    test "a read-only member can comment, authored by the token's user",
         %{conn: conn, board: board, user: owner, ready: ready} do
      {:ok, task} = Tasks.create_task(ready, %{"title" => "T", "created_by_id" => owner.id})
      reader = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      conn = Plug.Conn.assign(conn, :current_user, reader)

      assert {:ok, comment} = TaskActions.add_comment(conn, task.identifier, "observing")
      assert comment.author_user_id == reader.id
    end

    test "a user with no board membership is :not_authorized and nothing is stored",
         %{conn: conn, user: owner, ready: ready} do
      {:ok, task} = Tasks.create_task(ready, %{"title" => "T", "created_by_id" => owner.id})
      conn = Plug.Conn.assign(conn, :current_user, user_fixture())

      assert {:error, :not_authorized} = TaskActions.add_comment(conn, task.identifier, "nope")
      assert Kanban.Repo.aggregate(Kanban.Tasks.TaskComment, :count) == 0
    end

    test "a cross-board task is not_found", %{conn: conn} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_ready = other_board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))

      {:ok, other} =
        Tasks.create_task(other_ready, %{"title" => "O", "created_by_id" => other_user.id})

      assert {:error, :not_found} = TaskActions.add_comment(conn, other.identifier, "x")
    end

    test "a blank comment is a changeset error", %{conn: conn, user: user, ready: ready} do
      {:ok, task} = Tasks.create_task(ready, %{"title" => "T", "created_by_id" => user.id})
      assert {:error, %Ecto.Changeset{}} = TaskActions.add_comment(conn, task.identifier, "")
    end
  end

  describe "add_comment/4 attribution" do
    setup %{user: user, ready: ready} do
      {:ok, task} = Tasks.create_task(ready, %{"title" => "T", "created_by_id" => user.id})
      %{task: task}
    end

    test "attributes the comment to agent_name and stamps the token",
         %{conn: conn, task: task} do
      assert {:ok, comment} = TaskActions.add_comment(conn, task.identifier, "hi", "Claude")
      assert comment.author_agent_name == "Claude"
      assert comment.author.id == conn.assigns.current_user.id
      assert ApiTokens.get_api_token!(conn.assigns.api_token.id).last_agent_name == "Claude"
    end

    test "the token's agent_model wins", %{conn: conn, task: task} do
      api_token = %{conn.assigns.api_token | agent_model: "claude-x"}
      conn = Plug.Conn.assign(conn, :api_token, api_token)

      assert {:ok, comment} = TaskActions.add_comment(conn, task.identifier, "hi", "Param")
      assert comment.author_agent_name == "ai_agent:claude-x"
    end

    test "falls back to the token's last agent name", %{conn: conn, task: task} do
      api_token = %{conn.assigns.api_token | last_agent_name: "Remembered"}
      conn = Plug.Conn.assign(conn, :api_token, api_token)

      assert {:ok, comment} = TaskActions.add_comment(conn, task.identifier, "hi")
      assert comment.author_agent_name == "Remembered"
    end

    test "a refused write does not stamp the token", %{conn: conn, task: task} do
      conn = Plug.Conn.assign(conn, :current_user, user_fixture())

      assert {:error, :not_authorized} =
               TaskActions.add_comment(conn, task.identifier, "nope", "Stranger")

      assert ApiTokens.get_api_token!(conn.assigns.api_token.id).last_agent_name == nil
    end
  end

  describe "list_comments/3" do
    setup %{conn: conn, user: user, ready: ready} do
      {:ok, task} = Tasks.create_task(ready, %{"title" => "T", "created_by_id" => user.id})
      for n <- 1..3, do: {:ok, _} = TaskActions.add_comment(conn, task.identifier, "c#{n}")
      %{task: task}
    end

    test "returns the index template with comments and meta", %{conn: conn, task: task} do
      assert {:ok, :index, assigns} = TaskActions.list_comments(conn, task.identifier, %{})
      assert length(assigns[:comments]) == 3
      assert assigns[:meta] == %{limit: 50, has_more: false}
    end

    test "honours limit", %{conn: conn, task: task} do
      assert {:ok, :index, assigns} =
               TaskActions.list_comments(conn, task.identifier, %{"limit" => "2"})

      assert length(assigns[:comments]) == 2
      assert assigns[:meta] == %{limit: 2, has_more: true}
    end

    test "an invalid limit is an invalid_param error", %{conn: conn, task: task} do
      assert {:error, {:invalid_param, "Invalid limit" <> _}} =
               TaskActions.list_comments(conn, task.identifier, %{"limit" => "0"})
    end

    test "an unknown task is not_found", %{conn: conn} do
      assert {:error, :not_found} = TaskActions.list_comments(conn, "W999999", %{})
    end
  end

  describe "authorize_board_write/2" do
    test "allows owner and modify, refuses read_only", %{board: board, user: owner} do
      assert TaskActions.authorize_board_write(board, owner) == :ok

      writer = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, writer, :modify, owner)
      assert TaskActions.authorize_board_write(board, writer) == :ok

      reader = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)
      assert TaskActions.authorize_board_write(board, reader) == {:error, :not_authorized_write}
    end
  end

  describe "list_page/2" do
    test "an invalid param is {:invalid_param, message}", %{conn: conn} do
      assert {:error, {:invalid_param, message}} = TaskActions.list_page(conn, %{"limit" => "0"})
      assert is_binary(message)
    end

    test "an unknown column is not_found", %{conn: conn} do
      assert TaskActions.list_page(conn, %{"limit" => "5", "column_id" => "999999999"}) ==
               {:error, :not_found}
    end
  end

  describe "helpers" do
    test "parse_id/1" do
      assert TaskActions.parse_id(5) == {:ok, 5}
      assert TaskActions.parse_id("5") == {:ok, 5}
      assert TaskActions.parse_id("5x") == :error
      assert TaskActions.parse_id(nil) == :error
    end

    test "view_for/1 only opts in on the literal slim" do
      assert TaskActions.view_for(%{"response_view" => "slim"}) == :slim
      assert TaskActions.view_for(%{"response_view" => "full"}) == :full
      assert TaskActions.view_for(%{}) == :full
    end

    test "log_unexpected_claim_error/2 logs the raw reason" do
      log =
        capture_log(fn ->
          TaskActions.log_unexpected_claim_error({:weird, :reason}, task_identifier: "W1")
        end)

      assert log =~ ":weird"
    end
  end
end
