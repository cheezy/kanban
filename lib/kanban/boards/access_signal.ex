defmodule Kanban.Boards.AccessSignal do
  @moduledoc """
  The per-user signal for a board-access gain that sends no
  `board_access_changed` notification (D466).

  The app's live channels (`KanbanWeb.AgentsChannel` on `me:agents`,
  `KanbanWeb.InboxChannel` on `me:inbox`) hear a lost board on its
  `"board:<id>"` topic, which they already subscribe to (D460). A gained board
  is the reverse: its topic is the one they are not subscribed to yet. So the
  paths that grant access without a notification also broadcast
  `{Kanban.Boards, :access_gained, board_ids}` on each gaining user's own
  topic, `"user:<id>:board_access"`, and the channels rebuild and re-subscribe
  their board topics (`KanbanWeb.MeChannel.sync_boards/2`) when it arrives:

    * `board_gained/1`: a board created (`Kanban.Boards.Creation`) or moved
      into an Organization workspace (`Kanban.Workspaces.BoardMoves`), for
      every user with a `board_users` row on it and every org-admin of the
      Organization whose workspace holds it. Org-admins reach it through
      derived access (`Kanban.Workspaces.Policy`), and a row-holder may find
      it unlocked by the Organization's plan.
    * `organization_gained/2`: a user who became an org-admin
      (`Kanban.Organizations.MembershipWrites.appoint_org_admin/4`), for
      every board in the Organization's workspaces.

  Plain Organization membership grants no board access, so adding a member
  (including SCIM provisioning) sends nothing.

  A workspace import (`Kanban.Workspaces.Export.Importer`) sends nothing
  either, although it creates boards that the Organization's org-admins and
  the matched members gain. It runs from `mix kanban.import_workspace` or
  `Kanban.Release.import_workspace/3`, outside the web nodes and without the
  application (only the database connection and the HTTP client that
  attachment storage needs), so there is no PubSub to broadcast on and no
  channel that could hear it; the importer calls no broadcasting context
  function for the same reason. An open channel picks the imported boards up
  on its next rebuild, and any channel joined after the import covers them.

  The message carries ids only, never a board name or task content, because
  it fans out over PubSub. It is only a wake-up: a channel re-reads what the
  person may see from the context for their own scope, so a signal can never
  widen it, and a board id in it is never subscribed directly. The topic is
  separate from the notification topic (`Kanban.Notifications.Broadcaster`)
  so the notification bell's hook, which passes unknown messages on to every
  authenticated LiveView, never sees it.

  Both functions read the audience and broadcast through
  `Kanban.Telemetry.AfterCommit.defer/2`: straight away when called after a
  commit, as both callers do, and held until the outer commit when the
  caller's transaction is wrapped in `Kanban.Telemetry.AfterCommit.after_commit/1`.
  A user with no open channel has no subscriber, so the broadcast is a no-op.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Telemetry.AfterCommit
  alias Kanban.Workspaces.Workspace

  @doc """
  Returns the PubSub topic carrying one user's board-access gains.
  """
  @spec topic(Scope.t() | User.t() | pos_integer()) :: String.t()
  def topic(%Scope{user: %User{id: id}}), do: topic(id)
  def topic(%User{id: id}), do: topic(id)
  def topic(user_id) when is_integer(user_id), do: "user:#{user_id}:board_access"

  @doc """
  Subscribes the calling process to a user's board-access topic. The topic
  comes from the server-side scope or user, never from a client.
  """
  @spec subscribe(Scope.t() | User.t() | pos_integer()) :: :ok | {:error, term()}
  def subscribe(scope_or_user), do: Phoenix.PubSub.subscribe(Kanban.PubSub, topic(scope_or_user))

  @doc """
  Signals a gain of the board with `board_id` to every user with a
  `board_users` row on it and every org-admin of the Organization whose
  workspace holds it. Call it once the board's change has committed. Returns
  `:ok`.
  """
  @spec board_gained(integer()) :: :ok
  def board_gained(board_id) when is_integer(board_id) do
    AfterCommit.defer(fn ->
      board_id |> board_audience() |> Enum.each(&broadcast(&1, [board_id]))
    end)
  end

  @doc """
  Signals to the user with `user_id` a gain of every board in the
  Organization with `organization_id`, as after they became its org-admin.
  An Organization with no boards sends nothing. Returns `:ok`.
  """
  @spec organization_gained(integer(), integer()) :: :ok
  def organization_gained(user_id, organization_id)
      when is_integer(user_id) and is_integer(organization_id) do
    AfterCommit.defer(fn ->
      case organization_board_ids(organization_id) do
        [] -> :ok
        board_ids -> broadcast(user_id, board_ids)
      end
    end)
  end

  @doc """
  The ids of the users who can reach the board with `board_id`: its
  `board_users` rows and the org-admins of the Organization whose workspace
  holds it, ordered by id.
  """
  @spec board_audience(integer()) :: [integer()]
  def board_audience(board_id) when is_integer(board_id) do
    org_admins =
      from(m in OrganizationMember,
        join: w in Workspace,
        on: w.organization_id == m.organization_id,
        join: b in Board,
        on: b.workspace_id == w.id,
        where: b.id == ^board_id and m.role == ^:org_admin,
        select: m.user_id
      )

    from(bu in BoardUser, where: bu.board_id == ^board_id, select: bu.user_id)
    |> union(^org_admins)
    |> Repo.all()
    |> Enum.sort()
  end

  @doc """
  The ids of the boards in the Organization with `organization_id`'s
  workspaces, ordered by id.
  """
  @spec organization_board_ids(integer()) :: [integer()]
  def organization_board_ids(organization_id) when is_integer(organization_id) do
    from(b in Board,
      join: w in Workspace,
      on: w.id == b.workspace_id,
      where: w.organization_id == ^organization_id,
      order_by: b.id,
      select: b.id
    )
    |> Repo.all()
  end

  defp broadcast(user_id, board_ids) do
    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      topic(user_id),
      {Kanban.Boards, :access_gained, board_ids}
    )
  end
end
