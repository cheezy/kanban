defmodule KanbanWeb.API.Agent.WorkspaceTokenDocs do
  @moduledoc """
  The `api_reference.workspace_tokens` section of the agent onboarding payload
  (W2220): how a workspace-scoped token names the board each request acts on.
  Kept out of `KanbanWeb.API.AgentJSON` to hold that module under the size
  limit, like `EndpointDocs`. Pure data.
  """

  @docs_base_url "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main"

  @doc "The `api_reference.workspace_tokens` section of the onboarding payload."
  def summary do
    %{
      description:
        "A token is either board-scoped (one board) or workspace-scoped. Only an org-admin of an Organization workspace creates a workspace token, on the workspace settings page, and it acts as that org-admin on every board of the workspace they can modify.",
      board_selector: %{
        header: "X-Stride-Board",
        parameter: "board_id",
        rule:
          "With a workspace token, every request except GET /api/boards must name its board by id in the X-Stride-Board header or the board_id parameter. Board tokens ignore both."
      },
      errors: %{
        "400" => "No board named, or the header and parameter name different boards.",
        "404" =>
          "The board does not exist, is outside the token's workspace, or its user can no longer modify it. The body is the same in every case."
      },
      discovery: "GET /api/boards lists the board ids the token can use.",
      mcp: "MCP clients using a workspace token send X-Stride-Board on every POST /api/mcp.",
      expiry_days: 90,
      revocation:
        "A workspace token is revoked when its user stops being an org-admin of the Organization or leaves the workspace, and an org-admin can revoke it on the workspace settings page.",
      documentation_url: "#{@docs_base_url}/docs/api/get_boards.md"
    }
  end
end
