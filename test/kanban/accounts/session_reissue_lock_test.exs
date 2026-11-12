defmodule Kanban.Accounts.SessionReissueLockTest do
  @moduledoc """
  Shows that `Kanban.Accounts.SessionReissue.reissue/3` serialises two
  parallel reissues of one session token on its row lock (D425), using real,
  separate Postgres sessions: both wait on a held FOR UPDATE lock on the
  replaced token's row, and once it is released one mints the successor and
  the other is handed that same successor. Without the lock both would read
  the row unlinked and each mint its own successor.

  The test sandbox never commits, so these sessions cannot see sandboxed rows.
  This module therefore checks out unsandboxed connections and commits its
  fixtures for real, which is why it is not async; `on_exit` deletes them.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.SessionReissue
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserToken
  alias Kanban.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    uniq = System.unique_integer([:positive])
    user = Repo.insert!(%User{email: "session-reissue-lock-#{uniq}@example.com"})
    {token, user_token} = UserToken.build_session_token(user)
    row = Repo.insert!(user_token)
    old = DateTime.utc_now(:second) |> DateTime.add(-10, :day)

    from(t in UserToken, where: t.id == ^row.id)
    |> Repo.update_all(set: [inserted_at: old, authenticated_at: old])

    on_exit(fn -> delete_committed(user.id) end)

    %{user: user, token: token, row_id: row.id}
  end

  test "two parallel reissues of one token share a single successor", ctx do
    holder = hold_token_lock(ctx.row_id)

    first = start_reissue(ctx)
    second = start_reissue(ctx)
    await_lock_waiters(2)

    send(holder.pid, :proceed)
    assert Task.await(holder) == {:ok, :released}

    results = [Task.await(first), Task.await(second)]

    assert [{:ok, successor, _}, {:ok, successor, _}] = results
    assert results |> Enum.map(&elem(&1, 2)) |> Enum.sort() == [ctx.row_id, nil] |> Enum.sort()
    assert session_rows(ctx.user) |> Enum.sort() == Enum.sort([ctx.token, successor])
  end

  # A second session that locks the token row FOR UPDATE and holds it until
  # told to proceed, then commits without writing.
  defp hold_token_lock(row_id) do
    test_pid = self()
    conn = second_session()

    holder =
      Task.async(fn ->
        Postgrex.transaction(conn, fn c ->
          Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])
          Postgrex.query!(c, "SELECT id FROM users_tokens WHERE id = $1 FOR UPDATE", [row_id])
          send(test_pid, :holding)
          receive do: (:proceed -> :released)
        end)
      end)

    assert_receive :holding, 5_000
    holder
  end

  defp start_reissue(ctx) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      SessionReissue.reissue(ctx.user, ctx.token, 3600)
    end)
  end

  defp await_lock_waiters(expected, attempts \\ 500)

  defp await_lock_waiters(expected, 0),
    do: flunk("expected #{expected} sessions waiting on a lock, saw #{lock_waiters()}")

  defp await_lock_waiters(expected, attempts) do
    if lock_waiters() == expected do
      :ok
    else
      Process.sleep(10)
      await_lock_waiters(expected, attempts - 1)
    end
  end

  defp lock_waiters do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    count
  end

  defp session_rows(user) do
    from(t in UserToken, where: t.user_id == ^user.id and t.context == "session", select: t.token)
    |> Repo.all()
  end

  # A raw connection outside the sandbox: another Postgres session whose row
  # locks really contend with the others'. Linked to the test process, so it
  # closes when the test ends.
  defp second_session do
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
    {:ok, conn} = Postgrex.start_link(config)
    conn
  end

  # on_exit runs in its own process, which needs its own connection.
  defp delete_committed(user_id) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    from(t in UserToken, where: t.user_id == ^user_id) |> Repo.delete_all()
    from(u in User, where: u.id == ^user_id) |> Repo.delete_all()
  end
end
