defmodule KanbanWeb.API.Agent.EndpointDocsTest do
  @moduledoc """
  Unit tests for the onboarding endpoint catalogue extracted from
  `KanbanWeb.API.AgentJSON` (W2215).
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.API.Agent.EndpointDocs
  alias KanbanWeb.API.AgentJSON

  @docs_prefix "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/"

  describe "endpoints/0" do
    test "has exactly the discovery, management and creation groups" do
      assert EndpointDocs.endpoints() |> Map.keys() |> Enum.sort() ==
               [:creation, :discovery, :management]
    end

    test "every entry has a method, an /api path, auth and a docs/api page that exists" do
      for {_group, entries} <- EndpointDocs.endpoints(), entry <- entries do
        assert entry.method in ~w(GET POST PATCH PUT DELETE)
        assert String.starts_with?(entry.path, "/api/")
        assert entry.auth_required == true
        assert String.starts_with?(entry.documentation_url, @docs_prefix)

        page = String.replace_prefix(entry.documentation_url, @docs_prefix, "docs/api/")
        assert File.exists?(page), "#{entry.method} #{entry.path} links a missing page: #{page}"
      end
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
