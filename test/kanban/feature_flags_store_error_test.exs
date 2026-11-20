defmodule Kanban.FeatureFlagsStoreErrorTest do
  # Not async: it swaps the fun_with_flags persistence adapter, which is
  # global application config, for a store that fails every write.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.FeatureFlags

  defmodule FailingStore do
    @moduledoc false
    # Every write fails with an error that quotes the user gate, as a real
    # store error (an Ecto changeset, say) could.
    def put(_flag_name, gate), do: {:error, {:write_failed, gate}}
    def delete(_flag_name, gate), do: {:error, {:delete_failed, gate}}
    # Reads succeed and find no stored flag, so only the write fails.
    def all_flag_names, do: {:ok, []}
  end

  setup do
    original = Application.get_env(:fun_with_flags, :persistence)

    Application.put_env(
      :fun_with_flags,
      :persistence,
      Keyword.put(original, :adapter, FailingStore)
    )

    on_exit(fn -> Application.put_env(:fun_with_flags, :persistence, original) end)
  end

  test "a failed write returns {:error, :store_failed}, never the store's error" do
    user = %User{id: 4242}

    results = [
      FeatureFlags.enable_for_user(:mobile_app_preview, user),
      FeatureFlags.disable_for_user(:mobile_app_preview, user),
      FeatureFlags.enable_for_everyone(:mobile_app_preview),
      FeatureFlags.disable_for_everyone(:mobile_app_preview)
    ]

    assert results == List.duplicate({:error, :store_failed}, 4)
    refute inspect(results) =~ "4242"
  end

  test "an audited write whose store write fails records and broadcasts nothing" do
    admin = Scope.for_user(admin_fixture())
    user = user_fixture()
    :ok = FeatureFlags.subscribe()

    assert {:error, :store_failed} =
             FeatureFlags.turn_on_for_email(admin, :mobile_app_preview, user.email)

    assert {:error, :store_failed} = FeatureFlags.turn_on_for_everyone(admin, :mobile_app_preview)

    assert AuditLog.list_events(action: "feature_flag_enabled") == []
    refute_receive {:feature_flag_changed, _}
  end

  defmodule UnreadableStore do
    @moduledoc false
    # Every read fails, as a store that is down would.
    def all_flag_names, do: {:error, :store_down}
  end

  test "an audited write whose store cannot be read returns {:error, :store_failed}" do
    Application.put_env(
      :fun_with_flags,
      :persistence,
      Keyword.put(Application.get_env(:fun_with_flags, :persistence), :adapter, UnreadableStore)
    )

    admin = Scope.for_user(admin_fixture())
    user = user_fixture()
    :ok = FeatureFlags.subscribe()

    for result <- [
          FeatureFlags.turn_on_for_email(admin, :mobile_app_preview, user.email),
          FeatureFlags.turn_off_for_user_id(admin, :mobile_app_preview, user.id),
          FeatureFlags.turn_on_for_everyone(admin, :mobile_app_preview),
          FeatureFlags.turn_off_for_everyone(admin, :mobile_app_preview)
        ] do
      assert result == {:error, :store_failed}
    end

    assert AuditLog.list_events(action: "feature_flag_enabled") == []
    assert AuditLog.list_events(action: "feature_flag_disabled") == []
    refute_receive {:feature_flag_changed, _}
  end
end
