defmodule Kanban.MobileApiDocsTest do
  @moduledoc """
  Guards the route table in `docs/api/me.md` (W2780).

  The page is the map of the person API the Stride mobile apps call. Its table
  must list exactly the routes `KanbanWeb.Router` mounts under `/api/me` and
  exactly the operations the OpenAPI contract, `priv/openapi/stride-api.json`,
  describes there, so a route added to either cannot land without its row and
  a removed route cannot leave a stale one behind. The Plan-gated column must
  mark only `GET /api/me` and the four device routes as never gated
  (design §10).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @doc_path "docs/api/me.md"
  @contract_path "priv/openapi/stride-api.json"
  @row ~r/^\| `(GET|POST|PUT|PATCH|DELETE) (\/api\/me[^`]*)` \| .+ \| (Yes|No) \|$/m

  describe "the route table in docs/api/me.md" do
    test "lists exactly the routes the router mounts under /api/me" do
      documented = documented_routes() |> Map.keys() |> MapSet.new()

      # Guards against a parse that finds nothing and passes.
      assert MapSet.size(documented) > 20

      assert documented == router_routes()
    end

    test "lists exactly the /api/me operations in the OpenAPI contract" do
      documented =
        documented_routes()
        |> Map.keys()
        |> MapSet.new(fn {verb, path} -> {verb, String.replace(path, ~r/:(\w+)/, "{\\1}")} end)

      assert documented == contract_operations()
    end

    test "marks only GET /api/me and the device routes as not plan-gated" do
      ungated =
        for {route, "No"} <- documented_routes(), into: MapSet.new(), do: route

      assert ungated ==
               MapSet.new([
                 {"GET", "/api/me"},
                 {"GET", "/api/me/devices"},
                 {"PUT", "/api/me/devices/current"},
                 {"DELETE", "/api/me/devices/current"},
                 {"DELETE", "/api/me/devices/:id"}
               ])
    end
  end

  defp documented_routes do
    @root
    |> Path.join(@doc_path)
    |> File.read!()
    |> then(&Regex.scan(@row, &1))
    |> Map.new(fn [_, verb, path, gated] -> {{verb, path}, gated} end)
  end

  defp router_routes do
    for %{verb: verb, path: path} <- Phoenix.Router.routes(KanbanWeb.Router),
        me_path?(path),
        into: MapSet.new(),
        do: {verb |> Atom.to_string() |> String.upcase(), path}
  end

  defp contract_operations do
    @root
    |> Path.join(@contract_path)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("paths")
    |> Enum.filter(fn {path, _} -> me_path?(path) end)
    |> Enum.flat_map(&operations/1)
    |> MapSet.new()
  end

  defp operations({path, operations}) do
    for verb <- ~w(get post put patch delete),
        Map.has_key?(operations, verb),
        do: {String.upcase(verb), path}
  end

  defp me_path?(path), do: path == "/api/me" or String.starts_with?(path, "/api/me/")
end
