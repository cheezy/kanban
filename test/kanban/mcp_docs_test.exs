defmodule Kanban.McpDocsTest do
  @moduledoc """
  Keeps `docs/MCP.md` in step with the MCP server (W2429).

  The tool table must name every tool `KanbanWeb.MCP.ToolSchemas` serves, with
  the required arguments its `inputSchema` lists, and a claim that is true only
  while paid plans are enforced (`:plans_enforced`) must say so.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.MCP.ToolSchemas

  @doc_path Path.expand("../../docs/MCP.md", __DIR__)

  setup_all do
    %{doc: File.read!(@doc_path)}
  end

  describe "the tool table in docs/MCP.md" do
    test "has one row for every tool the server serves, and no other", %{doc: doc} do
      served = ToolSchemas.all() |> Enum.map(& &1["name"]) |> Enum.sort()

      documented =
        ~r/^\| `(stride_[a-z_]+)` \|/m
        |> Regex.scan(doc, capture: :all_but_first)
        |> List.flatten()
        |> Enum.sort()

      assert length(served) == 6
      assert documented == served
    end

    test "names every argument a tool's schema requires", %{doc: doc} do
      for %{"name" => name, "inputSchema" => schema} <- ToolSchemas.all(),
          required <- Map.get(schema, "required", []) do
        [row] = Regex.run(~r/^\| `#{name}` \|.*$/m, doc)

        assert row =~ "`#{required}`",
               "the #{name} row in docs/MCP.md does not name required argument #{required}"
      end
    end
  end

  describe "claims that depend on paid-plan enforcement" do
    test "the -32001 error row says it applies only while paid plans are enforced", %{doc: doc} do
      [row] = Regex.run(~r/^\| `-32001` \|.*$/m, doc)

      assert row =~ "while paid plans are enforced"
    end

    test "the Organization requirement names the enforcement condition", %{doc: doc} do
      [paragraph] = Regex.run(~r/\*\*Organization requirement\.\*\*.*?\n\n/s, doc)

      assert paragraph =~ "paid plans"
      assert paragraph =~ "-32001"
    end
  end
end
