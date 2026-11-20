defmodule Kanban.Notifications.PreferencesTest do
  @moduledoc """
  Direct tests of `Kanban.Notifications.Preferences`; `Kanban.Notifications`
  delegates its preference functions here.
  """
  # async: false - the plan tests switch the global :plans_enforced
  # application env on through Kanban.PlansHelpers.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.PlansHelpers

  alias Kanban.Accounts.Scope
  alias Kanban.Notifications.Preference
  alias Kanban.Notifications.Preferences
  alias Kanban.Notifications.PushSettings

  describe "event_types/0" do
    test "is every type the preference schema knows" do
      assert Preferences.event_types() == Preference.event_types()
      assert :comment_added in Preferences.event_types()
      assert :mentioned in Preferences.event_types()
    end
  end

  describe "normalize_event_type/1" do
    test "accepts a known type as an atom or a string" do
      assert Preferences.normalize_event_type(:task_assigned) == {:ok, :task_assigned}
      assert Preferences.normalize_event_type("task_assigned") == {:ok, :task_assigned}
    end

    test "returns :error for an unknown type or another term" do
      assert Preferences.normalize_event_type(:bogus) == :error
      assert Preferences.normalize_event_type("bogus") == :error
      assert Preferences.normalize_event_type(nil) == :error
      assert Preferences.normalize_event_type(42) == :error
    end
  end

  describe "default_preference/1" do
    test "in-app is on everywhere; email is off only for goals and comments" do
      for type <- Preferences.event_types() do
        default = Preferences.default_preference(type)

        assert %Preference{event_type: ^type, in_app: true, user_id: nil} = default
        assert default.email == type not in [:goal_completed, :comment_added]
        assert default.push == PushSettings.default_push?(type)
      end
    end

    test "accepts the string form" do
      assert %Preference{event_type: :goal_completed, email: false} =
               Preferences.default_preference("goal_completed")
    end

    test "raises for an unknown type" do
      assert_raise ArgumentError, ~r/unknown notification event type/, fn ->
        Preferences.default_preference(:bogus)
      end
    end
  end

  describe "get_preferences/1" do
    test "returns defaults stamped with the user, in event type order" do
      user = user_fixture()
      prefs = user |> Scope.for_user() |> Preferences.get_preferences()

      assert Enum.map(prefs, & &1.event_type) == Preferences.event_types()
      assert Enum.all?(prefs, &(&1.user_id == user.id and is_nil(&1.id)))
    end

    test "a saved row replaces the default for its type only" do
      user = user_fixture()
      scope = Scope.for_user(user)
      {:ok, saved} = Preferences.update_preference(scope, :task_assigned, %{email: false})

      prefs = scope |> Preferences.get_preferences() |> Map.new(&{&1.event_type, &1})

      assert prefs[:task_assigned].id == saved.id
      assert prefs[:task_assigned].email == false
      assert prefs[:review_requested].email == true
      assert is_nil(prefs[:review_requested].id)
    end
  end

  describe "update_preference/3" do
    test "an omitted flag keeps its current value" do
      scope = Scope.for_user(user_fixture())

      {:ok, first} = Preferences.update_preference(scope, "review_requested", %{in_app: false})
      assert {first.in_app, first.email} == {false, true}

      {:ok, second} = Preferences.update_preference(scope, :review_requested, %{email: false})
      assert second.id == first.id
      assert {second.in_app, second.email} == {false, false}
    end

    test "refuses an unknown event type" do
      scope = Scope.for_user(user_fixture())

      assert Preferences.update_preference(scope, :bogus, %{email: false}) ==
               {:error, :invalid_event_type}
    end

    test "refuses a user without paid access while plans are enforced" do
      enforce_plans()
      scope = Scope.for_user(user_fixture())

      assert Preferences.update_preference(scope, :task_assigned, %{email: false}) ==
               {:error, {:plan_required, :notifications}}

      assert Repo.aggregate(Preference, :count) == 0
    end
  end

  describe "unsubscribe/2" do
    test "turns email off, leaves in-app alone and is idempotent" do
      user = user_fixture()
      scope = Scope.for_user(user)
      {:ok, _} = Preferences.update_preference(scope, :mentioned, %{in_app: false})

      assert :ok = Preferences.unsubscribe(user.id, "mentioned")
      assert :ok = Preferences.unsubscribe(user.id, :mentioned)

      assert %Preference{in_app: false, email: false} =
               Repo.get_by!(Preference, user_id: user.id, event_type: :mentioned)
    end

    test "is never a paid action" do
      enforce_plans()
      user = user_fixture()

      assert :ok = Preferences.unsubscribe(user.id, :task_assigned)

      assert %Preference{email: false, in_app: true} =
               Repo.get_by!(Preference, user_id: user.id, event_type: :task_assigned)
    end

    test "returns :not_found for a missing user and refuses an unknown type" do
      user = user_fixture()

      assert Preferences.unsubscribe(-1, :task_assigned) == {:error, :not_found}
      assert Preferences.unsubscribe(user.id, "bogus") == {:error, :invalid_event_type}
    end
  end
end
