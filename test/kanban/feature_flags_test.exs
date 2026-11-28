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

  test "flags/0 registers :mobile_app_preview and :blog, and both are off by default" do
    assert FeatureFlags.flags() == [:mobile_app_preview, :blog]
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

  # The topic is global and these tests run async, so another test's broadcast
  # can arrive at any time: only receipt is asserted here, never absence.
  # Kanban.FeatureFlagsStoreErrorTest, which runs alone, asserts absence.
  describe "the audited admin writes" do
    setup do
      :ok = FeatureFlags.subscribe()
      %{admin: Scope.for_user(admin_fixture())}
    end

    defp events(action), do: Kanban.AuditLog.list_events(action: action)

    test "topic/0 is feature_flags" do
      assert FeatureFlags.topic() == "feature_flags"
    end

    test "turn_on_for_email/3 trims the address, ignores case, audits and broadcasts",
         %{admin: admin} do
      user = user_fixture()

      assert :ok = FeatureFlags.turn_on_for_email(admin, @flag, " #{String.upcase(user.email)} ")
      assert FeatureFlags.state(@flag) == {:users, [user.id]}
      assert_receive {:feature_flag_changed, :mobile_app_preview}

      assert [event] = events("feature_flag_enabled")
      assert event.actor_user_id == admin.user.id

      assert event.metadata == %{
               "user_id" => admin.user.id,
               "flag" => "mobile_app_preview",
               "target_user_id" => user.id,
               "scope" => "user"
             }
    end

    test "turn_on_for_email/3 refuses bad input with nothing written or sent", %{admin: admin} do
      disabled =
        user_fixture()
        |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second))
        |> Repo.update!()

      assert {:error, :invalid_email} = FeatureFlags.turn_on_for_email(admin, @flag, "  ")
      assert {:error, :invalid_email} = FeatureFlags.turn_on_for_email(admin, @flag, nil)

      assert {:error, :invalid_email} =
               FeatureFlags.turn_on_for_email(admin, @flag, String.duplicate("a", 161))

      assert {:error, :user_not_found} =
               FeatureFlags.turn_on_for_email(admin, @flag, "nobody@example.invalid")

      assert {:error, :user_disabled} =
               FeatureFlags.turn_on_for_email(admin, @flag, disabled.email)

      assert FeatureFlags.state(@flag) == :off
      assert events("feature_flag_enabled") == []
    end

    test "turn_on_for_email/3 counts the length cap in characters, as users.email does",
         %{admin: admin} do
      # 112 characters but 212 bytes: a stored address a byte cap would refuse.
      email = String.duplicate("é", 100) <> "@example.com"

      user =
        user_fixture()
        |> Ecto.Changeset.change(email: email)
        |> Repo.update!()

      assert :ok = FeatureFlags.turn_on_for_email(admin, @flag, email)
      assert on_for?(user)

      assert {:error, :invalid_email} =
               FeatureFlags.turn_on_for_email(admin, @flag, String.duplicate("é", 161))
    end

    test "turn_on_for_email/3 refuses a user who already has the gate", %{admin: admin} do
      user = user_fixture()
      :ok = FeatureFlags.enable_for_user(@flag, user)

      assert {:error, :already_enabled} = FeatureFlags.turn_on_for_email(admin, @flag, user.email)
      assert events("feature_flag_enabled") == []
    end

    test "every write refuses anyone but an enabled site admin, before any lookup" do
      user = user_fixture()
      :ok = FeatureFlags.enable_for_user(@flag, user)

      disabled_admin =
        admin_fixture()
        |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second))
        |> Repo.update!()

      for scope <- [
            nil,
            %Scope{user: nil},
            Scope.for_user(user),
            Scope.for_user(disabled_admin)
          ] do
        assert {:error, :unauthorized} =
                 FeatureFlags.turn_on_for_email(scope, @flag, "nobody@example.invalid")

        assert {:error, :unauthorized} = FeatureFlags.turn_off_for_user_id(scope, @flag, user.id)
        assert {:error, :unauthorized} = FeatureFlags.turn_on_for_everyone(scope, @flag)
        assert {:error, :unauthorized} = FeatureFlags.turn_off_for_everyone(scope, @flag)
      end

      assert FeatureFlags.state(@flag) == {:users, [user.id]}
      assert events("feature_flag_enabled") == []
      assert events("feature_flag_disabled") == []
    end

    test "turn_off_for_user_id/3 removes the gate, audits and broadcasts", %{admin: admin} do
      user = user_fixture()
      :ok = FeatureFlags.enable_for_user(@flag, user)

      assert :ok = FeatureFlags.turn_off_for_user_id(admin, @flag, user.id)
      assert FeatureFlags.state(@flag) == :off
      assert_receive {:feature_flag_changed, :mobile_app_preview}

      assert [%{metadata: %{"target_user_id" => target, "scope" => "user"}}] =
               events("feature_flag_disabled")

      assert target == user.id

      assert {:error, :not_enabled} = FeatureFlags.turn_off_for_user_id(admin, @flag, user.id)
      assert length(events("feature_flag_disabled")) == 1
    end

    test "turn_on_for_everyone/2 and turn_off_for_everyone/2 audit scope everyone",
         %{admin: admin} do
      user = user_fixture()
      :ok = FeatureFlags.enable_for_user(@flag, user)

      assert {:error, :not_enabled} = FeatureFlags.turn_off_for_everyone(admin, @flag)
      assert :ok = FeatureFlags.turn_on_for_everyone(admin, @flag)
      assert {:error, :already_enabled} = FeatureFlags.turn_on_for_everyone(admin, @flag)
      assert FeatureFlags.state(@flag) == :everyone
      assert_receive {:feature_flag_changed, :mobile_app_preview}

      assert :ok = FeatureFlags.turn_off_for_everyone(admin, @flag)
      assert FeatureFlags.state(@flag) == {:users, [user.id]}
      assert_receive {:feature_flag_changed, :mobile_app_preview}

      assert [%{metadata: on}] = events("feature_flag_enabled")
      assert [%{metadata: off}] = events("feature_flag_disabled")

      for metadata <- [on, off] do
        assert metadata == %{
                 "user_id" => admin.user.id,
                 "flag" => "mobile_app_preview",
                 "scope" => "everyone"
               }
      end
    end

    test "overview/1 lists users with a gate even while everyone is on, and deleted ids apart" do
      user = user_fixture()
      deleted = user_fixture()
      :ok = FeatureFlags.enable_for_user(@flag, user)
      :ok = FeatureFlags.enable_for_user(@flag, deleted)
      :ok = FeatureFlags.enable_for_everyone(@flag)
      Repo.delete!(deleted)

      assert %{flag: @flag, everyone?: true, users: [listed], missing_user_ids: [missing]} =
               FeatureFlags.overview(@flag)

      assert listed.id == user.id
      assert missing == deleted.id

      :ok = FeatureFlags.disable_for_everyone(@flag)
      assert %{everyone?: false} = FeatureFlags.overview(@flag)
    end

    test "overview/1 of a flag with no gates is empty" do
      assert FeatureFlags.overview(@flag) == %{
               flag: @flag,
               everyone?: false,
               users: [],
               missing_user_ids: []
             }
    end

    test "a gate whose id overflows a bigint is ignored" do
      Repo.insert_all("fun_with_flags_toggles", [
        %{
          flag_name: "mobile_app_preview",
          gate_type: "actor",
          target: "user:99999999999999999999",
          enabled: true
        }
      ])

      assert FeatureFlags.overview(@flag).missing_user_ids == []
      assert FeatureFlags.state(@flag) == :off
    end
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
