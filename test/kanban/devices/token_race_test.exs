defmodule Kanban.Devices.TokenRaceTest do
  @moduledoc """
  Races the device token paths on real, committing Postgres sessions:

    * a revocation of a device against a rotation of its refresh token, by
      the person (`revoke_device/4`) and by the app signing out
      (`revoke_by_refresh_token/3`), in both orders and at random;
    * a replay of an authorization code against its first exchange, from
      the same and from the other client;
    * an exchange of an authorization code, and the issue of one, against a
      password reset or change of its user, in both orders (D459);
    * `PUT /api/me/devices/current` moving push tokens
      (`Kanban.Devices.CurrentDevice`): two devices trading their tokens, and
      two devices registering one fresh token, in both orders.

  The invariant after every race: a revoked device has no token that still
  works, whatever pair a rotation returned, and a push token is held by one
  device at most.

  The sandboxed tests cannot show this, since every process there shares
  one connection. Each forced order holds the contended row FOR UPDATE in a
  third session, starts the racers one at a time until each is queued on
  that lock, and then lets them go: Postgres grants a row lock to its
  waiters in the order they queued.

  ## Running

  These tests carry `@moduletag :device_token_race`, which
  `test/test_helper.exs` excludes, so the normal suite never runs them.
  Their rows commit, so they run only in a throwaway database whose name
  ends in `_race`, dropped before and after the run:

      dropdb --if-exists kanban_test_a_race
      MIX_TEST_PARTITION=_a_race MIX_ENV=test mix test --only device_token_race test/kanban/devices/token_race_test.exs
      dropdb kanban_test_a_race

  `setup_all` refuses any database whose name does not end in `_race`.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts
  alias Kanban.AccountsFixtures
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.DevicesFixtures
  alias Kanban.Repo

  @moduletag :device_token_race
  @moduletag timeout: 300_000

  @deadline_ms 10_000
  @random_rounds 25

  setup_all do
    database = Repo.config()[:database]

    unless String.ends_with?(database, "_race") do
      raise """
      #{inspect(__MODULE__)} commits its rows, so it runs only in a throwaway \
      database whose name ends in _race, not #{database}:

          dropdb --if-exists kanban_test_a_race
          MIX_TEST_PARTITION=_a_race MIX_ENV=test mix test --only device_token_race #{Path.relative_to_cwd(__ENV__.file)}
          dropdb kanban_test_a_race
      """
    end

    :ok
  end

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    %{scope: AccountsFixtures.user_scope_fixture()}
  end

  describe "a revocation against a rotation of the device's refresh token" do
    for {first, second} <- [rotation: :revoke, revoke: :rotation] do
      test "the #{first} first, then the #{second}", %{scope: scope} do
        {device, issued} = DevicesFixtures.device_with_tokens_fixture(scope)

        results =
          forced_race(device.id, racers(unquote(first), unquote(second), scope, device, issued))

        assert_revoked_and_dead(device, results)
        assert_order(unquote(first), results)
      end
    end

    test "at random, #{@random_rounds} rounds", %{scope: scope} do
      for _round <- 1..@random_rounds do
        {device, issued} = DevicesFixtures.device_with_tokens_fixture(scope)

        results =
          [
            rotation: fn -> Devices.rotate_refresh_token(issued.refresh_token) end,
            revoke: fn -> Devices.revoke_device(scope, device) end
          ]
          |> Enum.map(fn {name, fun} -> {name, start_racer(fun)} end)
          |> await_racers()

        assert_revoked_and_dead(device, results)
      end
    end
  end

  describe "a sign-out with the refresh token against its rotation" do
    for {first, second} <- [rotation: :sign_out, sign_out: :rotation] do
      test "the #{first} first, then the #{second}", %{scope: scope} do
        {device, issued} = DevicesFixtures.device_with_tokens_fixture(scope)

        results =
          forced_race(device.id, racers(unquote(first), unquote(second), scope, device, issued))

        assert_revoked_and_dead(device, results)
        assert_order(unquote(first), results)
      end
    end
  end

  describe "a replayed authorization code against its first exchange" do
    for replay_client <- ["stride-ios", "stride-android"] do
      test "replayed by #{replay_client} while the first exchange holds the code", %{
        scope: scope
      } do
        code = DevicesFixtures.authorization_code_fixture(scope)
        first = grant(code)
        replay = %{first | client_id: unquote(replay_client)}

        holder = hold_rows("oauth_authorization_codes", [code.id])
        exchange = start_racer(fn -> Devices.exchange_authorization_code(first, details()) end)
        await_lock_waiters(1)
        replayed = start_racer(fn -> Devices.exchange_authorization_code(replay, details()) end)
        await_lock_waiters(2)
        release(holder)

        assert {:ok, issued} = Task.await(exchange, @deadline_ms)
        assert Task.await(replayed, @deadline_ms) == {:error, :invalid_grant}

        assert_revoked_and_dead(issued.device, rotation: {:ok, issued})
      end
    end
  end

  describe "an authorization code exchange against a password change of its user (D459)" do
    for change <- [:update_user_password, :reset_user_password] do
      test "#{change}, the exchange first: the device it signs in is revoked by the change",
           %{scope: scope} do
        code = DevicesFixtures.authorization_code_fixture(scope)

        holder = hold_rows("oauth_authorization_codes", [code.id])

        exchange =
          start_racer(fn -> code |> grant() |> Devices.exchange_authorization_code(details()) end)

        await_lock_waiters(1)
        change = start_racer(fn -> change_password(unquote(change), scope) end)
        await_lock_waiters(2)
        release(holder)

        assert {:ok, issued} = Task.await(exchange, @deadline_ms)
        assert {:ok, {_user, _tokens}} = Task.await(change, @deadline_ms)

        assert_revoked_and_dead(issued.device, rotation: {:ok, issued})
      end

      test "#{change}, the change first: the code is refused and signs no device in",
           %{scope: scope} do
        code = DevicesFixtures.authorization_code_fixture(scope)

        holder = hold_rows("oauth_authorization_codes", [code.id])
        change = start_racer(fn -> change_password(unquote(change), scope) end)
        await_lock_waiters(1)

        exchange =
          start_racer(fn -> code |> grant() |> Devices.exchange_authorization_code(details()) end)

        await_lock_waiters(2)
        release(holder)

        assert {:ok, {_user, _tokens}} = Task.await(change, @deadline_ms)
        assert Task.await(exchange, @deadline_ms) == {:error, :invalid_grant}
        refute Repo.get_by(Device, user_id: scope.user.id)
      end
    end
  end

  describe "issuing an authorization code against a password change of its user (D459)" do
    for change <- [:update_user_password, :reset_user_password] do
      test "#{change}, the change first: no code is issued for the old password",
           %{scope: scope} do
        holder = hold_rows("users", [scope.user.id])
        change = start_racer(fn -> change_password(unquote(change), scope) end)
        await_lock_waiters(1)
        issue = start_racer(fn -> issue_code(scope) end)
        await_lock_waiters(2)
        release(holder)

        assert {:ok, {_user, _tokens}} = Task.await(change, @deadline_ms)
        assert {:error, %Ecto.Changeset{}} = Task.await(issue, @deadline_ms)
        refute Repo.get_by(Kanban.Devices.AuthorizationCode, user_id: scope.user.id)
      end

      test "#{change}, the code first: the change expires it", %{scope: scope} do
        holder = hold_rows("users", [scope.user.id])
        issue = start_racer(fn -> issue_code(scope) end)
        await_lock_waiters(1)
        change = start_racer(fn -> change_password(unquote(change), scope) end)
        await_lock_waiters(2)
        release(holder)

        assert {:ok, code} = Task.await(issue, @deadline_ms)
        assert {:ok, {_user, _tokens}} = Task.await(change, @deadline_ms)

        assert code |> grant() |> Devices.exchange_authorization_code(details()) ==
                 {:error, :invalid_grant}
      end
    end
  end

  describe "push tokens moving between a person's devices" do
    test "two devices trading their tokens both get the other's", %{scope: scope} do
      for order <- [:first_then_second, :second_then_first] do
        {a, b} = {push_device(scope), push_device(scope)}
        [first, second] = if order == :first_then_second, do: [a, b], else: [b, a]

        holder = hold_rows("user_devices", [a.id, b.id])
        first_update = start_racer(fn -> update_push(scope, first, other(first, a, b)) end)
        await_lock_waiters(1)
        second_update = start_racer(fn -> update_push(scope, second, other(second, a, b)) end)
        await_lock_waiters(2)
        release(holder)

        assert {:ok, %Device{}} = Task.await(first_update, @deadline_ms)
        assert {:ok, %Device{}} = Task.await(second_update, @deadline_ms)

        assert Repo.get!(Device, a.id).push_token == b.push_token
        assert Repo.get!(Device, b.id).push_token == a.push_token
      end
    end

    test "two devices registering one fresh token: the last one holds it", %{scope: scope} do
      for order <- [:first_then_second, :second_then_first] do
        a = DevicesFixtures.device_fixture(scope)
        b = DevicesFixtures.device_fixture(scope)
        [first, second] = if order == :first_then_second, do: [a, b], else: [b, a]
        token = "race-push-#{System.unique_integer([:positive])}"

        holder = hold_rows("user_devices", [a.id, b.id])
        first_update = start_racer(fn -> Devices.update_current(scope, first, push(token)) end)
        await_lock_waiters(1)
        second_update = start_racer(fn -> Devices.update_current(scope, second, push(token)) end)
        await_lock_waiters(2)
        release(holder)

        assert {:ok, %Device{push_token: ^token}} = Task.await(first_update, @deadline_ms)
        assert {:ok, %Device{push_token: ^token}} = Task.await(second_update, @deadline_ms)

        assert Repo.get!(Device, first.id).push_token == nil
        assert Repo.get!(Device, second.id).push_token == token
        assert from(d in Device, where: d.push_token == ^token) |> Repo.aggregate(:count) == 1
      end
    end

    test "at random, a trade and a fresh registration never leave a token on two devices",
         %{scope: scope} do
      for _round <- 1..@random_rounds do
        {a, b} = {push_device(scope), push_device(scope)}
        c = DevicesFixtures.device_fixture(scope)

        [
          fn -> update_push(scope, a, b) end,
          fn -> update_push(scope, b, a) end,
          fn -> update_push(scope, c, a) end
        ]
        |> Enum.map(&start_racer/1)
        |> Enum.map(&Task.await(&1, @deadline_ms))
        |> Enum.each(&assert({:ok, %Device{}} = &1))

        tokens =
          from(d in Device, where: d.id in ^[a.id, b.id, c.id], select: d.push_token)
          |> Repo.all()
          |> Enum.reject(&is_nil/1)

        assert tokens == Enum.uniq(tokens)
      end
    end
  end

  # The two racers of a revocation race, by name, in the order they queue.
  # The rotation reads its clock two seconds before the revocation, as one
  # that waited on the device lock that long would: the tokens a revocation
  # expires then still look unexpired to it, so only the revoked device can
  # refuse it.
  defp racers(first, second, scope, device, issued) do
    early = DateTime.add(DateTime.utc_now(), -2, :second)

    funs = %{
      rotation: fn -> Devices.rotate_refresh_token(issued.refresh_token, early) end,
      revoke: fn -> Devices.revoke_device(scope, device) end,
      sign_out: fn -> Devices.revoke_by_refresh_token(issued.refresh_token) end
    }

    [{first, funs[first]}, {second, funs[second]}]
  end

  # Holds the device row, queues the racers on it one at a time, then
  # releases it, so they run in the order given.
  defp forced_race(device_id, racers) do
    holder = hold_rows("user_devices", [device_id])

    tasks =
      racers
      |> Enum.with_index(1)
      |> Enum.map(fn {{name, fun}, waiting} ->
        task = start_racer(fun)
        await_lock_waiters(waiting)
        {name, task}
      end)

    release(holder)
    await_racers(tasks)
  end

  defp await_racers(tasks),
    do: Enum.map(tasks, fn {name, task} -> {name, Task.await(task, @deadline_ms)} end)

  defp assert_order(:rotation, results) do
    assert {:ok, %{refresh_token: _}} = results[:rotation]
    assert {:ok, %Device{}} = results[:revoke] || results[:sign_out]
  end

  defp assert_order(_revocation, results) do
    assert {:ok, %Device{}} = results[:revoke] || results[:sign_out]
    assert results[:rotation] == {:error, :invalid_token}
  end

  # The device is revoked, no token of it is live, and whatever pair a
  # rotation returned no longer works.
  defp assert_revoked_and_dead(device, results) do
    assert %DateTime{} = Repo.get!(Device, device.id).revoked_at

    now = DateTime.utc_now(:second)

    assert from(t in DeviceToken, where: t.device_id == ^device.id and t.expires_at > ^now)
           |> Repo.all() == []

    case results[:rotation] do
      {:ok, issued} ->
        assert Devices.fetch_by_access_token(issued.access_token) == {:error, :invalid_token}
        assert Devices.rotate_refresh_token(issued.refresh_token) == {:error, :invalid_token}

      refused ->
        assert refused in [nil, {:error, :invalid_token}]
    end
  end

  defp grant(code) do
    %{
      code: code.code,
      client_id: code.client_id,
      redirect_uri: code.redirect_uri,
      code_verifier: DevicesFixtures.valid_code_verifier()
    }
  end

  defp details do
    %{
      platform: :ios,
      device_class: :phone,
      approval_public_key: DevicesFixtures.valid_approval_public_key()
    }
  end

  defp change_password(change, scope),
    do: apply(Accounts, change, [scope.user, %{password: "a new race password"}])

  defp issue_code(scope),
    do:
      Devices.create_authorization_code(
        scope,
        DevicesFixtures.valid_authorization_code_attributes()
      )

  defp push(token), do: %{"push_token" => token}

  defp push_device(scope) do
    device = DevicesFixtures.device_fixture(scope)
    token = "race-push-#{System.unique_integer([:positive])}"
    {:ok, device} = Devices.update_current(scope, device, push(token))
    device
  end

  defp other(device, a, b), do: if(device.id == a.id, do: b, else: a)

  # `device` registers the push token `holder` held when the round began.
  defp update_push(scope, device, holder),
    do: Devices.update_current(scope, device, push(holder.push_token))

  # A racer on its own committing connection, with a lock timeout so a
  # deadlock or a lost wake-up fails the test rather than hanging it.
  defp start_racer(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Repo.checkout(fn ->
        Repo.query!("SET lock_timeout = '5s'")
        result = fun.()
        Repo.query!("RESET lock_timeout")
        result
      end)
    end)
  end

  # A third session that locks rows of `table` FOR UPDATE until released.
  defp hold_rows(table, ids) do
    test_pid = self()
    conn = second_session()

    holder =
      Task.async(fn ->
        Postgrex.transaction(conn, fn c ->
          Postgrex.query!(c, "SET LOCAL lock_timeout = '5s'", [])
          Postgrex.query!(c, "SELECT id FROM #{table} WHERE id = ANY($1) FOR UPDATE", [ids])
          send(test_pid, :holding)
          receive do: (:proceed -> :released)
        end)
      end)

    assert_receive :holding, 5_000
    await_lock_waiters(0)
    holder
  end

  defp release(holder) do
    send(holder.pid, :proceed)
    assert {:ok, :released} = Task.await(holder, @deadline_ms)
  end

  defp await_lock_waiters(expected, waited \\ 0) do
    count = lock_waiters()

    cond do
      count == expected ->
        :ok

      waited >= @deadline_ms ->
        flunk("expected #{expected} sessions waiting on a lock, saw #{count}")

      true ->
        Process.sleep(10)
        await_lock_waiters(expected, waited + 10)
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

  # A raw connection outside the pool: another Postgres session whose row
  # locks really contend with the racers'. Linked to the test process.
  defp second_session do
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
    {:ok, conn} = Postgrex.start_link(config)
    conn
  end
end
