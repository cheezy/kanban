defmodule KanbanWeb.API.ApiDocsCoverageTest do
  @moduledoc """
  Keeps the endpoint table in `docs/api/README.md` complete (W2426).

  The router is the source of truth. Every method and path under `/api` in
  `KanbanWeb.Router` must have a row in the README's "Endpoint Summary" table,
  and every row there must name a route that exists. When this test fails after
  you added a route, add a row for it to that table, and give the route its own
  page under `docs/api/` if it needs one.

  The test reads router metadata and one markdown file. It makes no requests.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @readme "docs/api/README.md"
  @section "### Endpoint Summary"

  # Every route under /api as {"VERB", "/api/path"}, read from the router so a
  # new route is checked without anyone listing it here.
  defp api_routes do
    for %{path: "/api" <> _ = path, verb: verb} <- KanbanWeb.Router.__routes__(), uniq: true do
      {verb |> Atom.to_string() |> String.upcase(), path}
    end
  end

  defp readme, do: @root |> Path.join(@readme) |> File.read!()

  # The table lives between the section heading and the next heading. Rows in
  # any other table of the README do not count.
  defp summary_section(markdown) do
    case String.split(markdown, @section <> "\n", parts: 2) do
      [_before, rest] -> rest |> String.split(~r/^#/m, parts: 2) |> hd()
      [_no_section] -> flunk("#{@readme} has no \"#{@section}\" heading")
    end
  end

  # `| GET, DELETE | `/api/mcp` | ... |` gives [{"GET", "/api/mcp"}, {"DELETE", "/api/mcp"}].
  defp row_routes(line) do
    with ["", methods, path_cell | _] <- table_cells(line),
         [_, path] <- Regex.run(~r/^`(\/api[^`]*)`$/, path_cell) do
      for method <- String.split(methods, ","), do: {normalize_method(method), path}
    else
      _ -> []
    end
  end

  defp table_cells(line), do: line |> String.split("|") |> Enum.map(&String.trim/1)

  defp normalize_method(method), do: method |> String.trim() |> String.upcase()

  defp documented_routes(markdown) do
    markdown
    |> summary_section()
    |> String.split("\n")
    |> Enum.flat_map(&row_routes/1)
    |> MapSet.new()
  end

  defp format_routes(routes), do: Enum.map_join(routes, "\n", fn {m, p} -> "  #{m} #{p}" end)

  defp assert_documented(routes, markdown) do
    documented = documented_routes(markdown)
    missing = Enum.reject(routes, &MapSet.member?(documented, &1))

    assert missing == [], """
    #{@readme} "Endpoint Summary" table is missing these router routes:
    #{format_routes(missing)}

    Add a row for each, for example:
    | PATCH | `/api/tasks/:id/complete` | Complete a task | ... |
    """
  end

  defp assert_no_stale_rows(routes, markdown) do
    routed = MapSet.new(routes)
    stale = markdown |> documented_routes() |> Enum.reject(&MapSet.member?(routed, &1))

    assert stale == [], """
    #{@readme} "Endpoint Summary" table lists routes the router does not have:
    #{format_routes(Enum.sort(stale))}
    """
  end

  test "every /api route in the router appears in docs/api/README.md" do
    routes = api_routes()

    # Guards against passing on an empty or partial route list.
    assert length(routes) > 20
    # resources/4 expands :update into both PATCH and PUT.
    assert {"PATCH", "/api/tasks/:id"} in routes
    assert {"PUT", "/api/tasks/:id"} in routes
    # The 405-only routes are routes too.
    assert {"GET", "/api/mcp"} in routes
    assert {"DELETE", "/api/mcp"} in routes

    assert_documented(routes, readme())
  end

  test "every row in docs/api/README.md's endpoint table names a routed method and path" do
    assert_no_stale_rows(api_routes(), readme())
  end

  test "a route missing from the table fails with its method and path in the message" do
    markdown = """
    ### Endpoint Summary

    | Method | Endpoint | Purpose | Returns Hooks |
    |--------|----------|---------|---------------|
    | PATCH | `/api/tasks/:id` | Update task fields | No |
    | GET, DELETE | `/api/mcp` | Not supported, returns `405` | No |

    ## Errors

    | Method | Endpoint |
    |--------|----------|
    | PUT | `/api/tasks/:id` |
    """

    routes = [
      {"PATCH", "/api/tasks/:id"},
      {"PUT", "/api/tasks/:id"},
      {"GET", "/api/mcp"},
      {"DELETE", "/api/mcp"}
    ]

    error = assert_raise ExUnit.AssertionError, fn -> assert_documented(routes, markdown) end

    assert error.message =~ "PUT /api/tasks/:id"
    refute error.message =~ "PATCH /api/tasks/:id"
    refute error.message =~ "GET /api/mcp"
    refute error.message =~ "DELETE /api/mcp"
  end

  test "a row naming a route the router does not have fails with its method and path" do
    markdown = """
    ### Endpoint Summary

    | Method | Endpoint | Purpose | Returns Hooks |
    |--------|----------|---------|---------------|
    | PATCH | `/api/tasks/:id` | Update task fields | No |
    | DELETE | `/api/tasks/:id` | Not a route | No |
    """

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_no_stale_rows([{"PATCH", "/api/tasks/:id"}], markdown)
      end

    assert error.message =~ "DELETE /api/tasks/:id"
    refute error.message =~ "PATCH /api/tasks/:id"
  end
end
