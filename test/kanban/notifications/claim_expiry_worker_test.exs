defmodule Kanban.Notifications.ClaimExpiryWorkerTest do
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Columns
  alias Kanban.Notifications
  alias Kanban.Notifications.ClaimExpiryWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Tasks.Task

  setup do
    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    now = DateTime.truncate(DateTime.utc_now(), :second)

    %{owner: owner, board: board, cols: cols, now: now}
  end

  # The changeset rejects claims in the past, so age them with update_all.
  defp claimed_task(ctx, column_name, expired_minutes_ago, attrs \\ []) do
    task = task_fixture(ctx.cols[column_name], %{type: :work})

    set =
      Keyword.merge(
        [
          status: :in_progress,
          assigned_to_id: ctx.owner.id,
          claimed_at: DateTime.add(ctx.now, -(expired_minutes_ago + 60) * 60, :second),
          claim_expires_at: DateTime.add(ctx.now, -expired_minutes_ago * 60, :second)
        ],
        attrs
      )

    Task |> where(id: ^task.id) |> Repo.update_all(set: set)
    Repo.get!(Task, task.id)
  end

  defp expired_rows do
    Notification
    |> where(event_type: :claim_expired)
    |> Repo.all()
  end

  defp sweep(ctx), do: perform_job(ClaimExpiryWorker, %{"now" => DateTime.to_iso8601(ctx.now)})

  describe "cron configuration" do
    test "registers the sweeper every five minutes" do
      plugins = :kanban |> Application.fetch_env!(Oban) |> Keyword.fetch!(:plugins)
      {Oban.Plugins.Cron, opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)

      assert {"*/5 * * * *", ClaimExpiryWorker} in Keyword.fetch!(opts, :crontab)
    end

    test "manual testing mode keeps the cron plugin from running in tests" do
      assert Oban.config().testing == :manual
      assert Oban.config().plugins == []
    end
  end

  describe "perform/1" do
    test "notifies the assigned user once for a claim that expired in the window", ctx do
      task = claimed_task(ctx, "Doing", 10)

      assert :ok = sweep(ctx)

      assert [%Notification{} = n] = expired_rows()
      assert n.user_id == ctx.owner.id
      assert n.task_id == task.id
      assert n.board_id == ctx.board.id
      assert n.url_path == "/boards/#{ctx.board.id}/tasks/#{task.id}/edit"
      assert n.dedupe_key == "claim_expired:#{task.id}:#{DateTime.to_unix(task.claim_expires_at)}"
    end

    test "running the sweep twice notifies once; a later expired claim notifies again", ctx do
      task = claimed_task(ctx, "Doing", 20)

      assert :ok = sweep(ctx)
      assert :ok = sweep(ctx)
      assert length(expired_rows()) == 1

      Task
      |> where(id: ^task.id)
      |> Repo.update_all(
        set: [
          claimed_at: DateTime.add(ctx.now, -65 * 60, :second),
          claim_expires_at: DateTime.add(ctx.now, -5 * 60, :second)
        ]
      )

      assert :ok = sweep(ctx)
      assert length(expired_rows()) == 2
    end

    test "ignores re-claimed, completed, unclaimed and in-review tasks", ctx do
      claimed_task(ctx, "Doing", -30)
      claimed_task(ctx, "Done", 10, status: :completed)
      task_fixture(ctx.cols["Ready"], %{type: :work})
      claimed_task(ctx, "Review", 10)

      assert :ok = sweep(ctx)
      assert expired_rows() == []
    end

    test "ignores unassigned, archived and human tasks", ctx do
      claimed_task(ctx, "Doing", 10, assigned_to_id: nil)
      claimed_task(ctx, "Doing", 10, archived_at: ctx.now)
      claimed_task(ctx, "Doing", 10, human_task: true)

      assert :ok = sweep(ctx)
      assert expired_rows() == []
    end

    test "ignores claims that expired before the lookback window (e.g. downtime)", ctx do
      claimed_task(ctx, "Doing", 3 * 60)

      assert :ok = sweep(ctx)
      assert expired_rows() == []
    end

    test "returns :ok when there is nothing to do", ctx do
      assert :ok = sweep(ctx)
      assert :ok = perform_job(ClaimExpiryWorker, %{})
    end

    test "falls back to the current time for an invalid now argument", ctx do
      claimed_task(ctx, "Doing", 10)

      assert :ok = perform_job(ClaimExpiryWorker, %{"now" => "not-a-time"})
      assert [%Notification{}] = expired_rows()
    end

    test "honours a configured lookback window", ctx do
      original = Application.get_env(:kanban, ClaimExpiryWorker)
      on_exit(fn -> Application.put_env(:kanban, ClaimExpiryWorker, original) end)
      Application.put_env(:kanban, ClaimExpiryWorker, lookback_seconds: 5 * 60)

      claimed_task(ctx, "Doing", 10)

      assert :ok = sweep(ctx)
      assert expired_rows() == []
    end

    test "does not notify a user who left the board", ctx do
      outsider = user_fixture()
      claimed_task(ctx, "Doing", 10, assigned_to_id: outsider.id)

      assert :ok = sweep(ctx)
      assert expired_rows() == []
    end
  end

  describe "list_recently_expired_claims/2" do
    test "includes an expired in-window task and excludes open, completed and older ones",
         ctx do
      expired = claimed_task(ctx, "Doing", 15)
      task_fixture(ctx.cols["Ready"], %{type: :work})
      claimed_task(ctx, "Done", 15, status: :completed)
      claimed_task(ctx, "Doing", 5 * 60)

      assert [%Task{id: id}] = Notifications.list_recently_expired_claims(ctx.now, 2 * 60 * 60)
      assert id == expired.id
    end
  end
end
