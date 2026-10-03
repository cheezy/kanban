defmodule Kanban.Notifications.TargetStatusWorkerTest do
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Notifications.Notification
  alias Kanban.Notifications.TargetStatusWorker
  alias Kanban.Targets
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks

  # A target created 2026-06-01 and due 2026-07-21 with one incomplete child
  # reads :on_track on 2026-06-08, :at_risk from 2026-06-09 (the lag passes
  # 0.15) and :missed once its date has passed.
  @created_on ~N[2026-06-01 00:00:00]
  @target_date ~D[2026-07-21]
  @on_track_now ~U[2026-06-08 00:17:00Z]
  @at_risk_now ~U[2026-06-09 00:17:00Z]
  @missed_now ~U[2026-07-22 00:17:00Z]

  setup do
    owner = user_fixture()
    board = board_fixture(owner)
    doing = column_fixture(board, %{name: "Doing"})

    %{owner: owner, board: board, doing: doing}
  end

  defp target_with_open_goal(owner, column, attrs \\ %{}) do
    target =
      delivery_target_fixture(
        owner,
        Enum.into(attrs, %{name: "Q3 launch", target_date: @target_date})
      )

    DeliveryTarget |> where(id: ^target.id) |> Repo.update_all(set: [inserted_at: @created_on])

    goal = task_fixture(column, %{type: :goal})
    {:ok, goal} = Tasks.update_task(goal, %{target_id: target.id})
    task_fixture(column, %{parent_id: goal.id})

    Repo.get!(DeliveryTarget, target.id)
  end

  defp sweep(now), do: perform_job(TargetStatusWorker, %{"now" => DateTime.to_iso8601(now)})

  defp status_rows do
    Notification
    |> where(event_type: :target_status_changed)
    |> order_by(:id)
    |> Repo.all()
  end

  defp watermark(target), do: Repo.get!(DeliveryTarget, target.id).last_notified_status

  defp set_target_date(target, date) do
    DeliveryTarget |> where(id: ^target.id) |> Repo.update_all(set: [target_date: date])
  end

  describe "cron configuration" do
    test "registers the sweeper hourly, off the top of the hour" do
      plugins = :kanban |> Application.fetch_env!(Oban) |> Keyword.fetch!(:plugins)
      {Oban.Plugins.Cron, opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)

      assert {"17 * * * *", TargetStatusWorker} in Keyword.fetch!(opts, :crontab)
    end

    test "manual testing mode keeps the cron plugin from running in tests" do
      assert Oban.config().testing == :manual
      assert Oban.config().plugins == []
    end
  end

  describe "perform/1" do
    test "returns :ok when there are no targets" do
      assert :ok = sweep(@missed_now)
      assert status_rows() == []
    end

    test "a target past its date notifies the owner once and records missed", ctx do
      target = target_with_open_goal(ctx.owner, ctx.doing)

      assert :ok = sweep(@missed_now)

      assert [%Notification{} = row] = status_rows()
      assert row.user_id == ctx.owner.id
      assert row.url_path == "/targets/#{target.id}"
      assert row.metadata == %{"status" => "missed", "target_date" => "2026-07-21"}
      assert watermark(target) == "missed"
    end

    test "running the sweep again with no change creates nothing", ctx do
      target_with_open_goal(ctx.owner, ctx.doing)

      sweep(@missed_now)
      sweep(DateTime.add(@missed_now, 3600))

      assert [%Notification{}] = status_rows()
    end

    test "a move into at_risk notifies, and a later move to missed notifies again", ctx do
      target = target_with_open_goal(ctx.owner, ctx.doing)

      sweep(@at_risk_now)
      assert [%Notification{metadata: %{"status" => "at_risk"}}] = status_rows()
      assert watermark(target) == "at_risk"

      sweep(@missed_now)

      assert ["at_risk", "missed"] = Enum.map(status_rows(), & &1.metadata["status"])
      assert watermark(target) == "missed"
    end

    test "a first observation of on_track is recorded without notifying", ctx do
      target = target_with_open_goal(ctx.owner, ctx.doing)

      sweep(@on_track_now)

      assert status_rows() == []
      assert watermark(target) == "on_track"
    end

    test "recovering is silent and a later slip notifies again", ctx do
      target = target_with_open_goal(ctx.owner, ctx.doing)

      sweep(@at_risk_now)
      assert length(status_rows()) == 1

      # The owner moves the date out: on_track again, recorded silently.
      set_target_date(target, ~D[2026-12-31])
      sweep(DateTime.add(@at_risk_now, 86_400))
      assert length(status_rows()) == 1
      assert watermark(target) == "on_track"

      # Then the date is moved into the past: missed, a second notification.
      set_target_date(target, ~D[2026-06-09])
      sweep(DateTime.add(@at_risk_now, 2 * 86_400))

      assert ["at_risk", "missed"] = Enum.map(status_rows(), & &1.metadata["status"])
    end

    test "the recorded status matches list_targets_with_status/2 for the owner", ctx do
      target = target_with_open_goal(ctx.owner, ctx.doing)

      for now <- [@on_track_now, @at_risk_now, @missed_now] do
        sweep(now)

        [summary] =
          ctx.owner
          |> Scope.for_user()
          |> Targets.list_targets_with_status(now)
          |> Enum.filter(&(&1.target.id == target.id))

        assert watermark(target) == Atom.to_string(summary.status)
      end
    end

    test "archived targets are skipped", ctx do
      target = target_with_open_goal(ctx.owner, ctx.doing)

      {:ok, _} =
        target
        |> DeliveryTarget.archive_changeset(%{archived_at: DateTime.utc_now()})
        |> Repo.update()

      assert :ok = sweep(@missed_now)
      assert status_rows() == []
      assert watermark(target) == nil
    end

    test "targets with no owner are skipped", ctx do
      target = target_with_open_goal(ctx.owner, ctx.doing)
      DeliveryTarget |> where(id: ^target.id) |> Repo.update_all(set: [owner_id: nil])

      assert :ok = sweep(@missed_now)
      assert status_rows() == []
      assert watermark(target) == nil
    end

    test "a target another owner can see notifies only its own owner, once", ctx do
      colleague = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, colleague, :modify, ctx.owner)
      # The colleague owns a target too, so the sweep also runs in their scope.
      colleague_board = board_fixture(colleague)
      colleague_doing = column_fixture(colleague_board, %{name: "Doing"})
      target_with_open_goal(colleague, colleague_doing, %{target_date: ~D[2027-12-31]})

      target = target_with_open_goal(ctx.owner, ctx.doing)

      sweep(@missed_now)

      assert [%Notification{user_id: user_id, url_path: url_path}] =
               Enum.filter(status_rows(), &(&1.url_path == "/targets/#{target.id}"))

      assert user_id == ctx.owner.id
      assert url_path == "/targets/#{target.id}"
    end

    test "goals on boards the owner cannot access never feed the status", ctx do
      stranger = user_fixture()
      stranger_board = board_fixture(stranger)
      stranger_doing = column_fixture(stranger_board, %{name: "Doing"})

      # The owner's target, but its only goal is on a board they cannot see.
      target = target_with_open_goal(ctx.owner, stranger_doing)

      assert :ok = sweep(@missed_now)
      assert status_rows() == []
      assert watermark(target) == nil
    end
  end
end
