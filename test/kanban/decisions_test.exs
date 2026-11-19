defmodule Kanban.DecisionsTest do
  @moduledoc """
  Tests for `Kanban.Decisions.build/1` and its five sources.
  """
  # Plan enforcement flips global application env, so this module is not async.
  use Kanban.DataCase, async: false

  import Ecto.Query, only: [where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.NotificationsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Decisions
  alias Kanban.Notifications
  alias Kanban.Notifications.Events
  alias Kanban.Notifications.Notification
  alias Kanban.Reviews
  alias Kanban.Tasks

  setup do
    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    %{owner: owner, board: board, cols: columns(board), scope: Scope.for_user(owner)}
  end

  defp columns(board), do: board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp pending_task!(column, attrs \\ %{}) do
    base = %{needs_review: true, completed_at: now(), completed_by_agent: "Claude"}
    {:ok, task} = column |> task_fixture() |> Tasks.update_task(Map.merge(base, attrs))
    task
  end

  defp claimed!(task, user, column, claimed_at, expires_at) do
    task
    |> Ecto.Changeset.change(%{
      status: :in_progress,
      assigned_to_id: user.id,
      claimed_at: claimed_at,
      claim_expires_at: expires_at,
      column_id: column.id
    })
    |> Repo.update!()
  end

  defp released!(cols, user, reason) do
    task = task_fixture(cols["Doing"])
    released_again!(task, cols, user, reason)
  end

  defp released_again!(task, cols, user, reason) do
    task = claimed!(task, user, cols["Doing"], now(), DateTime.add(now(), 3600))
    {:ok, task} = Tasks.unclaim_task(task, user, reason)
    task
  end

  defp expired!(cols, user) do
    task =
      cols["Doing"]
      |> task_fixture()
      |> claimed!(user, cols["Doing"], DateTime.add(now(), -7200), DateTime.add(now(), -3600))

    :ok = Events.claim_expired(task)
    task
  end

  defp failed_goal!(column, exit_code \\ 1) do
    goal =
      column
      |> task_fixture(%{type: :goal})
      |> Ecto.Changeset.change(%{after_goal_status: :pending})
      |> Repo.update!()

    {:ok, goal} = Tasks.report_after_goal(goal, attempt(exit_code))
    goal
  end

  defp attempt(exit_code) do
    %{
      "exit_code" => exit_code,
      "output" => "boom",
      "duration_ms" => 4000,
      "reported_at" => "2026-11-18T10:00:00Z"
    }
  end

  defp agent_task!(column, completed_at, agent \\ "Claude") do
    {:ok, task} =
      column
      |> task_fixture()
      |> Tasks.update_task(%{
        created_by_agent: agent,
        completed_by_agent: agent,
        completed_at: completed_at,
        status: :completed
      })

    task
  end

  defp of_kind(items, kind), do: Enum.filter(items, &(&1.kind == kind))

  defp archive!(task) do
    task |> Ecto.Changeset.change(%{archived_at: now()}) |> Repo.update!()
  end

  describe "review" do
    test "a pending review the person can approve is a review item", ctx do
      task = pending_task!(ctx.cols["Review"], %{priority: :high})

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:review)

      assert item.id == "review:task:#{task.id}"
      assert item.task_id == task.id
      assert item.board_id == ctx.board.id
      assert item.since == task |> Repo.reload!() |> Reviews.waiting_since()

      assert item.summary == %{
               identifier: task.identifier,
               title: task.title,
               priority: :high,
               agent: "Claude",
               board: %{id: ctx.board.id, name: ctx.board.name}
             }

      assert item.details == %{verdicts: [], first_failed_note: nil}
      assert item.actions == [:open_review, :approve, :request_changes, :open_on_web]

      assert item.web_url ==
               KanbanWeb.Endpoint.url() <> "/boards/#{ctx.board.id}/tasks/#{task.id}/edit"
    end

    test "the review items match the /review count", ctx do
      pending_task!(ctx.cols["Review"])
      pending_task!(ctx.cols["Review"])

      reviews = ctx.scope |> Decisions.build() |> of_kind(:review)

      assert length(reviews) == Reviews.queue_stats(scope: ctx.scope).count
      assert length(reviews) == 2
    end

    test "carries the four verdict pills and the first failed note", ctx do
      task =
        pending_task!(ctx.cols["Review"], %{
          review_report: "x",
          reviewer_result: %{
            "acceptance_criteria" => [%{"criterion" => "A", "status" => "met"}],
            "testing_strategy" => %{"status" => "passed", "note" => "fine"},
            "patterns" => %{"status" => "failed", "note" => "Query in a LiveView"},
            "pitfalls" => %{"status" => "passed", "note" => nil},
            "security_considerations" => %{"status" => "passed", "note" => nil}
          }
        })

      [item] = ctx.scope |> Decisions.build() |> of_kind(:review)
      sections = Enum.map(item.details.verdicts, & &1.section)

      assert sections == [
               :acceptance_criteria,
               :testing_strategy,
               :patterns,
               :security_considerations
             ]

      assert %{section: :patterns, status: "failed"} in item.details.verdicts
      assert item.details.first_failed_note == "Query in a LiveView"
      assert task |> Repo.reload!() |> Kanban.Reviews.MobileReview.verdicts() |> length() == 5
    end

    test "actions omit approve for a read-only member", ctx do
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.owner)
      pending_task!(ctx.cols["Review"])

      [reader_item] = reader |> Scope.for_user() |> Decisions.build() |> of_kind(:review)
      [owner_item] = ctx.scope |> Decisions.build() |> of_kind(:review)

      assert reader_item.actions == [:open_on_web]
      assert :approve in owner_item.actions
    end

    test "an archived pending review offers only the web", ctx do
      ctx.cols["Review"] |> pending_task!() |> archive!()

      assert [%{actions: [:open_on_web]}] = ctx.scope |> Decisions.build() |> of_kind(:review)
    end

    test "clears when the review is decided", ctx do
      task = pending_task!(ctx.cols["Review"])

      {:ok, _} =
        Tasks.update_task(task, %{
          review_status: :approved,
          reviewed_at: now(),
          reviewed_by_id: ctx.owner.id
        })

      assert ctx.scope |> Decisions.build() |> of_kind(:review) == []
    end
  end

  describe "released" do
    test "an unread task_unclaimed notification is a released item with its reason", ctx do
      task = released!(ctx.cols, ctx.owner, "Needs a product decision")

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:released)
      assert item.id == "released:task:#{task.id}"
      assert item.details.reason == "Needs a product decision"
      assert is_integer(item.details.notification_id)
      assert item.actions == [:reply, :move_to_backlog, :open_on_web]
      assert %DateTime{} = item.since
    end

    test "two notifications for the same released task are one item with the newest reason",
         ctx do
      task = released!(ctx.cols, ctx.owner, "First reason")
      Process.sleep(1100)
      released_again!(Repo.reload!(task), ctx.cols, ctx.owner, "Second reason")

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:released)
      assert item.details.reason == "Second reason"
    end

    test "clears when the notification is read", ctx do
      released!(ctx.cols, ctx.owner, "why")
      [item] = ctx.scope |> Decisions.build() |> of_kind(:released)

      {:ok, _} = Notifications.mark_read(ctx.scope, item.details.notification_id)

      assert ctx.scope |> Decisions.build() |> of_kind(:released) == []
    end

    test "clears when the task is claimed again or moved", ctx do
      task = released!(ctx.cols, ctx.owner, "why")
      claimed!(task, ctx.owner, ctx.cols["Doing"], now(), DateTime.add(now(), 3600))
      assert ctx.scope |> Decisions.build() |> of_kind(:released) == []

      other = released!(ctx.cols, ctx.owner, "why")
      other |> Ecto.Changeset.change(%{column_id: ctx.cols["Backlog"].id}) |> Repo.update!()
      assert ctx.scope |> Decisions.build() |> of_kind(:released) == []
    end

    test "a task archived while its notification is unread leaves the list", ctx do
      ctx.cols |> released!(ctx.owner, "why") |> archive!()

      assert ctx.scope |> Decisions.build() |> of_kind(:released) == []
    end

    test "move_to_backlog is left out while Backlog is at its WIP limit", ctx do
      released!(ctx.cols, ctx.owner, "why")
      task_fixture(ctx.cols["Backlog"])

      ctx.cols["Backlog"] |> Ecto.Changeset.change(%{wip_limit: 1}) |> Repo.update!()

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:released)
      assert item.actions == [:reply, :open_on_web]

      ctx.cols["Backlog"] |> Ecto.Changeset.change(%{wip_limit: 2}) |> Repo.update!()

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:released)
      assert item.actions == [:reply, :move_to_backlog, :open_on_web]
    end

    test "a read-only member can reply but not move the task", ctx do
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.owner)
      task = task_fixture(ctx.cols["Ready"])

      notification_fixture(reader, %{
        event_type: :task_unclaimed,
        board_id: ctx.board.id,
        task_id: task.id,
        body: "why"
      })

      assert [item] = reader |> Scope.for_user() |> Decisions.build() |> of_kind(:released)
      assert item.actions == [:reply, :open_on_web]
    end

    test "reads no other person's notifications", ctx do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, member, :modify, ctx.owner)
      released!(ctx.cols, member, "theirs")

      assert ctx.scope |> Decisions.build() |> of_kind(:released) == []
      assert [_] = member |> Scope.for_user() |> Decisions.build() |> of_kind(:released)
    end
  end

  describe "claim_expired" do
    test "a claim_expired item clears once the task is claimed again", ctx do
      task = expired!(ctx.cols, ctx.owner)

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:claim_expired)
      assert item.id == "claim_expired:task:#{task.id}"
      assert item.since == task.claim_expires_at
      assert item.details == %{claimed_at: task.claimed_at, expired_at: task.claim_expires_at}
      assert item.actions == [:move_to_backlog, :open_on_web]

      Process.sleep(1100)
      claimed!(task, ctx.owner, ctx.cols["Doing"], now(), DateTime.add(now(), 3600))

      assert ctx.scope |> Decisions.build() |> of_kind(:claim_expired) == []
    end

    test "a reclaim in the same second that expires again does not revive the old notification",
         ctx do
      task = expired!(ctx.cols, ctx.owner)

      # Pin the old notification half a second into a past second, then start
      # the new claim in that same second and let it expire a second later.
      sent_at = now() |> DateTime.add(-10) |> DateTime.add(500_000, :microsecond)

      Notification
      |> where([n], n.task_id == ^task.id)
      |> Repo.update_all(set: [inserted_at: sent_at])

      claimed_at = DateTime.truncate(sent_at, :second)
      claimed!(task, ctx.owner, ctx.cols["Doing"], claimed_at, DateTime.add(claimed_at, 1))

      assert ctx.scope |> Decisions.build() |> of_kind(:claim_expired) == []
    end

    test "clears when the task is completed, moved or archived", ctx do
      completed = expired!(ctx.cols, ctx.owner)

      completed
      |> Ecto.Changeset.change(%{column_id: ctx.cols["Review"].id})
      |> Repo.update!()

      assert ctx.scope |> Decisions.build() |> of_kind(:claim_expired) == []

      ctx.cols |> expired!(ctx.owner) |> archive!()
      assert ctx.scope |> Decisions.build() |> of_kind(:claim_expired) == []
    end
  end

  describe "hook_failed" do
    test "a goal whose last after_goal failed is a hook_failed item and clears after a success",
         ctx do
      goal = failed_goal!(ctx.cols["Doing"])

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:hook_failed)
      assert item.id == "hook_failed:goal:#{goal.id}"
      assert item.details == %{exit_code: 1, duration_ms: 4000}
      assert item.since == ~U[2026-11-18 10:00:00Z]
      assert item.actions == [:view_attempt, :open_on_web]

      assert item.web_url ==
               KanbanWeb.Endpoint.url() <> "/boards/#{ctx.board.id}/goals/#{goal.id}"

      refute inspect(item) =~ "boom"

      {:ok, _} = goal |> Repo.reload!() |> Tasks.report_after_goal(attempt(0))

      assert ctx.scope |> Decisions.build() |> of_kind(:hook_failed) == []
    end

    test "an attempt with a missing or non-integer exit_code is a failure", ctx do
      failed_goal!(ctx.cols["Doing"], "137")
      failed_goal!(ctx.cols["Doing"], nil)

      items = ctx.scope |> Decisions.build() |> of_kind(:hook_failed)

      assert length(items) == 2
      assert Enum.all?(items, &(&1.details.exit_code == nil))
    end

    test "a goal still waiting on its first after_goal report is not an item", ctx do
      ctx.cols["Doing"]
      |> task_fixture(%{type: :goal})
      |> Ecto.Changeset.change(%{after_goal_status: :pending})
      |> Repo.update!()

      assert ctx.scope |> Decisions.build() |> of_kind(:hook_failed) == []
    end
  end

  describe "ready_empty" do
    test "a board with Backlog work, no Ready task and an idle recent agent is ready_empty",
         ctx do
      task_fixture(ctx.cols["Backlog"])
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600))

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:ready_empty)
      assert item.id == "ready_empty:board:#{ctx.board.id}"
      assert item.task_id == nil
      assert item.details == %{idle_agents: 1, backlog_count: 1}
      assert item.actions == [:open_backlog, :open_on_web]
      assert item.summary.board == %{id: ctx.board.id, name: ctx.board.name}
      assert item.web_url == KanbanWeb.Endpoint.url() <> "/boards/#{ctx.board.id}"

      task_fixture(ctx.cols["Ready"])
      assert ctx.scope |> Decisions.build() |> of_kind(:ready_empty) == []
    end

    test "an agent last active 25 hours ago does not make ready_empty", ctx do
      task_fixture(ctx.cols["Backlog"])
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -25 * 3600))

      assert ctx.scope |> Decisions.build() |> of_kind(:ready_empty) == []
    end

    test "clears when no agent is idle", ctx do
      task_fixture(ctx.cols["Backlog"])
      agent = agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600))
      assert [_] = ctx.scope |> Decisions.build() |> of_kind(:ready_empty)

      {:ok, _} =
        ctx.cols["Doing"]
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: agent.created_by_agent, status: :in_progress})

      assert ctx.scope |> Decisions.build() |> of_kind(:ready_empty) == []
    end

    test "a board the person can only read is never ready_empty", ctx do
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.owner)
      task_fixture(ctx.cols["Backlog"])
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600))

      assert reader |> Scope.for_user() |> Decisions.build() |> of_kind(:ready_empty) == []
    end

    test "an empty Backlog or a board without Ready and Backlog columns is not ready_empty",
         ctx do
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600))
      plain = board_fixture(ctx.owner)
      done = Kanban.ColumnsFixtures.column_fixture(plain, %{name: "Done"})
      agent_task!(done, DateTime.add(now(), -3600))

      assert ctx.scope |> Decisions.build() |> of_kind(:ready_empty) == []
    end
  end

  describe "scope" do
    test "a person with no boards gets an empty list", ctx do
      pending_task!(ctx.cols["Review"])
      released!(ctx.cols, ctx.owner, "why")

      assert user_fixture() |> Scope.for_user() |> Decisions.build() == []
      assert Decisions.build(%Scope{user: nil}) == []
      assert Decisions.build(nil) == []
    end

    test "boards outside the plan and boards the person can't see are left out", ctx do
      other = user_fixture()
      org = organization_fixture()
      organization_member_fixture(org, ctx.owner)
      organization_member_fixture(org, other)

      paid = ctx.owner |> ai_optimized_board_fixture() |> move_board_to_organization(org)
      shared = other |> ai_optimized_board_fixture() |> move_board_to_organization(org)
      {:ok, _} = Boards.add_user_to_board(shared, ctx.owner, :modify, other)
      hidden = other |> ai_optimized_board_fixture() |> move_board_to_organization(org)

      paid_task = pending_task!(columns(paid)["Review"])
      shared_task = pending_task!(columns(shared)["Review"])
      pending_task!(columns(hidden)["Review"])
      pending_task!(ctx.cols["Review"])

      enforce_plans()

      ids = ctx.scope |> Decisions.build() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort(["review:task:#{paid_task.id}", "review:task:#{shared_task.id}"])

      {:ok, _} = Boards.remove_user_from_board(shared, ctx.owner, other)

      assert ctx.scope |> Decisions.build() |> Enum.map(& &1.id) == [
               "review:task:#{paid_task.id}"
             ]
    end

    test "item ids are stable across builds", ctx do
      review = pending_task!(ctx.cols["Review"])
      released = released!(ctx.cols, ctx.owner, "why")
      expired = expired!(ctx.cols, ctx.owner)
      goal = failed_goal!(ctx.cols["Doing"])

      other_board = ai_optimized_board_fixture(ctx.owner)
      other_cols = columns(other_board)
      task_fixture(other_cols["Backlog"])
      # A different agent: "Claude" waits on the pending review, so is not idle.
      agent_task!(other_cols["Done"], DateTime.add(now(), -3600), "Codex")

      first = ctx.scope |> Decisions.build() |> Enum.map(& &1.id)

      notification_fixture(ctx.owner, %{
        event_type: :claim_expired,
        board_id: ctx.board.id,
        task_id: expired.id,
        dedupe_key: "claim_expired:again:#{expired.id}"
      })

      second = ctx.scope |> Decisions.build() |> Enum.map(& &1.id)

      assert first == second

      assert first == [
               "review:task:#{review.id}",
               "released:task:#{released.id}",
               "claim_expired:task:#{expired.id}",
               "hook_failed:goal:#{goal.id}",
               "ready_empty:board:#{other_board.id}"
             ]
    end
  end
end
