defmodule KanbanWeb.API.Agent.EndpointDocsTest do
  @moduledoc """
  Unit tests for the onboarding endpoint catalogue extracted from
  `KanbanWeb.API.AgentJSON` (W2215).
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.API.Agent.EndpointDocs
  alias KanbanWeb.API.AgentJSON

  @repo_prefix "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/"
  @docs_prefix @repo_prefix <> "docs/api/"

  # The two routes the router serves through its public pipeline, with no token.
  @public_routes [{"GET", "/api/agent/onboarding"}, {"GET", "/api/openapi.json"}]

  # Every route under /api as {"VERB", "/api/path"}, read from the router so a
  # new route is checked without anyone listing it here (the same reading as
  # api_docs_coverage_test.exs).
  defp api_routes do
    for %{path: "/api" <> _ = path, verb: verb} <- KanbanWeb.Router.__routes__(), uniq: true do
      {verb |> Atom.to_string() |> String.upcase(), path}
    end
  end

  defp documented_routes do
    for {_group, entries} <- EndpointDocs.endpoints(), entry <- entries do
      {entry.method, entry.path}
    end
  end

  defp entry(method, path) do
    EndpointDocs.endpoints()
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1.method == method and &1.path == path))
  end

  describe "endpoints/0" do
    test "has exactly the discovery, management and creation groups" do
      assert EndpointDocs.endpoints() |> Map.keys() |> Enum.sort() ==
               [:creation, :discovery, :management]
    end

    test "every entry has a method, an /api path, auth and a docs page that exists" do
      for {_group, entries} <- EndpointDocs.endpoints(), entry <- entries do
        assert entry.method in ~w(GET POST PATCH PUT DELETE)
        assert String.starts_with?(entry.path, "/api/")
        assert entry.auth_required == {entry.method, entry.path} not in @public_routes
        assert String.starts_with?(entry.documentation_url, @repo_prefix <> "docs/")

        page = String.replace_prefix(entry.documentation_url, @repo_prefix, "")
        assert File.exists?(page), "#{entry.method} #{entry.path} links a missing page: #{page}"
      end
    end

    test "every api route is documented" do
      routes = api_routes()
      documented = documented_routes()

      # Guards against passing on an empty or partial route list.
      assert length(routes) > 20
      assert {"PATCH", "/api/tasks/:id"} in routes
      assert {"PUT", "/api/tasks/:id"} in routes

      missing = Enum.reject(routes, &(&1 in documented))
      assert missing == [], "EndpointDocs omits these router routes: #{inspect(missing)}"

      stale = Enum.reject(documented, &(&1 in routes))
      assert stale == [], "EndpointDocs lists routes the router does not have: #{inspect(stale)}"

      assert documented == Enum.uniq(documented), "EndpointDocs lists a route twice"
    end

    test "complete and mark_reviewed list their real required parameters" do
      complete = entry("PATCH", "/api/tasks/:id/complete")

      assert complete.required_parameters == EndpointDocs.complete_required_parameters()

      for param <- ~w(after_doing_result before_review_result completion_summary
                      actual_complexity actual_files_changed time_spent_minutes
                      explorer_result reviewer_result) do
        assert param in complete.required_parameters, "complete omits #{param}"
        assert complete.description =~ param, "complete's description omits #{param}"
      end

      mark_reviewed = entry("PATCH", "/api/tasks/:id/mark_reviewed")

      assert mark_reviewed.required_parameters == ["after_review_result"]
      assert mark_reviewed.required_parameters == EndpointDocs.mark_reviewed_required_parameters()
      assert mark_reviewed.description =~ "after_review_result"
    end

    test "lists GET /api/boards under discovery (W2220)" do
      boards = Enum.filter(EndpointDocs.endpoints().discovery, &(&1.path == "/api/boards"))

      assert [%{method: "GET", documentation_url: url, description: description}] = boards
      assert url == @docs_prefix <> "get_boards.md"
      assert description =~ "workspace token"
    end

    test "lists the comment endpoints, each once" do
      paths =
        for {_group, entries} <- EndpointDocs.endpoints(),
            entry <- entries,
            entry.path == "/api/tasks/:id/comments",
            do: entry.method

      assert Enum.sort(paths) == ["GET", "POST"]
    end

    test "is what the onboarding payload publishes as api_reference.endpoints" do
      payload = AgentJSON.onboarding(%{base_url: "http://example.test"})

      assert payload.api_reference.endpoints == EndpointDocs.endpoints()
    end
  end
end
