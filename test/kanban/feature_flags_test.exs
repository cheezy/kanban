defmodule Kanban.FeatureFlagsTest do
  # Async is safe: config/test.exs turns the fun_with_flags cache off, so every
  # read and write goes through this test's own sandbox connection.
  use Kanban.DataCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.FeatureFlags

  @flag :mobile_app_preview

  defp stored_gates do
    query =
      from t in "fun_with_flags_toggles",
        where: t.flag_name == "mobile_app_preview",
        order_by: [t.gate_type, t.target],
        select: {t.gate_type, t.target, t.enabled}

    Repo.all(query)
  end

  defp on_for?(user), do: user |> Scope.for_user() |> FeatureFlags.enabled?(@flag)

  test "flags/0 registers :mobile_app_preview, and it is off by default" do
    assert FeatureFlags.flags() == [:mobile_app_preview]
    assert FeatureFlags.state(@flag) == :off
    refute FeatureFlags.enabled?(nil, @flag)
  end

  test "enabled?/2 is false for a user when the flag has no gates" do
    scope = user_scope_fixture()

    refute FeatureFlags.enabled?(scope, @flag)
    assert stored_gates() == []
  end

  test "enable_for_user/2 turns the flag on for that user only" do
    user = user_fixture()
    other = user_fixture()

    assert FeatureFlags.enable_for_user(@flag, user) == :ok

    assert on_for?(user)
    refute on_for?(other)
    refute FeatureFlags.enabled?(nil, @flag)
  end

  test "enable_for_everyone/1 turns the flag on for every user and for a nil scope" do
    user = user_fixture()
    other = user_fixture()

    assert FeatureFlags.enable_for_everyone(@flag) == :ok

    assert on_for?(user)
    assert on_for?(other)
    assert FeatureFlags.enabled?(nil, @flag)
    assert FeatureFlags.enabled?(%Scope{user: nil}, @flag)
  end

  test "disable_for_user/2 removes only that user's gate" do
    user = user_fixture()
    other = user_fixture()
    :ok = FeatureFlags.enable_for_user(@flag, user)
    :ok = FeatureFlags.enable_for_user(@flag, other)

    assert FeatureFlags.disable_for_user(@flag, user) == :ok

    refute on_for?(user)
    assert on_for?(other)

    # The gate is removed, not stored as "forced off": only the other user's
    # row remains, so the everyone gate reaches this user again.
    assert stored_gates() == [{"actor", "user:#{other.id}", true}]
    :ok = FeatureFlags.enable_for_everyone(@flag)
    assert on_for?(user)
  end

  test "disable_for_everyone/1 turns off the everyone gate and keeps user gates" do
    user = user_fixture()
    other = user_fixture()
    :ok = FeatureFlags.enable_for_user(@flag, user)
    :ok = FeatureFlags.enable_for_everyone(@flag)

    assert FeatureFlags.disable_for_everyone(@flag) == :ok

    assert on_for?(user)
    refute on_for?(other)
    refute FeatureFlags.enabled?(nil, @flag)
  end

  test "an unknown flag name raises ArgumentError" do
    user = user_fixture()
    scope = Scope.for_user(user)

    # :mobile_app is the plan feature of the same stem, not a flag.
    for flag <- [:nope, :mobile_app] do
      calls = [
        fn -> FeatureFlags.enabled?(scope, flag) end,
        fn -> FeatureFlags.enabled?(nil, flag) end,
        fn -> FeatureFlags.enabled?(%Scope{user: nil}, flag) end,
        fn -> FeatureFlags.enable_for_user(flag, user) end,
        fn -> FeatureFlags.disable_for_user(flag, user) end,
        fn -> FeatureFlags.enable_for_everyone(flag) end,
        fn -> FeatureFlags.disable_for_everyone(flag) end,
        fn -> FeatureFlags.state(flag) end
      ]

      for call <- calls do
        error = assert_raise ArgumentError, call
        assert error.message =~ "unknown feature flag #{inspect(flag)}"
        assert error.message =~ ":mobile_app_preview"
      end
    end

    # A value that may have come from a request is described, never echoed.
    for {flag, description} <- [{"mobile_app_preview", "(a string)"}, {42, "(a non-atom value)"}] do
      error = assert_raise ArgumentError, fn -> FeatureFlags.state(flag) end
      assert error.message =~ description
      refute error.message =~ "\"mobile_app_preview\""
    end

    # Nothing was written for an unknown flag.
    assert Repo.aggregate("fun_with_flags_toggles", :count) == 0
  end

  test "a nil scope sees only the everyone gate" do
    user = user_fixture()
    :ok = FeatureFlags.enable_for_user(@flag, user)

    refute FeatureFlags.enabled?(nil, @flag)
    refute FeatureFlags.enabled?(%Scope{user: nil}, @flag)

    :ok = FeatureFlags.enable_for_everyone(@flag)

    assert FeatureFlags.enabled?(nil, @flag)
    assert FeatureFlags.enabled?(%Scope{user: nil}, @flag)
  end

  test "the FunWithFlags.Actor id for a user is user:<id>" do
    user = user_fixture()

    assert FunWithFlags.Actor.id(user) == "user:#{user.id}"
    refute FunWithFlags.Actor.id(user) =~ user.email

    :ok = FeatureFlags.enable_for_user(@flag, user)
    assert stored_gates() == [{"actor", "user:#{user.id}", true}]
  end

  test "state/1 reports off, users (with ids) or everyone" do
    first = user_fixture()
    second = user_fixture()
    assert FeatureFlags.state(@flag) == :off

    :ok = FeatureFlags.enable_for_user(@flag, second)
    :ok = FeatureFlags.enable_for_user(@flag, first)
    assert FeatureFlags.state(@flag) == {:users, Enum.sort([first.id, second.id])}

    # Everyone wins while user gates still exist.
    :ok = FeatureFlags.enable_for_everyone(@flag)
    assert FeatureFlags.state(@flag) == :everyone

    :ok = FeatureFlags.disable_for_everyone(@flag)
    assert FeatureFlags.state(@flag) == {:users, Enum.sort([first.id, second.id])}

    :ok = FeatureFlags.disable_for_user(@flag, first)
    :ok = FeatureFlags.disable_for_user(@flag, second)
    assert FeatureFlags.state(@flag) == :off
  end

  test "state/1 ignores a user gate stored as off or with a target that is not a user id" do
    user = user_fixture()

    Repo.insert_all("fun_with_flags_toggles", [
      %{
        flag_name: "mobile_app_preview",
        gate_type: "actor",
        target: "user:#{user.id}",
        enabled: false
      },
      %{flag_name: "mobile_app_preview", gate_type: "actor", target: "user:abc", enabled: true},
      %{flag_name: "mobile_app_preview", gate_type: "actor", target: "team:7", enabled: true}
    ])

    assert FeatureFlags.state(@flag) == :off
  end

  test "state/1 still reports the id of a deleted user whose gate remains" do
    user = user_fixture()
    :ok = FeatureFlags.enable_for_user(@flag, user)

    Repo.delete!(user)

    assert FeatureFlags.state(@flag) == {:users, [user.id]}
  end

  test "enable_for_user/2 and disable_for_user/2 refuse a user with no id" do
    # With a nil actor FunWithFlags would act on the whole flag; the wrapper
    # must never pass one through.
    user = user_fixture()
    :ok = FeatureFlags.enable_for_user(@flag, user)

    for bad <- [nil, %Kanban.Accounts.User{}] do
      assert_raise FunctionClauseError, fn -> FeatureFlags.enable_for_user(@flag, bad) end
      assert_raise FunctionClauseError, fn -> FeatureFlags.disable_for_user(@flag, bad) end
    end

    assert FeatureFlags.state(@flag) == {:users, [user.id]}
  end

  test "a toggle written through the Ecto store is read back after the cache is busted" do
    # The setup every node runs: Ecto persistence through Kanban.Repo, and
    # cache-bust notifications over Kanban.PubSub.
    assert Application.get_env(:fun_with_flags, :persistence) == [
             adapter: FunWithFlags.Store.Persistent.Ecto,
             repo: Kanban.Repo
           ]

    assert Application.get_env(:fun_with_flags, :cache_bust_notifications) == [
             enabled: true,
             adapter: FunWithFlags.Notifications.PhoenixPubSub,
             client: Kanban.PubSub
           ]

    # In tests there is no cache, so every read below is a fresh read of the
    # table: the state a node sees once its cached copy has been busted.
    assert FunWithFlags.compiled_store() == FunWithFlags.SimpleStore

    user = user_fixture()
    :ok = FeatureFlags.enable_for_user(@flag, user)
    assert stored_gates() == [{"actor", "user:#{user.id}", true}]

    # Another node changes the stored toggles; this one reads the new state.
    Repo.insert_all("fun_with_flags_toggles", [
      %{flag_name: "mobile_app_preview", gate_type: "boolean", target: "_fwf_none", enabled: true}
    ])

    assert FeatureFlags.enabled?(nil, @flag)
    assert FeatureFlags.state(@flag) == :everyone
  end

  test "the kanban release loads fun_with_flags, which does not start on its own" do
    config = Mix.Project.config()

    assert get_in(config, [:releases, :kanban, :applications, :fun_with_flags]) == :load

    assert {:fun_with_flags, "~> 1.13", opts} = List.keyfind(config[:deps], :fun_with_flags, 0)
    assert opts[:runtime] == false
  end

  test "FunWithFlags.Supervisor starts after Kanban.PubSub" do
    source = File.read!("lib/kanban/application.ex")
    {pubsub, _} = :binary.match(source, "{Phoenix.PubSub, name: Kanban.PubSub}")
    {flags, _} = :binary.match(source, "FunWithFlags.Supervisor,")

    assert pubsub < flags
  end

  test "only Kanban.FeatureFlags calls FunWithFlags" do
    callers =
      for path <- Path.wildcard("lib/**/*.{ex,exs,heex}"),
          path != "lib/kanban/feature_flags.ex",
          not String.starts_with?(path, "lib/kanban/feature_flags/"),
          File.read!(path) =~ "FunWithFlags",
          do: path

    assert callers == ["lib/kanban/application.ex"]

    # Kanban.Application only starts the supervisor.
    mentions =
      ~r/FunWithFlags(?:\.\w+)*/
      |> Regex.scan(File.read!("lib/kanban/application.ex"))
      |> List.flatten()
      |> Enum.uniq()

    assert mentions == ["FunWithFlags.Supervisor"]
  end

  test "nothing attaches to the library's telemetry, whose metadata names the user gate" do
    # A prefix match: every [:fun_with_flags, ...] event, current and future.
    assert :telemetry.list_handlers([:fun_with_flags]) == []
  end

  test "the library's debug log line, which quotes the user gate, is silenced at boot" do
    assert Logger.get_module_level(FunWithFlags.Telemetry) == [{FunWithFlags.Telemetry, :info}]

    # Idempotent, so a second call (another boot path, a test) changes nothing.
    assert FeatureFlags.quiet_library_log() == :ok
    assert Logger.get_module_level(FunWithFlags.Telemetry) == [{FunWithFlags.Telemetry, :info}]
  end
end
