defmodule Kanban.ApiTokens.WorkspaceTokens do
  @moduledoc """
  Workspace-scoped API tokens (W2220), delegated from `Kanban.ApiTokens`.

  A workspace token belongs to an Organization workspace instead of a board,
  so one credential reaches every board of that workspace its user can work on.
  Only an enabled org-admin of the workspace's Organization creates or revokes
  one, and the token acts as that user. Archiving the workspace revokes all of
  its tokens (`revoke_workspace_tokens/1`).

  The token stores no board and no access grant. Every request names its board
  (`KanbanWeb.Plugs.AuthenticateApiToken`), and `fetch_workspace_board/2`
  re-derives access then through `Kanban.Workspaces.Policy`, so a token whose
  user stopped being an org-admin keeps only that user's explicit `board_users`
  access, with nothing cached in the token. Losing org-admin status, which
  also ends the Organization membership, revokes the user's workspace tokens
  outright, and so does leaving a workspace: both run
  `Kanban.Workspaces.MembershipCascade.remove/2`.

  A board is usable through a workspace token when all of these hold:

    * it is in the token's workspace, which is an unarchived org workspace,
    * it is an AI Optimized board, as for board tokens, and
    * the token's user has `:owner` or `:modify` access to it, the access a
      board token requires to be minted and keeps (W1430 revokes it at
      `:read_only`).
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Boards.Board
  alias Kanban.Organizations
  alias Kanban.Organizations.Organization
  alias Kanban.Repo
  alias Kanban.Workspaces.Policy
  alias Kanban.Workspaces.Workspace

  @usable_access [:owner, :modify]
  @max_bigint 9_223_372_036_854_775_807

  @doc """
  Creates a token for `workspace` acting as `user`, who must be an enabled
  org-admin of the workspace's Organization.

  The org-admin check and the insert share one transaction that first takes a
  share lock on the Organization row, so a removal of the org-admin that
  commits first is seen and the token refused, and one that starts later waits
  for the insert and then revokes the new token with the others. The workspace
  row is read under a share lock too, so an archive that commits first is seen
  (`{:error, :archived}`), and one that starts later waits for the insert and
  then revokes the new token.

  `attrs` takes the same fields as a board token (`name`, `agent_capabilities`,
  ...). Any `user_id` or `workspace_id` in it is overwritten.

  Returns `{:ok, {api_token, plain_text_token}}` (show the plain text once and
  never store it), `{:error, :unauthorized}` for a personal workspace, a missing
  workspace or a user who is not an org-admin there, `{:error, :archived}` for
  an archived workspace, and `{:error, changeset}` for invalid attributes.
  """
  @spec create_workspace_api_token(User.t(), Workspace.t() | integer(), map()) ::
          {:ok, {ApiToken.t(), String.t()}}
          | {:error, :unauthorized | :archived | Ecto.Changeset.t()}
  def create_workspace_api_token(%User{} = user, workspace, attrs \\ %{}) do
    workspace_id = workspace_id(workspace)

    fn -> create_locked(user, workspace_id, attrs) end
    |> Repo.transaction()
    |> report_created()
  end

  defp create_locked(user, workspace_id, attrs) do
    lock_organization(workspace_id)

    with {:ok, workspace} <- manageable_workspace(user, workspace_id),
         {:ok, api_token, plain_text} <- insert_token(user, workspace, attrs) do
      {api_token, plain_text, workspace}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp manageable_workspace(user, workspace_id) do
    case workspace_id && lock_workspace(workspace_id) do
      %Workspace{personal: false, organization_id: org_id} = workspace
      when is_integer(org_id) ->
        authorize_manager(user, workspace)

      _missing_or_personal ->
        {:error, :unauthorized}
    end
  end

  defp authorize_manager(user, %Workspace{} = workspace) do
    cond do
      not Organizations.org_admin?(user, workspace.organization_id) -> {:error, :unauthorized}
      not is_nil(workspace.archived_at) -> {:error, :archived}
      true -> {:ok, workspace}
    end
  end

  defp lock_workspace(workspace_id) do
    from(w in Workspace, where: w.id == ^workspace_id, lock: "FOR SHARE")
    |> Repo.one()
  end

  defp insert_token(user, workspace, attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("user_id", user.id)
      |> Map.put("workspace_id", workspace.id)

    changeset = ApiToken.workspace_changeset(%ApiToken{}, attrs)

    case Repo.insert(changeset) do
      {:ok, api_token} -> {:ok, api_token, Ecto.Changeset.get_change(changeset, :token)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp lock_organization(nil), do: :ok

  defp lock_organization(workspace_id) do
    organization_ids =
      from(w in Workspace,
        where: w.id == ^workspace_id and not is_nil(w.organization_id),
        select: w.organization_id
      )

    from(o in Organization,
      where: o.id in subquery(organization_ids),
      lock: "FOR SHARE",
      select: o.id
    )
    |> Repo.all()
  end

  defp report_created({:ok, {api_token, plain_text, workspace}}) do
    Kanban.Telemetry.emit(
      [:kanban, :api, :token_created],
      %{count: 1},
      %{user_id: api_token.user_id, workspace_id: workspace.id, token_id: api_token.id}
    )

    Kanban.AuditLog.event(:api_token_created,
      user_id: api_token.user_id,
      workspace_id: workspace.id,
      organization_id: workspace.organization_id,
      token_id: api_token.id
    )

    {:ok, {api_token, plain_text}}
  end

  defp report_created({:error, reason}), do: {:error, reason}

  @doc """
  Returns every token of `workspace`, revoked and expired ones included, newest
  first, with `:user` preloaded, for `actor`, who must be an enabled org-admin
  of the workspace's Organization. Anyone else gets `[]`: the role is checked
  here on every call, as for create and revoke, not left to the caller.
  """
  @spec list_workspace_api_tokens(User.t(), Workspace.t()) :: [ApiToken.t()]
  def list_workspace_api_tokens(%User{} = actor, %Workspace{id: workspace_id} = workspace) do
    if Policy.can_manage_workspace?(actor, workspace) do
      from(t in ApiToken,
        where: t.workspace_id == ^workspace_id,
        order_by: [desc: t.inserted_at, desc: t.id],
        preload: :user
      )
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  Revokes the token with `token_id` of `workspace`, for `actor`, who must be an
  enabled org-admin of the workspace's Organization.

  The id is only looked up among `workspace`'s own tokens, so an id from
  another workspace is `{:error, :not_found}`. Revoking a revoked token returns
  it unchanged.

  Returns `{:ok, api_token}`, `{:error, :unauthorized}` or `{:error, :not_found}`.
  """
  @spec revoke_workspace_api_token(User.t(), Workspace.t(), integer() | String.t()) ::
          {:ok, ApiToken.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def revoke_workspace_api_token(%User{} = actor, %Workspace{} = workspace, token_id) do
    with true <- Policy.can_manage_workspace?(actor, workspace) || {:error, :unauthorized},
         %ApiToken{} = api_token <- get_workspace_token(workspace, token_id) do
      revoke(api_token, workspace)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_workspace_token(%Workspace{id: workspace_id}, token_id) do
    case parse_id(token_id) do
      nil -> nil
      id -> ApiToken |> where([t], t.id == ^id and t.workspace_id == ^workspace_id) |> Repo.one()
    end
  end

  defp revoke(%ApiToken{revoked_at: nil} = api_token, workspace),
    do: ApiTokens.revoke_api_token(api_token, organization_id: workspace.organization_id)

  defp revoke(%ApiToken{} = api_token, _workspace), do: {:ok, api_token}

  @doc """
  Revokes every active workspace token `user_id` holds in the workspaces of
  `organization_id`, with one `update_all`. Call it inside the transaction that
  ends the user's org-admin status or Organization membership; it emits no
  telemetry, because that transaction may still roll back.

  Returns the number of tokens revoked.

  ## Examples

      iex> revoke_user_workspace_tokens(user.id, organization.id)
      1

  """
  @spec revoke_user_workspace_tokens(integer(), integer()) :: non_neg_integer()
  def revoke_user_workspace_tokens(user_id, organization_id)
      when is_integer(user_id) and is_integer(organization_id) do
    workspace_ids =
      from(w in Workspace, where: w.organization_id == ^organization_id, select: w.id)

    {count, _} =
      from(t in ApiToken,
        where:
          t.user_id == ^user_id and is_nil(t.revoked_at) and
            t.workspace_id in subquery(workspace_ids)
      )
      |> Repo.update_all(set: [revoked_at: DateTime.utc_now(:second)])

    count
  end

  @doc """
  Revokes every active token of the workspace with `workspace_id`, with one
  `update_all`. Call it inside the transaction that archives the workspace,
  after locking the workspace row; it emits no telemetry, because that
  transaction may still roll back.

  Returns the number of tokens revoked.

  ## Examples

      iex> revoke_workspace_tokens(workspace.id)
      2

  """
  @spec revoke_workspace_tokens(integer()) :: non_neg_integer()
  def revoke_workspace_tokens(workspace_id) when is_integer(workspace_id) do
    {count, _} =
      from(t in ApiToken, where: t.workspace_id == ^workspace_id and is_nil(t.revoked_at))
      |> Repo.update_all(set: [revoked_at: DateTime.utc_now(:second)])

    count
  end

  @doc """
  Resolves the board a workspace token's request named with `selector` (a board
  id, as an integer or a string of digits).

  Returns `{:ok, board}` with `board.workspace` set to the token's workspace
  when the board is usable through the token (see the moduledoc), and `:error`
  for every other case — a board that does not exist, one in another workspace
  or Organization, one the user cannot modify, and an id that is not a board id
  at all — so the caller can answer them all identically. It costs one query
  whenever the selector is a valid id, whatever the outcome, plus the loading
  of the token's workspace and user when they are not loaded yet.
  """
  @spec fetch_workspace_board(ApiToken.t(), integer() | String.t()) :: {:ok, Board.t()} | :error
  def fetch_workspace_board(%ApiToken{} = api_token, selector) do
    api_token |> with_owner_links() |> fetch_loaded_board(selector)
  end

  defp fetch_loaded_board(
         %ApiToken{workspace: %Workspace{} = workspace, user: %User{} = user},
         selector
       ) do
    case Policy.fetch_board(selector, user) do
      {%Board{} = board, access} ->
        if usable_workspace?(workspace) and usable_board?(board, access, workspace),
          do: {:ok, %{board | workspace: workspace}},
          else: :error

      nil ->
        :error
    end
  end

  defp fetch_loaded_board(%ApiToken{}, _selector), do: :error

  @doc """
  Returns the boards `api_token` can be used on, sorted by name: its one board
  for a board token, and the usable boards of its workspace for a workspace
  token (none when the workspace is archived). The token's board, workspace and
  user are loaded first when they are not, so the struct a create returns
  lists the same boards as one read back from the database.
  """
  @spec list_token_boards(ApiToken.t()) :: [Board.t()]
  def list_token_boards(%ApiToken{} = api_token) do
    api_token |> with_owner_links() |> loaded_token_boards()
  end

  defp loaded_token_boards(%ApiToken{workspace_id: nil, board: %Board{} = board}), do: [board]

  defp loaded_token_boards(%ApiToken{workspace: %Workspace{} = workspace, user: %User{} = user}) do
    if usable_workspace?(workspace) do
      user
      |> Policy.list_accessible_boards(workspace_id: workspace.id)
      |> Enum.filter(&usable_board?(&1, &1.user_access, workspace))
      |> Enum.sort_by(&{&1.name, &1.id})
    else
      []
    end
  end

  defp loaded_token_boards(%ApiToken{}), do: []

  # Loads only what is not loaded yet, so a token from the auth plug, which has
  # them all, costs no query here.
  defp with_owner_links(%ApiToken{} = api_token),
    do: Repo.preload(api_token, [:board, :workspace, :user])

  @doc """
  Returns `"workspace"` for a workspace token and `"board"` for a board token.
  """
  @spec token_scope(ApiToken.t()) :: String.t()
  def token_scope(%ApiToken{} = api_token) do
    if ApiToken.workspace_token?(api_token), do: "workspace", else: "board"
  end

  defp usable_workspace?(%Workspace{personal: false, archived_at: nil, organization_id: org_id}),
    do: is_integer(org_id)

  defp usable_workspace?(_workspace), do: false

  defp usable_board?(%Board{} = board, access, %Workspace{id: workspace_id}) do
    board.workspace_id == workspace_id and board.ai_optimized_board == true and
      access in @usable_access
  end

  defp workspace_id(%Workspace{id: id}), do: id
  defp workspace_id(id), do: parse_id(id)

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil
end
