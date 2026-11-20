defmodule Kanban.FeatureFlagsStoreErrorTest do
  # Not async: it swaps the fun_with_flags persistence adapter, which is
  # global application config, for a store that fails every write.
  use ExUnit.Case, async: false

  alias Kanban.Accounts.User
  alias Kanban.FeatureFlags

  defmodule FailingStore do
    @moduledoc false
    # Every write fails with an error that quotes the user gate, as a real
    # store error (an Ecto changeset, say) could.
    def put(_flag_name, gate), do: {:error, {:write_failed, gate}}
    def delete(_flag_name, gate), do: {:error, {:delete_failed, gate}}
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
end
