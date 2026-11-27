defmodule Kanban.DecisionsTest do
  @moduledoc """
  Tests for `Kanban.Decisions.build/2`, `build_with_summary/2`,
  `review_queue/2`, the five sources and the `[:kanban, :decisions, :built]`
  event.
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
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Decisions
  alias Kanban.Decisions.Sources
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

  defp loaded(notification), do: Repo.preload(notification, task: :column)

  defp released_rows(user, task) do
    Notification
    |> where([n], n.user_id == ^user.id and n.task_id == ^task.id)
    |> where([n], n.event_type == :task_unclaimed)
    |> Repo.all()
  end

  # The claim runs out and a person moves the card back to Ready, which opens
  # it again; nothing sends a task_unclaimed.
  defp expire_and_return_to_ready!(task, cols) do
    past = DateTime.add(now(), -60)

    task
    |> Repo.reload!()
    |> Ecto.Changeset.change(%{
      claimed_at: DateTime.add(past, -3600),
      claim_expires_at: past,
      status: :open,
      column_id: cols["Ready"].id
    })
    |> Repo.update!()
  end

  # Sets dependencies directly: task_fixture/2 swaps given dependencies for
  # new placeholder tasks.
  defp dependent!(column, identifiers) do
    column
    |> task_fixture()
    |> Ecto.Changeset.change(dependencies: identifiers)
    |> Repo.update!()
  end

  defp waiting_since!(task, seconds_ago) do
    task
    |> Ecto.Changeset.change(review_requested_at: DateTime.add(now(), -seconds_ago))
    |> Repo.update!()
  end

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

      assert item.details == %{
               verdicts: [],
               first_failed_note: nil,
               size: %{
                 files: 0,
                 files_unknown: false,
                 changed_lines: 0,
                 truncated: false,
                 large_change: false
               }
             }

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

    test "a phone is not offered approve on a change too large for a phone", ctx do
      files = Enum.map_join(1..11, ", ", &"lib/file_#{&1}.ex")

      large =
        ctx.cols["Review"]
        |> pending_task!()
        |> Ecto.Changeset.change(actual_files_changed: files)
        |> Repo.update!()

      small = pending_task!(ctx.cols["Review"])
      assert Kanban.Reviews.MobileGuard.large_change?(large)

      actions = fn opts ->
        ctx.scope
        |> Decisions.build(opts)
        |> of_kind(:review)
        |> Map.new(&{&1.task_id, &1.actions})
      end

      phone = actions.(device_class: :phone)
      assert phone[large.id] == [:open_review, :request_changes, :open_on_web]
      assert phone[small.id] == [:open_review, :approve, :request_changes, :open_on_web]

      for opts <- [[device_class: :tablet], [device_class: nil], []] do
        assert :approve in actions.(opts)[large.id]
      end

      assert [%{actions: [:open_review, :request_changes, :open_on_web]}, _small] =
               ctx.scope
               |> Decisions.review_queue(device_class: :phone)
               |> Enum.sort_by(&(&1.task_id != large.id))
    end

    test "a review carries its size and whether it is large, on every device", ctx do
      files = Enum.map_join(1..11, ", ", &"lib/file_#{&1}.ex")

      large =
        ctx.cols["Review"]
        |> pending_task!()
        |> Ecto.Changeset.change(actual_files_changed: files)
        |> Repo.update!()

      small = pending_task!(ctx.cols["Review"])

      for opts <- [[device_class: :phone], [device_class: :tablet], []] do
        sizes =
          ctx.scope
          |> Decisions.build(opts)
          |> of_kind(:review)
          |> Map.new(&{&1.task_id, &1.details.size})

        assert %{files: 11, files_unknown: false, large_change: true} = sizes[large.id]
        assert %{files: 0, changed_lines: 0, large_change: false} = sizes[small.id]
      end
    end

    test "an unknown device class raises", ctx do
      assert_raise ArgumentError, ~r/unknown device class :watch/, fn ->
        Decisions.build(ctx.scope, device_class: :watch)
      end
    end

    test "a read-only member's review links to a page they can open", ctx do
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.owner)
      task = pending_task!(ctx.cols["Review"])

      [reader_item] = reader |> Scope.for_user() |> Decisions.build() |> of_kind(:review)
      [owner_item] = ctx.scope |> Decisions.build() |> of_kind(:review)

      assert reader_item.web_url == KanbanWeb.Endpoint.url() <> "/boards/#{ctx.board.id}"

      assert owner_item.web_url ==
               KanbanWeb.Endpoint.url() <> "/boards/#{ctx.board.id}/tasks/#{task.id}/edit"
    end

    test "an archived pending review is not an item", ctx do
      ctx.cols["Review"] |> pending_task!() |> archive!()

      assert ctx.scope |> Decisions.build() |> of_kind(:review) == []
    end

    test "items tied on time sort by the number in their id" do
      at = ~U[2026-11-19 10:00:00Z]
      item = &%{kind: :review, holds_up: 0, since: at, id: "review:task:#{&1}"}

      sorted =
        [item.(1_000_000), item.(999_999), item.(10)]
        |> Enum.sort_by(&Decisions.sort_key/1)
        |> Enum.map(& &1.id)

      assert sorted == ["review:task:10", "review:task:999999", "review:task:1000000"]
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

    test "stays cleared once an agent claims the task, after that claim expires and the task goes back to Ready",
         ctx do
      task = released!(ctx.cols, ctx.owner, "why")
      task = Repo.reload!(task)
      assert task.column_id == ctx.cols["Ready"].id
      assert [_] = ctx.scope |> Decisions.build() |> of_kind(:released)

      [row] = released_rows(ctx.owner, task)
      assert row |> loaded() |> Sources.notification_open?(now())

      {:ok, claimed, _hook} = Tasks.claim_next_task([], ctx.owner, ctx.board.id, task.identifier)
      assert claimed.id == task.id

      # The claim expires and a person drags the card back to Ready: no
      # task_unclaimed is sent, the task is open in Ready again, and the old
      # notification is still unread.
      expire_and_return_to_ready!(claimed, ctx.cols)

      assert ctx.scope |> Decisions.build() |> of_kind(:released) == []
      refute row |> Repo.reload!() |> loaded() |> Sources.notification_open?(now())
    end

    test "stays cleared after a claim that ClaimRelease returns to Ready without a notification",
         ctx do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, member, :modify, ctx.owner)
      task = released!(ctx.cols, ctx.owner, "why")

      {:ok, _claimed, _hook} = Tasks.claim_next_task([], member, ctx.board.id, task.identifier)
      assert [_] = Kanban.Tasks.ClaimRelease.release(member.id, [ctx.board.id])
      assert Repo.reload!(task).column_id == ctx.cols["Ready"].id

      assert ctx.scope |> Decisions.build() |> of_kind(:released) == []
    end

    test "a release of a real claim is an item: only a claim after the notification clears it",
         ctx do
      task = task_fixture(ctx.cols["Ready"])
      {:ok, claimed, _hook} = Tasks.claim_next_task([], ctx.owner, ctx.board.id, task.identifier)
      {:ok, _} = Tasks.unclaim_task(claimed, ctx.owner, "blocked")

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:released)
      assert item.details.reason == "blocked"
      [row] = released_rows(ctx.owner, task)
      assert row |> loaded() |> Sources.notification_open?(now())
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
      assert item.web_url == KanbanWeb.Endpoint.url() <> "/boards/#{ctx.board.id}"
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

    test "a failed goal holds up itself and then its dependents", ctx do
      goal = failed_goal!(ctx.cols["Doing"])

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:hook_failed)
      assert item.holds_up == 1
      assert item.held_identifiers == [goal.identifier]

      dependent = dependent!(ctx.cols["Backlog"], [goal.identifier])

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:hook_failed)
      assert item.holds_up == 2
      assert item.held_identifiers == [goal.identifier, dependent.identifier]
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

    test "an agent in a Doing column renamed in case or spacing is working, not idle", ctx do
      task_fixture(ctx.cols["Backlog"])
      agent = agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600))

      {:ok, _} =
        ctx.cols["Doing"]
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: agent.created_by_agent, status: :in_progress})

      ctx.cols["Doing"] |> Ecto.Changeset.change(name: " doing ") |> Repo.update!()

      assert ctx.scope |> Decisions.build() |> of_kind(:ready_empty) == []
      assert %{summary: %{agents_working: 1}} = Decisions.build_with_summary(ctx.scope)
    end

    test "an agent in a renamed Review column is waiting, not idle", ctx do
      task_fixture(ctx.cols["Backlog"])
      agent = agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600))

      {:ok, _} =
        ctx.cols["Review"]
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: agent.created_by_agent, status: :in_progress})

      ctx.cols["Review"] |> Ecto.Changeset.change(name: "REVIEW") |> Repo.update!()

      assert ctx.scope |> Decisions.build() |> of_kind(:ready_empty) == []
    end

    test "a board the person can only read is never ready_empty", ctx do
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.owner)
      task_fixture(ctx.cols["Backlog"])
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600))

      assert reader |> Scope.for_user() |> Decisions.build() |> of_kind(:ready_empty) == []
    end

    test "two columns of one name read only the leftmost, as the app's board list counts",
         ctx do
      plain = board_fixture(ctx.owner)
      column = &Kanban.ColumnsFixtures.column_fixture(plain, %{name: &1})
      backlog = column.("Backlog")
      _ready = column.("Ready")
      second_ready = column.(" ready ")
      second_backlog = column.("backlog")
      agent_task!(column.("Done"), DateTime.add(now(), -3600))

      # Work in a second Ready does not fill the leftmost, the one a promote fills.
      in_backlog = task_fixture(backlog)
      task_fixture(second_ready)
      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:ready_empty)
      assert item.details.backlog_count == 1

      [%{counts: counts}] =
        ctx.scope |> Boards.list_boards_for_app() |> Enum.filter(&(&1.board.id == plain.id))

      assert {counts.ready, counts.backlog} == {0, 1}

      # Work only in a second Backlog leaves the leftmost empty: nothing to promote.
      in_backlog |> Ecto.Changeset.change(archived_at: now()) |> Repo.update!()
      task_fixture(second_backlog)
      assert ctx.scope |> Decisions.build() |> of_kind(:ready_empty) == []
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

  describe "holds up, order and summary" do
    test "orders by holds_up then oldest, with ready_empty last", ctx do
      two = ctx.cols["Review"] |> pending_task!() |> waiting_since!(1800)
      one = ctx.cols["Review"] |> pending_task!() |> waiting_since!(7200)
      old = ctx.cols["Review"] |> pending_task!() |> waiting_since!(10_800)
      new = ctx.cols["Review"] |> pending_task!() |> waiting_since!(3600)

      direct = dependent!(ctx.cols["Backlog"], [two.identifier])
      chained = dependent!(ctx.cols["Backlog"], [direct.identifier])
      held_by_one = dependent!(ctx.cols["Backlog"], [one.identifier])

      # "Claude" waits on the reviews, so a different agent is the idle one.
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600), "Codex")

      items = Decisions.build(ctx.scope)

      assert Enum.map(items, & &1.id) == [
               "review:task:#{two.id}",
               "review:task:#{one.id}",
               "review:task:#{old.id}",
               "review:task:#{new.id}",
               "ready_empty:board:#{ctx.board.id}"
             ]

      assert Enum.map(items, & &1.holds_up) == [2, 1, 0, 0, nil]

      assert Enum.map(items, & &1.held_identifiers) == [
               [direct.identifier, chained.identifier],
               [held_by_one.identifier],
               [],
               [],
               []
             ]

      assert List.last(items).details.idle_agents == 1
    end

    test "lists at most 5 held identifiers but counts every held task", ctx do
      review = pending_task!(ctx.cols["Review"])
      held = for _i <- 1..7, do: dependent!(ctx.cols["Backlog"], [review.identifier])

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:review)
      assert item.holds_up == 7
      assert item.held_identifiers == held |> Enum.take(5) |> Enum.map(& &1.identifier)
    end

    test "caps the list at 100 and builds the summary", ctx do
      [first, second | _rest] =
        for i <- 1..101 do
          ctx.cols["Review"] |> pending_task!() |> waiting_since!(1000 + i)
        end

      # Both hold up the same task, and the first holds up one more.
      dependent!(ctx.cols["Backlog"], [first.identifier, second.identifier])
      dependent!(ctx.cols["Backlog"], [first.identifier])

      {:ok, _} =
        ctx.cols["Doing"]
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Codex", status: :in_progress})

      %{items: items, summary: summary} = Decisions.build_with_summary(ctx.scope)

      assert length(items) == 100
      assert Decisions.build(ctx.scope) == items
      assert Enum.take(items, 2) |> Enum.map(& &1.task_id) == [first.id, second.id]
      assert Enum.take(items, 2) |> Enum.map(& &1.holds_up) == [2, 1]
      assert summary == %{waiting: 101, held_up: 2, agents_working: 1}
    end

    test "held_up counts every distinct held task past the per-item cap of 50", ctx do
      wide = pending_task!(ctx.cols["Review"])
      narrow = pending_task!(ctx.cols["Review"])
      goal = failed_goal!(ctx.cols["Doing"])

      dependents = for _i <- 1..55, do: dependent!(ctx.cols["Backlog"], [wide.identifier])

      # The narrow review and the goal share the first ten, which the wide
      # review's own cap of 50 keeps; the last five lie past that cap.
      for task <- Enum.take(dependents, 10) do
        task
        |> Ecto.Changeset.change(
          dependencies: [wide.identifier, narrow.identifier, goal.identifier]
        )
        |> Repo.update!()
      end

      %{items: items, summary: summary} = Decisions.build_with_summary(ctx.scope)

      assert items |> of_kind(:review) |> Enum.map(& &1.holds_up) |> Enum.sort() == [10, 50]
      assert [%{holds_up: 11}] = of_kind(items, :hook_failed)
      # 55 dependents plus the failed goal itself.
      assert summary.held_up == 56
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

      # The failed goal holds itself up, so it ranks first; ready_empty is last.
      assert hd(first) == "hook_failed:goal:#{goal.id}"
      assert List.last(first) == "ready_empty:board:#{other_board.id}"

      assert Enum.sort(first) ==
               Enum.sort([
                 "review:task:#{review.id}",
                 "released:task:#{released.id}",
                 "claim_expired:task:#{expired.id}",
                 "hook_failed:goal:#{goal.id}",
                 "ready_empty:board:#{other_board.id}"
               ])
    end

    test "build_with_summary/1 gives no items and zero counts without a person or boards",
         ctx do
      pending_task!(ctx.cols["Review"])
      empty = %{items: [], summary: %{waiting: 0, held_up: 0, agents_working: 0}}

      assert Decisions.build_with_summary(nil) == empty
      assert Decisions.build_with_summary(%Scope{user: nil}) == empty
      assert user_fixture() |> Scope.for_user() |> Decisions.build_with_summary() == empty
    end

    test "agents_working counts the agents in Doing when nothing is waiting", ctx do
      {:ok, _} =
        ctx.cols["Doing"]
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Codex", status: :in_progress})

      assert Decisions.build_with_summary(ctx.scope) == %{
               items: [],
               summary: %{waiting: 0, held_up: 0, agents_working: 1}
             }
    end

    test "a hidden board's dependents never count toward holds_up", ctx do
      review = pending_task!(ctx.cols["Review"])

      hidden = columns(ai_optimized_board_fixture(user_fixture()))["Backlog"]
      # The hidden board's own task with the review's identifier, and its dependent.
      twin = task_fixture(hidden)
      stranger = dependent!(hidden, [review.identifier])
      assert twin.identifier == review.identifier
      refute stranger.identifier == review.identifier

      assert [item] = ctx.scope |> Decisions.build() |> of_kind(:review)
      assert item.holds_up == 0
      assert item.held_identifiers == []
    end
  end

  describe "review_queue" do
    test "returns only review items, in build order", ctx do
      low = ctx.cols["Review"] |> pending_task!() |> waiting_since!(1800)
      high = ctx.cols["Review"] |> pending_task!() |> waiting_since!(600)
      dependent!(ctx.cols["Backlog"], [high.identifier])
      released!(ctx.cols, ctx.owner, "why")
      failed_goal!(ctx.cols["Doing"])

      reviews = ctx.scope |> Decisions.build() |> of_kind(:review)

      assert Enum.map(reviews, & &1.task_id) == [high.id, low.id]
      assert Decisions.review_queue(ctx.scope) == reviews
    end

    test "keeps a review the 100-item decisions cap leaves out", ctx do
      for _i <- 1..100, do: released!(ctx.cols, ctx.owner, "why")
      # Waiting from a minute ahead, so it ranks after every release.
      review = ctx.cols["Review"] |> pending_task!() |> waiting_since!(-60)

      assert ctx.scope |> Decisions.build() |> of_kind(:review) == []
      assert [%{task_id: task_id}] = Decisions.review_queue(ctx.scope)
      assert task_id == review.id
    end

    test "is empty without a person", _ctx do
      assert Decisions.review_queue(nil) == []
    end
  end

  describe "telemetry" do
    test "emits decisions built with duration, count and source", ctx do
      attach_telemetry([:kanban, :decisions, :built])
      pending_task!(ctx.cols["Review"])
      released!(ctx.cols, ctx.owner, "why")

      Decisions.build_with_summary(ctx.scope)

      assert_receive {:telemetry_event, [:kanban, :decisions, :built],
                      %{count: 2, duration: duration}, metadata}

      assert is_integer(duration) and duration >= 0
      assert metadata == %{source: :api}

      Decisions.build(ctx.scope, source: :channel)
      assert_receive {:telemetry_event, _, %{count: 2}, %{source: :channel}}

      Decisions.review_queue(ctx.scope, source: :api)
      assert_receive {:telemetry_event, _, %{count: 2}, %{source: :api}}
    end

    test "emits a count of 0 for an empty scope", _ctx do
      attach_telemetry([:kanban, :decisions, :built])

      Decisions.build(nil)
      assert_receive {:telemetry_event, _, %{count: 0}, %{source: :api}}
    end

    test "counts the items waiting before the 100-item cap", ctx do
      for i <- 1..101, do: ctx.cols["Review"] |> pending_task!() |> waiting_since!(1000 + i)

      attach_telemetry([:kanban, :decisions, :built])

      assert length(Decisions.build(ctx.scope)) == 100
      assert_receive {:telemetry_event, _, %{count: 101}, %{source: :api}}
    end

    test "an unknown source raises", ctx do
      assert_raise ArgumentError, ~r/unknown decisions source/, fn ->
        Decisions.build(ctx.scope, source: :web)
      end
    end
  end

  describe "Sources.notification_open?/2" do
    defp hidden!(notification),
      do: notification |> Ecto.Changeset.change(in_app: false) |> Repo.update!()

    test "judges a hidden released row like a visible one", ctx do
      task = task_fixture(ctx.cols["Ready"])

      hidden =
        notification_fixture(ctx.owner, %{
          event_type: :task_unclaimed,
          board_id: ctx.board.id,
          task_id: task.id
        })
        |> hidden!()

      assert hidden |> loaded() |> Sources.notification_open?(DateTime.utc_now())

      task |> Ecto.Changeset.change(column_id: ctx.cols["Doing"].id) |> Repo.update!()
      refute hidden |> loaded() |> Sources.notification_open?(DateTime.utc_now())
    end

    test "is open while the claim it was about is still expired", ctx do
      task =
        ctx.cols["Doing"]
        |> task_fixture()
        |> claimed!(
          ctx.owner,
          ctx.cols["Doing"],
          DateTime.add(now(), -7200),
          DateTime.add(now(), -3600)
        )

      n =
        notification_fixture(ctx.owner, %{
          event_type: :claim_expired,
          board_id: ctx.board.id,
          task_id: task.id
        })
        |> hidden!()

      assert n |> loaded() |> Sources.notification_open?(DateTime.utc_now())

      claimed!(task, ctx.owner, ctx.cols["Doing"], now(), DateTime.add(now(), 3600))
      refute n |> loaded() |> Sources.notification_open?(DateTime.utc_now())
    end

    test "an older unread release that a newer read one replaced is not open, as in the list",
         ctx do
      task = task_fixture(ctx.cols["Ready"])
      attrs = %{event_type: :task_unclaimed, board_id: ctx.board.id, task_id: task.id}
      older = notification_fixture(ctx.owner, attrs)
      newer = notification_fixture(ctx.owner, attrs)

      # Same second: the higher id is the newer row, as the list reads them.
      Notification
      |> where([n], n.id in ^[older.id, newer.id])
      |> Repo.update_all(set: [inserted_at: DateTime.add(now(), -60)])

      assert [%{details: %{notification_id: newer_id}}] =
               ctx.scope |> Decisions.build() |> of_kind(:released)

      assert newer_id == newer.id
      assert newer |> Repo.reload!() |> loaded() |> Sources.notification_open?(now())

      {:ok, _} = Notifications.mark_read(ctx.scope, newer.id)

      assert ctx.scope |> Decisions.build() |> of_kind(:released) == []
      refute older |> Repo.reload!() |> loaded() |> Sources.notification_open?(now())
      refute newer |> Repo.reload!() |> loaded() |> Sources.notification_open?(now())
    end

    test "a newer hidden row replaces an older visible one", ctx do
      task = task_fixture(ctx.cols["Ready"])
      attrs = %{event_type: :task_unclaimed, board_id: ctx.board.id, task_id: task.id}
      older = notification_fixture(ctx.owner, attrs)
      newer = ctx.owner |> notification_fixture(attrs) |> hidden!()

      Notification
      |> where([n], n.id == ^older.id)
      |> Repo.update_all(set: [inserted_at: DateTime.add(now(), -60)])

      refute older |> Repo.reload!() |> loaded() |> Sources.notification_open?(now())
      assert newer |> loaded() |> Sources.notification_open?(now())
    end

    test "a release or an expired claim on an archived task is not open", ctx do
      released = task_fixture(ctx.cols["Ready"])

      released_row =
        notification_fixture(ctx.owner, %{
          event_type: :task_unclaimed,
          board_id: ctx.board.id,
          task_id: released.id
        })

      expired_task =
        ctx.cols["Doing"]
        |> task_fixture()
        |> claimed!(
          ctx.owner,
          ctx.cols["Doing"],
          DateTime.add(now(), -7200),
          DateTime.add(now(), -3600)
        )

      expired_row =
        notification_fixture(ctx.owner, %{
          event_type: :claim_expired,
          board_id: ctx.board.id,
          task_id: expired_task.id
        })

      for row <- [released_row, expired_row] do
        assert row |> loaded() |> Sources.notification_open?(DateTime.utc_now())
      end

      archive!(released)
      archive!(expired_task)

      for row <- [released_row, expired_row] do
        refute row |> loaded() |> Sources.notification_open?(DateTime.utc_now())
      end
    end

    test "is false for any other event type", ctx do
      task = task_fixture(ctx.cols["Ready"])

      n =
        notification_fixture(ctx.owner, %{
          event_type: :review_requested,
          board_id: ctx.board.id,
          task_id: task.id
        })

      refute n |> loaded() |> Sources.notification_open?(DateTime.utc_now())
    end
  end
end
