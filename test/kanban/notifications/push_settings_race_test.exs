defmodule Kanban.Notifications.PushSettingsRaceTest do
  @moduledoc """
  Proves that two push settings changes for one person at once both persist,
  with real, committing connections (W2767).

  The sandboxed tests cannot show it: every process there shares one
  connection, so two changes never overlap. Here the test holds the person's
  `user_push_settings` row lock, starts two changes on their own connections,
  waits until both are blocked, and then lets them go. Each change locks the
  row before it reads the current settings and writes only the columns it
  changes, so neither loses the other's field. Without both, the change that
  writes last puts back the value the first one replaced.

  ## Running

  These tests carry `@moduletag :push_settings_race`, which
  `test/test_helper.exs` excludes, so the normal suite never runs them. Their
  rows commit, so they run only in a throwaway database, dropped before and
  after the run:

      dropdb --if-exists kanban_test_race
      MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only push_settings_race test/kanban/notifications/push_settings_race_test.exs
      dropdb kanban_test_race

  `setup_all` refuses any database whose name does not end in `_race`.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.Scope
  alias Kanban.Notifications
  alias Kanban.Notifications.PushSettings
  alias Kanban.Repo

  @moduletag :push_settings_race
  @moduletag timeout: 120_000

  @deadline_ms 30_000

  setup_all do
    database = Repo.config()[:database]

    unless String.ends_with?(database, "_race") do
      raise """
      #{inspect(__MODULE__)} commits its rows, so it runs only in the throwaway \
      kanban_test_race database, not #{database}:

          dropdb --if-exists kanban_test_race
          MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only push_settings_race #{Path.relative_to_cwd(__ENV__.file)}
          dropdb kanban_test_race
      """
    end

    :ok
  end

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    scope = Scope.for_user(user_fixture())
    {:ok, _view} = change(scope, %{"time_zone" => "Europe/London"})

    %{scope: scope}
  end

  test "two changes at once both persist without losing a field", %{scope: scope} do
    user_id = scope.user.id

    {:ok, racers} =
      Repo.transaction(fn ->
        Repo.one!(from(s in PushSettings, where: s.user_id == ^user_id, lock: "FOR UPDATE"))

        racers = [
          Elixir.Task.async(fn -> race(scope, %{"quiet_hours_enabled" => true}) end),
          Elixir.Task.async(fn ->
            race(scope, %{"switches" => %{"mentioned" => true}, "time_zone" => "Asia/Tokyo"})
          end)
        ]

        await_blocked_on_lock(2)
        racers
      end)

    assert [{:ok, _}, {:ok, _}] = Enum.map(racers, &Elixir.Task.await(&1, @deadline_ms))

    assert %{
             quiet_hours_enabled: true,
             time_zone: "Asia/Tokyo",
             switches: %{mentioned: true, review_requested: true}
           } = Notifications.get_push_settings(scope)
  end

  defp change(scope, attrs),
    do: Notifications.update_push_settings(scope, attrs, via: :ios, feature: :mobile_app)

  defp race(scope, attrs) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    change(scope, attrs)
  end

  # Polls until `count` other backends of this database wait on a lock, so
  # both changes are past whatever they read before they block.
  defp await_blocked_on_lock(count, waited \\ 0) do
    blocked =
      from(a in fragment("pg_stat_activity"),
        where:
          a.datname == fragment("current_database()") and a.wait_event_type == "Lock" and
            a.pid != fragment("pg_backend_pid()"),
        select: count()
      )
      |> Repo.one!()

    cond do
      blocked >= count ->
        :ok

      waited >= @deadline_ms ->
        flunk("only #{blocked} of #{count} changes blocked on the settings row lock")

      true ->
        Process.sleep(20)
        await_blocked_on_lock(count, waited + 20)
    end
  end
end
