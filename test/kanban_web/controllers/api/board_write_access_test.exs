defmodule KanbanWeb.API.BoardWriteAccessTest do
  @moduledoc """
  Every API task write checks the token user's live board access before it
  looks at the task, so a refused caller gets one fixed 403 whatever the task's
  state, and whether it exists (G442 exploratory findings 1, 3 and 4).
  """
  use KanbanWeb.ConnCase

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks
  alias KanbanWeb.API.BoardWriteAccess
  alias KanbanWeb.API.TaskErrors
  alias KanbanWeb.API.TaskTransitions

  @moduletag capture_log: true

  @hook %{"exit_code" => 0, "output" => "ok", "duration_ms" => 1}

  setup do
    owner = user_fixture()
    member = user_fixture()
    board = ai_optimized_board_fixture(owner)
    Repo.insert!(%BoardUser{board_id: board.id, user_id: member.id, access: :modify})
    columns = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

    tasks = %{
      ready: task_in(columns["Ready"], owner, %{"status" => "open"}),
      claimed: task_in(columns["Doing"], owner, claimed_by(member)),
      claimed_by_other: task_in(columns["Doing"], owner, claimed_by(owner)),
      review: task_in(columns["Review"], owner, claimed_by(member)),
      goal: task_in(columns["Doing"], owner, %{"type" => "goal", "status" => "in_progress"})
    }

    %{owner: owner, member: member, board: board, tasks: tasks}
  end

  describe "a board token whose user was removed from the board" do
    setup %{conn: conn, board: board, member: member} do
      conn = authed(conn, board_token(member, board))
      set_access(board, member, nil)
      %{conn: conn}
    end

    test "gets one 403 from every write, whatever the task's state", %{conn: conn, tasks: tasks} do
      for id <- task_ids(tasks), request <- write_requests() do
        assert_refused(write(conn, request, id), request, id)
      end
    end

    test "gets the after_goal 403 for an existing goal and a missing id", %{
      conn: conn,
      tasks: tasks
    } do
      for id <- [tasks.goal.id, tasks.ready.id, "999999999", "W999999"] do
        assert conn
               |> patch(~p"/api/tasks/#{id}/after_goal", @hook)
               |> json_response(403) == body(:not_authorized_after_goal),
               "#{id}"
      end
    end

    test "gets the membership 403 when commenting, for any task id", %{conn: conn, tasks: tasks} do
      for id <- task_ids(tasks) do
        assert conn
               |> post(~p"/api/tasks/#{id}/comments", %{"content" => "hi"})
               |> json_response(403) == body(:not_authorized),
               "#{id}"
      end
    end

    test "changes no task", %{conn: conn, tasks: tasks} do
      for id <- task_ids(tasks), request <- write_requests(), do: write(conn, request, id)

      for {_name, task} <- tasks do
        reloaded = Tasks.get_task!(task.id)
        assert {reloaded.status, reloaded.column_id} == {task.status, task.column_id}
      end
    end
  end

  describe "a board token whose user was made read-only" do
    setup %{conn: conn, board: board, member: member} do
      conn = authed(conn, board_token(member, board))
      set_access(board, member, :read_only)
      %{conn: conn}
    end

    test "mark_done answers 403, never 500 (finding 1)", %{conn: conn, tasks: tasks} do
      assert conn |> patch(~p"/api/tasks/#{tasks.review.id}/mark_done") |> json_response(403) ==
               body(:not_authorized_write)

      assert Tasks.get_task!(tasks.review.id).status == :in_progress
    end

    test "mark_reviewed answers 403, never 422 (finding 3)", %{conn: conn, tasks: tasks} do
      assert conn
             |> patch(~p"/api/tasks/#{tasks.review.id}/mark_reviewed", %{
               "after_review_result" => @hook
             })
             |> json_response(403) == body(:not_authorized_write)
    end

    test "gets one 403 from every write, whatever the task's state", %{conn: conn, tasks: tasks} do
      for id <- task_ids(tasks), request <- write_requests() do
        assert_refused(write(conn, request, id), request, id)
      end
    end

    test "may still comment", %{conn: conn, tasks: tasks} do
      assert conn
             |> post(~p"/api/tasks/#{tasks.ready.id}/comments", %{"content" => "hi"})
             |> json_response(201)
    end
  end

  describe "a board token whose user keeps write access" do
    setup %{conn: conn, board: board, member: member} do
      %{conn: authed(conn, board_token(member, board))}
    end

    test "still gets the task-specific answers", %{conn: conn, tasks: tasks} do
      assert conn
             |> post(~p"/api/tasks/#{tasks.ready.id}/unclaim")
             |> json_response(422)
             |> Map.fetch!("error") == "Task is not currently claimed"

      assert conn
             |> post(~p"/api/tasks/#{tasks.claimed_by_other.id}/unclaim")
             |> json_response(403)
             |> Map.fetch!("error") == "You can only unclaim tasks that you claimed"

      assert conn |> post(~p"/api/tasks/999999999/unclaim") |> json_response(404)
      assert conn |> patch(~p"/api/tasks/#{tasks.review.id}/mark_done") |> json_response(200)
    end
  end

  describe "TaskTransitions when the context refuses" do
    # The plug runs first, so these clauses only answer a request whose access
    # was lost between the plug and the context call. Called directly here.
    setup %{board: board, member: member} do
      set_access(board, member, :read_only)
      :ok
    end

    test "proceed_with_mark_done answers 403", %{conn: conn, member: member, tasks: tasks} do
      conn = conn |> json_conn() |> TaskTransitions.proceed_with_mark_done(tasks.review, member)
      assert json_response(conn, 403) == body(:not_authorized_write)
    end

    test "proceed_with_mark_reviewed answers 403", %{conn: conn, member: member, tasks: tasks} do
      conn =
        conn |> json_conn() |> TaskTransitions.proceed_with_mark_reviewed(tasks.review, member)

      assert json_response(conn, 403) == body(:not_authorized_write)
    end
  end

  describe "authorize/2" do
    test "passes owner and modify, refuses read-only and non-members", %{
      board: board,
      owner: owner,
      member: member
    } do
      assert BoardWriteAccess.authorize(board, owner) == :ok
      assert BoardWriteAccess.authorize(board, member) == :ok

      set_access(board, member, :read_only)
      assert BoardWriteAccess.authorize(board, member) == {:error, :not_authorized_write}
      assert BoardWriteAccess.authorize(board, user_fixture()) == {:error, :not_authorized_write}
    end

    test "refuses a missing board or user", %{board: board, owner: owner} do
      assert BoardWriteAccess.authorize(nil, owner) == {:error, :not_authorized_write}
      assert BoardWriteAccess.authorize(board, nil) == {:error, :not_authorized_write}
    end
  end

  describe "authorize_member/2" do
    test "passes any access, read-only included", %{board: board, member: member} do
      assert BoardWriteAccess.authorize_member(board, member) == :ok
      set_access(board, member, :read_only)
      assert BoardWriteAccess.authorize_member(board, member) == :ok
    end

    test "refuses a non-member or a missing board or user", %{board: board, owner: owner} do
      assert BoardWriteAccess.authorize_member(board, user_fixture()) ==
               {:error, :not_authorized}

      assert BoardWriteAccess.authorize_member(nil, owner) == {:error, :not_authorized}
      assert BoardWriteAccess.authorize_member(board, nil) == {:error, :not_authorized}
    end
  end

  describe "the plug" do
    test "init/1 defaults the refusal to :not_authorized_write" do
      assert BoardWriteAccess.init([]) == :not_authorized_write

      assert BoardWriteAccess.init(reason: :not_authorized_after_goal) ==
               :not_authorized_after_goal
    end

    test "halts with the configured body when refused", %{board: board} do
      conn =
        board
        |> assigned_conn(user_fixture())
        |> BoardWriteAccess.call(BoardWriteAccess.init(reason: :not_authorized_after_goal))

      assert conn.halted
      assert json_response(conn, 403) == body(:not_authorized_after_goal)
    end

    test "lets a writer through untouched", %{board: board, member: member} do
      conn = board |> assigned_conn(member) |> BoardWriteAccess.call(:not_authorized_write)

      refute conn.halted
      refute conn.state == :sent
    end
  end

  # {method, action, params} for every task write the BoardWriteAccess plug or
  # TaskActions.complete/3 guards.
  defp write_requests do
    [
      {:post, "unclaim", %{}},
      {:patch, "complete", completion_params()},
      {:put, "changed_files", %{"changed_files" => [%{"path" => "a"}]}},
      {:patch, "mark_reviewed", %{"after_review_result" => @hook}},
      {:patch, "mark_done", %{}}
    ]
  end

  defp write(conn, {method, action, params}, id),
    do: dispatch(conn, @endpoint, method, "/api/tasks/#{id}/#{action}", params)

  defp assert_refused(conn, {_method, action, _params}, id) do
    assert json_response(conn, 403) == body(:not_authorized_write), "#{action} #{id}"
  end

  defp task_ids(tasks) do
    numeric = tasks |> Map.values() |> Enum.map(&Integer.to_string(&1.id))
    numeric ++ [tasks.ready.identifier, "999999999", "W999999"]
  end

  defp completion_params do
    %{
      "completion_summary" => "Done",
      "actual_complexity" => "small",
      "actual_files_changed" => "1",
      "time_spent_minutes" => 1,
      "after_doing_result" => @hook,
      "before_review_result" => @hook
    }
  end

  defp body(reason) do
    {:forbidden, _code, body} = TaskErrors.error_body(reason)
    body |> Jason.encode!() |> Jason.decode!()
  end

  defp claimed_by(user),
    do: %{
      "status" => "in_progress",
      "assigned_to_id" => user.id,
      "claimed_at" => DateTime.utc_now()
    }

  defp task_in(column, creator, attrs) do
    {:ok, task} =
      Tasks.create_task(
        column,
        Map.merge(
          %{"title" => "A task", "created_by_id" => creator.id, "needs_review" => false},
          attrs
        )
      )

    task
  end

  defp set_access(board, user, nil) do
    {1, _} = BoardUser |> where(board_id: ^board.id, user_id: ^user.id) |> Repo.delete_all()
  end

  defp set_access(board, user, access) do
    {1, _} =
      BoardUser
      |> where(board_id: ^board.id, user_id: ^user.id)
      |> Repo.update_all(set: [access: access])
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

  defp json_conn(conn) do
    conn
    |> Phoenix.Controller.put_format("json")
    |> Phoenix.Controller.put_view(json: KanbanWeb.API.TaskJSON)
  end

  defp assigned_conn(board, user) do
    Plug.Test.conn(:patch, "/")
    |> Plug.Conn.assign(:current_board, board)
    |> Plug.Conn.assign(:current_user, user)
    |> Phoenix.Controller.put_format("json")
  end
end
