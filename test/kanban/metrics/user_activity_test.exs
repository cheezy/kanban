defmodule Kanban.Metrics.UserActivityTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures

  alias Kanban.Metrics.UserActivity
  alias Kanban.Repo

  # Mirrors the write shape in KanbanWeb.Telemetry.MetricsStorage. `user_id`
  # must be a numeric *string* — the aggregation excludes any row whose
  # metadata->>'user_id' is not entirely digits.
  defp event!(user, metric_name, opts \\ []) do
    recorded_at = Keyword.get(opts, :recorded_at, DateTime.utc_now())
    user_id = Keyword.get(opts, :user_id, to_string(user.id))

    Repo.insert_all("metrics_events", [
      %{
        metric_name: metric_name,
        measurement: 1.0,
        metadata: %{"user_id" => user_id},
        recorded_at: recorded_at,
        inserted_at: DateTime.utc_now()
      }
    ])
  end

  defp row_for(rows, user), do: Enum.find(rows, &(&1.user_id == user.id))

  describe "list_user_activity/1 aggregation" do
    test "total_actions counts only kanban.api.task_ events for the user" do
      user = user_fixture()
      event!(user, "kanban.api.task_claimed")
      event!(user, "kanban.api.task_completed")
      event!(user, "kanban.api.task_created")
      # Not a task event — must not be counted.
      event!(user, "kanban.api.board_created")

      assert row_for(UserActivity.list_user_activity(), user).total_actions == 3
    end

    test "per-type counts match the claimed/completed/created prefixes" do
      user = user_fixture()
      for _ <- 1..3, do: event!(user, "kanban.api.task_claimed")
      for _ <- 1..2, do: event!(user, "kanban.api.task_completed")
      event!(user, "kanban.api.task_created")

      row = row_for(UserActivity.list_user_activity(), user)

      assert row.tasks_claimed == 3
      assert row.tasks_completed == 2
      assert row.tasks_created == 1
      assert row.total_actions == 6
    end

    test "per-type counts match on prefix, not exact equality" do
      user = user_fixture()
      event!(user, "kanban.api.task_claimed.duration")
      event!(user, "kanban.api.task_completed.count")

      row = row_for(UserActivity.list_user_activity(), user)

      assert row.tasks_claimed == 1
      assert row.tasks_completed == 1
    end

    test "last_activity is the max recorded_at and rows carry exactly the seven keys" do
      user = user_fixture()
      now = DateTime.utc_now()
      newest = DateTime.add(now, -60, :second)

      event!(user, "kanban.api.task_claimed", recorded_at: DateTime.add(now, -3600, :second))
      event!(user, "kanban.api.task_created", recorded_at: DateTime.add(now, -1800, :second))
      event!(user, "kanban.api.task_completed", recorded_at: newest)

      row = row_for(UserActivity.list_user_activity(), user)

      assert row |> Map.keys() |> Enum.sort() == [
               :email,
               :last_activity,
               :tasks_claimed,
               :tasks_completed,
               :tasks_created,
               :total_actions,
               :user_id
             ]

      assert row.email == user.email

      # metrics_events has no Ecto schema, so Postgrex returns the timestamp
      # column as a NaiveDateTime rather than a cast DateTime.
      assert %NaiveDateTime{} = row.last_activity

      assert NaiveDateTime.truncate(row.last_activity, :second) ==
               newest |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)
    end

    test "a user with no task events is absent from the results" do
      active = user_fixture()
      idle = user_fixture()
      event!(active, "kanban.api.task_claimed")

      rows = UserActivity.list_user_activity()

      assert row_for(rows, active)
      refute row_for(rows, idle)
    end

    test "events with a non-numeric metadata user_id are excluded" do
      user = user_fixture()
      event!(user, "kanban.api.task_claimed")
      event!(user, "kanban.api.task_claimed", user_id: "not-a-number")
      event!(user, "kanban.api.task_claimed", user_id: "")
      event!(user, "kanban.api.task_claimed", user_id: "12abc")

      assert row_for(UserActivity.list_user_activity(), user).total_actions == 1
    end
  end

  describe "list_user_activity/1 search" do
    test "filters by a case-insensitive match on email" do
      alice = user_fixture(email: "alice@example.com")
      bob = user_fixture(email: "bob@example.com")
      event!(alice, "kanban.api.task_claimed")
      event!(bob, "kanban.api.task_claimed")

      rows = UserActivity.list_user_activity(search: "alice")
      assert [%{email: "alice@example.com"}] = rows

      rows = UserActivity.list_user_activity(search: "ALICE")
      assert [%{email: "alice@example.com"}] = rows
    end

    test "nil and empty search return every user" do
      alice = user_fixture(email: "alice@example.com")
      bob = user_fixture(email: "bob@example.com")
      event!(alice, "kanban.api.task_claimed")
      event!(bob, "kanban.api.task_claimed")

      assert length(UserActivity.list_user_activity(search: nil)) == 2
      assert length(UserActivity.list_user_activity(search: "")) == 2
    end

    test "an underscore in the search term is matched literally, not as a wildcard" do
      literal = user_fixture(email: "a_b@example.com")
      decoy = user_fixture(email: "axb@example.com")
      event!(literal, "kanban.api.task_claimed")
      event!(decoy, "kanban.api.task_claimed")

      assert [%{email: "a_b@example.com"}] = UserActivity.list_user_activity(search: "a_b")
    end

    test "a percent in the search term is matched literally, not as a wildcard" do
      literal = user_fixture(email: "a%b@example.com")
      decoy = user_fixture(email: "axb@example.com")
      event!(literal, "kanban.api.task_claimed")
      event!(decoy, "kanban.api.task_claimed")

      assert [%{email: "a%b@example.com"}] = UserActivity.list_user_activity(search: "a%b")
    end

    test "a backslash in the search term matches nothing rather than erroring" do
      user = user_fixture(email: "alice@example.com")
      event!(user, "kanban.api.task_claimed")

      assert UserActivity.list_user_activity(search: "a\\b") == []
    end
  end

  describe "list_user_activity/1 sorting" do
    # alice: 3 claimed; bob: 1 claimed + 2 completed + 1 created.
    defp sort_setup do
      alice = user_fixture(email: "alice@example.com")
      bob = user_fixture(email: "bob@example.com")

      for _ <- 1..3, do: event!(alice, "kanban.api.task_claimed")

      event!(bob, "kanban.api.task_claimed")
      for _ <- 1..2, do: event!(bob, "kanban.api.task_completed")
      event!(bob, "kanban.api.task_created")

      %{alice: alice, bob: bob}
    end

    defp emails(rows), do: Enum.map(rows, & &1.email)

    test "sorts by email in both directions" do
      sort_setup()

      assert emails(UserActivity.list_user_activity(sort_by: :email, sort_dir: :asc)) ==
               ["alice@example.com", "bob@example.com"]

      assert emails(UserActivity.list_user_activity(sort_by: :email, sort_dir: :desc)) ==
               ["bob@example.com", "alice@example.com"]
    end

    test "sorts by total_actions in both directions" do
      sort_setup()

      # alice has 3 actions, bob has 4.
      assert emails(UserActivity.list_user_activity(sort_by: :total_actions, sort_dir: :asc)) ==
               ["alice@example.com", "bob@example.com"]

      assert emails(UserActivity.list_user_activity(sort_by: :total_actions, sort_dir: :desc)) ==
               ["bob@example.com", "alice@example.com"]
    end

    test "sorts by tasks_claimed in both directions" do
      sort_setup()

      assert emails(UserActivity.list_user_activity(sort_by: :tasks_claimed, sort_dir: :asc)) ==
               ["bob@example.com", "alice@example.com"]

      assert emails(UserActivity.list_user_activity(sort_by: :tasks_claimed, sort_dir: :desc)) ==
               ["alice@example.com", "bob@example.com"]
    end

    test "sorts by tasks_completed in both directions" do
      sort_setup()

      assert emails(UserActivity.list_user_activity(sort_by: :tasks_completed, sort_dir: :asc)) ==
               ["alice@example.com", "bob@example.com"]

      assert emails(UserActivity.list_user_activity(sort_by: :tasks_completed, sort_dir: :desc)) ==
               ["bob@example.com", "alice@example.com"]
    end

    test "sorts by tasks_created in both directions" do
      sort_setup()

      assert emails(UserActivity.list_user_activity(sort_by: :tasks_created, sort_dir: :asc)) ==
               ["alice@example.com", "bob@example.com"]

      assert emails(UserActivity.list_user_activity(sort_by: :tasks_created, sort_dir: :desc)) ==
               ["bob@example.com", "alice@example.com"]
    end

    test "an unknown sort field falls back to total_actions descending" do
      sort_setup()

      assert emails(UserActivity.list_user_activity(sort_by: :bogus, sort_dir: :asc)) ==
               ["bob@example.com", "alice@example.com"]

      assert emails(UserActivity.list_user_activity()) ==
               ["bob@example.com", "alice@example.com"]
    end
  end

  describe "list_user_activity/1 limit" do
    test "limit bounds the rows returned while the count reports the full total" do
      for i <- 1..3 do
        user = user_fixture(email: "user#{i}@example.com")
        event!(user, "kanban.api.task_claimed")
      end

      assert length(UserActivity.list_user_activity(limit: 2)) == 2
      assert length(UserActivity.list_user_activity()) == 3
      assert UserActivity.count_user_activity(limit: 2) == 3
    end
  end

  describe "count_user_activity/1" do
    test "returns zero when there are no events" do
      assert UserActivity.count_user_activity() == 0
    end

    test "counts distinct matching users and honors search" do
      alice = user_fixture(email: "alice@example.com")
      bob = user_fixture(email: "bob@example.com")
      for _ <- 1..3, do: event!(alice, "kanban.api.task_claimed")
      event!(bob, "kanban.api.task_claimed")

      assert UserActivity.count_user_activity() == 2
      assert UserActivity.count_user_activity(search: "alice") == 1
      assert UserActivity.count_user_activity(search: "nobody") == 0
    end
  end

  describe "escape_like/1" do
    test "escapes the three LIKE metacharacters" do
      assert UserActivity.escape_like("50% off") == "50\\% off"
      assert UserActivity.escape_like("foo_bar") == "foo\\_bar"
      assert UserActivity.escape_like("a\\b") == "a\\\\b"
    end

    test "passes plain strings through unchanged" do
      assert UserActivity.escape_like("alice@example.com") == "alice@example.com"
      assert UserActivity.escape_like("") == ""
    end

    test "escapes every occurrence, not just the first" do
      assert UserActivity.escape_like("a%b%c") == "a\\%b\\%c"
      assert UserActivity.escape_like("__init__") == "\\_\\_init\\_\\_"
    end

    test "handles a string that is entirely metacharacters" do
      assert UserActivity.escape_like("%%__\\\\") == "\\%\\%\\_\\_\\\\\\\\"
    end
  end
end
