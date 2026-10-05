# D360: a numeric task id or column_id outside the signed 64-bit range used to
# reach Postgrex, which raised DBConnection.EncodeError (a 500). Promoted from
# the D351 exploratory draft and extended to every :id route and the column_id
# routes. Under Phoenix.ConnTest the encode error surfaces as a raised exception,
# so a regression here fails the test by raising rather than by a 500.
defmodule KanbanWeb.API.TaskIdOutOfBigintRangeTest do
  use KanbanWeb.ConnCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @moduletag capture_log: true

  @bigint_max "9223372036854775807"
  @bigint_min "-9223372036854775808"
  @above_bigint_max "9223372036854775808"
  @below_bigint_min "-9223372036854775809"
  @reported_id "99999999999999999999"
  @not_found %{"error" => "Task not found"}

  # Every route that resolves :id through the shared task lookup, with a body
  # that lets the request reach the lookup (update needs a "task" key first).
  @id_routes [
    {:get, "", nil},
    {:patch, "", %{"task" => %{"title" => "x"}}},
    {:put, "", %{"task" => %{"title" => "x"}}},
    {:patch, "/complete", %{}},
    {:put, "/changed_files", %{}},
    {:post, "/unclaim", %{}},
    {:patch, "/mark_reviewed", %{}},
    {:patch, "/mark_done", %{}},
    {:patch, "/after_goal", %{"exit_code" => 0, "output" => "", "duration_ms" => 0}},
    {:get, "/dependencies", nil},
    {:get, "/dependents", nil},
    {:get, "/tree", nil},
    {:get, "/after_goal_status", nil}
  ]

  setup %{conn: conn} do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)

    {:ok, {_token_struct, plain_token}} =
      ApiTokens.create_api_token(user, board, %{
        "name" => "Test Token",
        "agent_capabilities" => ["code_generation", "testing"]
      })

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{plain_token}")

    %{conn: conn, user: user, board: board}
  end

  defp call(conn, :get, path, _body), do: get(conn, path)
  defp call(conn, :patch, path, body), do: patch(conn, path, body)
  defp call(conn, :put, path, body), do: put(conn, path, body)
  defp call(conn, :post, path, body), do: post(conn, path, body)

  describe "GET /api/tasks/:id with a numeric id outside the bigint range" do
    test "bigint max + 1 returns 404 instead of crashing", %{conn: conn} do
      conn = get(conn, "/api/tasks/#{@above_bigint_max}")
      assert json_response(conn, 404) == @not_found
    end

    test "bigint min - 1 returns 404 instead of crashing", %{conn: conn} do
      conn = get(conn, "/api/tasks/#{@below_bigint_min}")
      assert json_response(conn, 404) == @not_found
    end

    test "the id from the original report returns 404", %{conn: conn} do
      conn = get(conn, "/api/tasks/#{@reported_id}")
      assert json_response(conn, 404) == @not_found
    end

    test "a several-hundred-digit id returns 404", %{conn: conn} do
      conn = get(conn, "/api/tasks/#{String.duplicate("9", 400)}")
      assert json_response(conn, 404) == @not_found
    end

    test "an out-of-range id with response_view or fields still returns 404", %{conn: conn} do
      slim = get(conn, "/api/tasks/#{@above_bigint_max}?response_view=slim")
      fields = get(conn, "/api/tasks/#{@above_bigint_max}?fields=title")

      assert json_response(slim, 404) == @not_found
      assert json_response(fields, 404) == @not_found
    end

    test "an out-of-range number with trailing text returns 404 without a database error",
         %{conn: conn} do
      conn = get(conn, "/api/tasks/#{@above_bigint_max}abc")
      assert json_response(conn, 404) == @not_found
    end
  end

  describe "bigint boundary and in-range ids keep the normal lookup" do
    test "bigint max and bigint min themselves return 404 through the lookup", %{conn: conn} do
      assert json_response(get(conn, "/api/tasks/#{@bigint_max}"), 404) == @not_found
      assert json_response(get(conn, "/api/tasks/#{@bigint_min}"), 404) == @not_found
    end

    # A 404 alone cannot tell the database lookup from the out-of-range short
    # circuit, so these put real tasks at the edge ids. Narrowing the guard at
    # either end, or to positive ids only, turns the 200 into a 404.
    test "tasks stored at the bigint bounds, at zero and at a negative id are found by id",
         %{conn: conn, user: user, board: board} do
      column = board |> Columns.list_columns() |> hd()

      for {id, n} <- Enum.with_index([@bigint_max, @bigint_min, "0", "-1"], 1) do
        id = String.to_integer(id)

        Repo.insert!(%Task{
          id: id,
          title: "D360 edge id #{n}",
          identifier: "W#{900_000_000 + n}",
          column_id: column.id,
          position: 1_000 + n,
          created_by_id: user.id
        })

        assert json_response(get(conn, "/api/tasks/#{id}"), 200)["data"]["id"] == id
      end
    end

    test "in-range nonexistent, zero and negative ids still return 404",
         %{conn: conn} do
      for id <- ["999999999", "0", "-1", "W999999999"] do
        assert json_response(get(conn, "/api/tasks/#{id}"), 404) == @not_found
      end
    end

    test "an out-of-range id is indistinguishable from a cross-board id", %{conn: conn} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)
      other_column = other_board |> Columns.list_columns() |> hd()

      {:ok, other_task} =
        Tasks.create_task(other_column, %{
          "title" => "Other Board Task",
          "created_by_id" => other_user.id
        })

      cross_board = get(conn, "/api/tasks/#{other_task.id}")
      out_of_range = get(conn, "/api/tasks/#{@above_bigint_max}")

      assert json_response(cross_board, 404) == json_response(out_of_range, 404)
    end

    test "an in-range numeric id, a padded id and an identifier still resolve the task",
         %{conn: conn, user: user, board: board} do
      column = board |> Columns.list_columns() |> hd()

      {:ok, task} =
        Tasks.create_task(column, %{"title" => "Mine", "created_by_id" => user.id})

      for id <- ["#{task.id}", "+#{task.id}", "00#{task.id}", task.identifier] do
        assert json_response(get(conn, "/api/tasks/#{id}"), 200)["data"]["id"] == task.id
      end
    end
  end

  describe "every :id route returns 404 for an out-of-range numeric id" do
    for {verb, suffix, body} <- @id_routes, id <- [@above_bigint_max, @below_bigint_min] do
      @verb verb
      @suffix suffix
      @body body
      @id id

      test "#{verb |> Atom.to_string() |> String.upcase()} /api/tasks/#{id}#{suffix}",
           %{conn: conn} do
        conn = call(conn, @verb, "/api/tasks/#{@id}#{@suffix}", @body)
        assert json_response(conn, 404) == @not_found
      end
    end
  end

  describe "column_id out of range returns 404 on list, paginated list and create" do
    test "GET /api/tasks legacy mode", %{conn: conn} do
      conn = get(conn, "/api/tasks?column_id=#{@above_bigint_max}")
      assert json_response(conn, 404) == @not_found
    end

    test "GET /api/tasks paginated mode", %{conn: conn} do
      conn = get(conn, "/api/tasks?column_id=#{@above_bigint_max}&limit=2")
      assert json_response(conn, 404) == @not_found
    end

    test "GET /api/tasks with bigint min - 1 in both modes", %{conn: conn} do
      legacy = get(conn, "/api/tasks?column_id=#{@below_bigint_min}")
      paged = get(conn, "/api/tasks?column_id=#{@below_bigint_min}&limit=2")

      assert json_response(legacy, 404) == @not_found
      assert json_response(paged, 404) == @not_found
    end

    test "out-of-range column_id is the same 404 as a nonexistent column", %{conn: conn} do
      out_of_range = get(conn, "/api/tasks?column_id=#{@above_bigint_max}")
      nonexistent = get(conn, "/api/tasks?column_id=999999999")

      assert json_response(out_of_range, 404) == json_response(nonexistent, 404)
    end

    test "POST /api/tasks with an out-of-range column_id string", %{conn: conn} do
      conn =
        post(conn, "/api/tasks", %{
          "task" => %{"title" => "D360", "column_id" => @above_bigint_max}
        })

      assert json_response(conn, 404) == @not_found
    end

    test "POST /api/tasks with an out-of-range column_id JSON number", %{conn: conn} do
      body = ~s({"task": {"title": "D360", "column_id": #{@above_bigint_max}}})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/tasks", body)

      assert json_response(conn, 404) == @not_found
    end

    test "non-numeric column_id still returns 400 in every mode", %{conn: conn} do
      message = "Invalid column_id: must be an integer"

      legacy = get(conn, "/api/tasks?column_id=abc")
      paged = get(conn, "/api/tasks?column_id=abc&limit=2")

      created =
        post(conn, "/api/tasks", %{"task" => %{"title" => "D360", "column_id" => "abc"}})

      assert json_response(legacy, 400)["error"] == message
      assert json_response(paged, 400)["error"] == message
      assert json_response(created, 400)["error"] == message
    end
  end
end
