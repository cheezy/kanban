defmodule Kanban.ApiTokens.DeniedAudit do
  @moduledoc """
  The `permission_denied` audit row for an API request refused by a board
  gate: `:api_board_selector` (a workspace token named a board it may not use,
  `KanbanWeb.Plugs.AuthenticateApiToken`) and `:api_board_read` (a board
  token's user lost access to its board, `KanbanWeb.API.BoardReadAccess`).

  Two things set these rows apart from other `permission_denied` events:

    * **Organization.** The row carries the `organization_id` of the token's
      Organization, so it is part of that Organization's audit log and export
      (`/org/audit`). A workspace token's Organization is its workspace's; a
      board token's is that of the workspace holding its board. A token outside
      any Organization (a personal workspace) writes the row without one, as
      before.
    * **Throttle.** A token can repeat a refused request as fast as it likes,
      and each refusal wrote a row: one token produced 425 rows in a session.
      So at most one row is written per token and gate in each window of the
      `:api_denied_audit` surface of `Kanban.RateLimit` (5 minutes by
      default). The refusal itself is unchanged, the
      `[:kanban, :api, :auth_failed]` telemetry still counts every selector
      refusal, and each suppressed row emits
      `[:kanban, :rate_limit, :denied]` with `surface: :api_denied_audit`.

  A request without a token (no route allows one here) writes its row
  unthrottled and without an Organization.
  """

  import Ecto.Query, warn: false

  alias Kanban.ApiTokens.ApiToken
  alias Kanban.AuditLog
  alias Kanban.RateLimit
  alias Kanban.Repo
  alias Kanban.Workspaces.Workspace

  @type gate :: :api_board_selector | :api_board_read

  @doc """
  Writes the `permission_denied` row for `gate`, refused for the user
  `user_id` holding `api_token`, unless this token already wrote one for
  `gate` in the current throttle window. Always returns `:ok`.
  """
  @spec record(ApiToken.t() | nil, pos_integer() | nil, gate()) :: :ok
  def record(api_token, user_id, gate) when is_atom(gate) do
    if write?(api_token, gate) do
      AuditLog.event(:permission_denied, audit_fields(api_token, user_id, gate))
    end

    :ok
  end

  @doc """
  The id of the Organization `api_token` belongs to, or `nil`: its workspace's
  Organization for a workspace token, and the Organization of the workspace
  holding its board for a board token.
  """
  @spec organization_id(ApiToken.t() | nil) :: pos_integer() | nil
  def organization_id(%ApiToken{workspace: %Workspace{organization_id: organization_id}}),
    do: organization_id

  def organization_id(%ApiToken{workspace_id: workspace_id}) when is_integer(workspace_id),
    do: workspace_organization_id(workspace_id)

  def organization_id(%ApiToken{board: %{workspace_id: workspace_id}})
      when is_integer(workspace_id),
      do: workspace_organization_id(workspace_id)

  def organization_id(_api_token), do: nil

  defp write?(%ApiToken{id: id}, gate) when is_integer(id),
    do: RateLimit.check(:api_denied_audit, identity: "token:#{id}:#{gate}") == :ok

  defp write?(_api_token, _gate), do: true

  defp audit_fields(api_token, user_id, gate) do
    case organization_id(api_token) do
      nil -> [user_id: user_id, gate: gate]
      organization_id -> [user_id: user_id, gate: gate, organization_id: organization_id]
    end
  end

  defp workspace_organization_id(workspace_id) do
    from(w in Workspace, where: w.id == ^workspace_id, select: w.organization_id)
    |> Repo.one()
  end
end
