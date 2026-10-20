defmodule Kanban.Workspaces.InvitationCapLockTest do
  @moduledoc """
  Shows that accepting a free-board invitation counts the board's members
  under the same row lock as `Kanban.Boards.add_user_to_board/4`, so two
  joins racing for the last seat cannot both succeed (W2219).

  The competing join holds the board lock from a second, real Postgres
  session, the way `Kanban.Boards.MemberCapLockTest` does it; see that module
  for why the fixtures are committed for real and deleted in `on_exit`. The
  acceptance under test runs inside a transaction the test rolls back.

  It also switches the global `:plans_enforced` application env on.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Kanban.PlansHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.Invitations
  alias Kanban.Workspaces.Workspace

  @hold_ms 300

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    enforce_plans()

    owner = committed_user()
    member = committed_user()
    competitor_user = committed_user()
    invitee = committed_user()
    {:ok, workspace} = Workspaces.ensure_personal_workspace(owner)

    board =
      Repo.insert!(%Board{
        name: "Invite cap lock #{System.unique_integer([:positive])}",
        workspace_id: workspace.id
      })

    Repo.insert!(%BoardUser{board_id: board.id, user_id: owner.id, access: :owner})
    Repo.insert!(%BoardUser{board_id: board.id, user_id: member.id, access: :modify})

    {token, hash} = Invitation.build_token()

    Repo.insert!(%Invitation{
      workspace_id: workspace.id,
      email: invitee.email,
      board_id: board.id,
      board_access: :read_only,
      token_hash: hash,
      invited_by_id: owner.id,
      expires_at: Invitation.expires_at_from(DateTime.utc_now())
    })

    user_ids = Enum.map([owner, member, competitor_user, invitee], & &1.id)
    on_exit(fn -> delete_committed(board.id, workspace.id, user_ids) end)

    %{
      board: board,
      competitor_user: competitor_user,
      invitee: invitee,
      token: token
    }
  end

  test "an invitation accepted while another join holds the last seat is refused", ctx do
    competitor = hold_third_member(ctx)

    {elapsed_ms, result} = accept_and_roll_back(ctx)

    assert {:ok, :committed} = Task.await(competitor)

    # Without the board lock the count would read 2, because the competitor's
    # insert had not committed yet, and the invitee would become the fourth.
    assert result == {:error, {:error, :member_cap_reached}}
    assert elapsed_ms >= @hold_ms - 50
    assert member_ids(ctx.board.id) |> length() == 3
    refute ctx.invitee.id in member_ids(ctx.board.id)
  end

  defp hold_third_member(ctx) do
    test_pid = self()
    conn = second_session()

    competitor =
      Task.async(fn ->
        Postgrex.transaction(conn, fn c ->
          Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])
          Postgrex.query!(c, "SELECT id FROM boards WHERE id = $1 FOR UPDATE", [ctx.board.id])

          Postgrex.query!(
            c,
            "INSERT INTO board_users (board_id, user_id, access, inserted_at, updated_at) " <>
              "VALUES ($1, $2, 'modify', now(), now())",
            [ctx.board.id, ctx.competitor_user.id]
          )

          send(test_pid, :competitor_holding)
          Process.sleep(@hold_ms)
          :committed
        end)
      end)

    assert_receive :competitor_holding, 5_000
    competitor
  end

  # Accepts inside a transaction that is always rolled back, returning the
  # elapsed time and accept/2's result wrapped as {:error, result}.
  defp accept_and_roll_back(ctx) do
    started = System.monotonic_time(:millisecond)

    result =
      Repo.transaction(fn ->
        Repo.rollback(Invitations.accept(ctx.token, ctx.invitee))
      end)

    {System.monotonic_time(:millisecond) - started, result}
  end

  defp committed_user do
    Repo.insert!(%User{
      email: "invite-cap-lock-#{System.unique_integer([:positive])}@example.com",
      confirmed_at: DateTime.utc_now(:second)
    })
  end

  defp second_session do
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
    {:ok, conn} = Postgrex.start_link(config)
    conn
  end

  defp member_ids(board_id) do
    from(bu in BoardUser, where: bu.board_id == ^board_id, select: bu.user_id)
    |> Repo.all()
  end

  # on_exit runs in its own process, which needs its own connection.
  defp delete_committed(board_id, workspace_id, user_ids) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    from(i in Invitation, where: i.workspace_id == ^workspace_id) |> Repo.delete_all()
    from(bu in BoardUser, where: bu.board_id == ^board_id) |> Repo.delete_all()
    from(b in Board, where: b.id == ^board_id) |> Repo.delete_all()
    from(w in Workspace, where: w.id == ^workspace_id) |> Repo.delete_all()
    from(u in User, where: u.id in ^user_ids) |> Repo.delete_all()
  end
end
