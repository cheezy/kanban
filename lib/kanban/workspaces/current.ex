defmodule Kanban.Workspaces.Current do
  @moduledoc """
  The workspace a signed-in user is acting in, kept in the session as
  `current_workspace_id` (D7: workspaces are paid-only).

  `KanbanWeb.UserAuth` calls `put_current/2` for every controller request and
  LiveView mount, so the id in the session is only ever a hint. It is accepted
  only when it names a workspace in the user's switcher list — their
  Organization's reachable, unarchived org workspaces
  (`Kanban.Workspaces.list_workspaces_for_membership/2`). That is
  `Kanban.Workspaces.get_workspace/2`'s reach rule with archived workspaces and
  the user's own personal workspace (which `get_workspace/2` still returns)
  refused, read in one query that also fills the switcher. Any other id — stale,
  removed, archived, personal, another Organization's or garbage — falls back
  to the first workspace in the list, or to none. Nothing here crashes on a bad
  id or grants access through one.

  A user without an Organization never has a current workspace, and costs no
  query.

  `switchable/2` is the stricter check behind `POST /workspace/switch`.
  `group_boards/2` splits the `/boards` list into the current workspace's
  boards, Personal boards and other shared boards.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Plans
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace

  @max_bigint 9_223_372_036_854_775_807

  @type groups :: %{workspace: [Board.t()], personal: [Board.t()], shared: [Board.t()]}

  @doc """
  Sets the scope's switcher list (`workspaces`) and its current `workspace`
  from `session_workspace_id`, falling back as the moduledoc describes.

  ## Examples

      iex> put_current(member_scope, workspace.id)
      %Scope{workspace: %Workspace{}, workspaces: [%Workspace{}, ...]}

      iex> put_current(free_user_scope, workspace.id)
      %Scope{workspace: nil, workspaces: []}

  """
  @spec put_current(Scope.t(), term()) :: Scope.t()
  def put_current(
        %Scope{user: %User{} = user, organization_membership: %OrganizationMember{} = membership} =
          scope,
        session_workspace_id
      ) do
    workspaces = Workspaces.list_workspaces_for_membership(user, membership)
    requested = parse_id(session_workspace_id)

    current =
      Enum.find(workspaces, &(&1.id == requested)) || List.first(workspaces)

    %{scope | workspaces: workspaces}
    |> Scope.put_workspace(current)
  end

  def put_current(%Scope{} = scope, _session_workspace_id) do
    %{scope | workspaces: []}
    |> Scope.put_workspace(nil)
  end

  @doc """
  Returns `{:ok, workspace}` when `scope`'s user may switch to the workspace
  with `id`, else `:error`.

  The user needs paid access — checked through `Kanban.Plans`, and also
  directly, because the plan check lets everyone through while plans are not
  enforced and workspaces exist only for Organizations — and must reach the
  workspace (`Kanban.Workspaces.get_workspace/2`), which must be neither
  archived nor personal.
  """
  @spec switchable(Scope.t(), term()) :: {:ok, Workspace.t()} | :error
  def switchable(%Scope{user: %User{} = user} = scope, id) do
    with :ok <- Plans.check_user(scope, :workspaces, surface: :controller),
         true <- Plans.user_has_paid_access?(scope),
         %Workspace{personal: false, archived_at: nil} = workspace <-
           Workspaces.get_workspace(id, user) do
      {:ok, workspace}
    else
      _ -> :error
    end
  end

  def switchable(_scope, _id), do: :error

  @doc """
  Splits `boards`, the user's accessible boards, for `/boards`.

  Returns `nil` when `scope` has no current workspace, so the page keeps its
  flat list. Otherwise returns `%{workspace: ..., personal: ..., shared: ...}`:
  the boards in the current workspace, the boards in the user's personal
  workspace, and every other board. Order within each group is kept.

  `boards` must already be filtered to the user's effective access, so a board
  in their personal workspace that they have no `board_users` row on (placed
  there by the W2217 backfill) never appears in any group.
  """
  @spec group_boards([Board.t()], Scope.t()) :: groups() | nil
  def group_boards(_boards, %Scope{workspace: nil}), do: nil

  def group_boards(boards, %Scope{workspace: %Workspace{id: workspace_id}, user: %User{} = user}) do
    personal_id = personal_workspace_id(user)

    groups =
      Enum.group_by(boards, fn
        %{workspace_id: ^workspace_id} -> :workspace
        %{workspace_id: id} when id == personal_id and not is_nil(id) -> :personal
        _other -> :shared
      end)

    to_groups(groups)
  end

  defp personal_workspace_id(user) do
    case Workspaces.get_personal_workspace(user) do
      %Workspace{id: id} -> id
      nil -> nil
    end
  end

  defp to_groups(groups) do
    %{
      workspace: Map.get(groups, :workspace, []),
      personal: Map.get(groups, :personal, []),
      shared: Map.get(groups, :shared, [])
    }
  end

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil
end
