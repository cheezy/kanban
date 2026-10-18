defmodule Kanban.Plans do
  @moduledoc """
  The plan check. **This module is the only place that decides paid versus
  free.** Every lock, the free-board member cap and every paid gate calls it,
  and nothing else reads the `:plans_enforced` flag. See section 5 of
  `docs/plans/PAYING-ORGANIZATIONS-DESIGN.md`.

  ## Paid status

    * A **board** is paid only when its workspace belongs to an Organization
      (`workspaces.organization_id` is set). Who is asking does not matter, so
      an Organization member's personal-workspace board is free. A board with
      no workspace is free.
    * A **user** has paid access when they are a member of an Organization, in
      either role. This decides only whether user-level paid UI shows unlocked;
      board-level features still resolve per board.

  The decision depends only on the board or the user handed in. No function
  here takes request parameters, so a caller cannot influence the answer
  except through which board or user it asks about.

  ## Enforcement

  `enforced?/0` reads `Application.get_env(:kanban, :plans_enforced, false)` at
  call time, never with `compile_env`, because launch flips the flag with a
  restart rather than a rebuild. The flag is false in every environment until
  the deployment sets `STRIDE_PLANS_ENFORCED=true` (see `config/runtime.exs`).
  Only the deployment environment can switch it on; no request parameter or API
  field reads or writes it.

  `board_unlocked?/1` and `user_unlocked?/1` are true whenever enforcement is
  off, without touching the database. Render-time UI uses them.

  Paid status is never cached in a process or ETS: a board can move into an
  Organization at any time.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces.Workspace

  @doc """
  Returns true only when paid-plan enforcement is switched on.

  Reads the `:plans_enforced` application env at call time and treats any value
  other than the boolean `true` as off.
  """
  @spec enforced?() :: boolean()
  def enforced?, do: Application.get_env(:kanban, :plans_enforced, false) == true

  @doc """
  Returns true when the board's workspace belongs to an Organization.

  Accepts a `%Board{}` or a board id. A board whose workspace is preloaded is
  decided without a query; a board without a preloaded workspace, or a board
  id, costs one query. A board with no workspace, and an id that matches no
  board, are free.
  """
  @spec paid_board?(Board.t() | integer()) :: boolean()
  def paid_board?(%Board{workspace: %Workspace{organization_id: organization_id}}),
    do: not is_nil(organization_id)

  def paid_board?(%Board{workspace: nil}), do: false
  def paid_board?(%Board{id: id}) when is_integer(id), do: paid_board?(id)
  def paid_board?(%Board{}), do: false

  def paid_board?(board_id) when is_integer(board_id) do
    from(b in Board,
      join: w in assoc(b, :workspace),
      where: b.id == ^board_id,
      select: not is_nil(w.organization_id)
    )
    |> Repo.one()
    |> Kernel.==(true)
  end

  @doc """
  Returns true when the user belongs to an Organization, in either role.

  Accepts a `%User{}` or a `%Scope{}`. A scope that carries its
  `organization_membership` is decided without a query. A scope without one
  (scopes built outside `KanbanWeb.UserAuth` leave it `nil`) falls back to
  `Kanban.Organizations.get_membership/1`. A scope without a user, and `nil`,
  have no paid access.
  """
  @spec user_has_paid_access?(User.t() | Scope.t() | nil) :: boolean()
  def user_has_paid_access?(%Scope{organization_membership: %OrganizationMember{}}), do: true
  def user_has_paid_access?(%Scope{user: %User{} = user}), do: user_has_paid_access?(user)
  def user_has_paid_access?(%Scope{}), do: false
  def user_has_paid_access?(%User{} = user), do: not is_nil(Organizations.get_membership(user))
  def user_has_paid_access?(nil), do: false

  @doc """
  Returns true when enforcement is off or the board is paid.

  Accepts what `paid_board?/1` accepts. When enforcement is off it never
  queries.
  """
  @spec board_unlocked?(Board.t() | integer()) :: boolean()
  def board_unlocked?(board), do: not enforced?() or paid_board?(board)

  @doc """
  Returns true when enforcement is off or the user has paid access.

  Accepts what `user_has_paid_access?/1` accepts. When enforcement is off it
  never queries.
  """
  @spec user_unlocked?(User.t() | Scope.t() | nil) :: boolean()
  def user_unlocked?(user_or_scope), do: not enforced?() or user_has_paid_access?(user_or_scope)
end
