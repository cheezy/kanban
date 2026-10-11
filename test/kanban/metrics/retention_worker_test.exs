defmodule Kanban.Metrics.RetentionWorkerTest do
  # Not async: the tests change the worker's application config, which is
  # global.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.TelemetryHelpers

  alias Kanban.Metrics.RetentionWorker
  alias Kanban.Repo

  @event [:kanban, :metrics, :retention_completed]
  @day 24 * 60 * 60

  setup do
    original = Application.get_env(:kanban, RetentionWorker)
    on_exit(fn -> restore_config(original) end)

    %{now: ~U[2026-10-11 12:00:00.000000Z]}
  end

  defp restore_config(nil), do: Application.delete_env(:kanban, RetentionWorker)
  defp restore_config(config), do: Application.put_env(:kanban, RetentionWorker, config)

  defp put_config(config), do: Application.put_env(:kanban, RetentionWorker, config)

  # Mirrors the write shape in KanbanWeb.Telemetry.MetricsStorage.
  defp metric!(recorded_at, name \\ "kanban.api.task_claimed") do
    Repo.insert_all("metrics_events", [
      %{
        metric_name: name,
        measurement: 1.0,
        metadata: %{"user_id" => "1"},
        recorded_at: recorded_at,
        inserted_at: recorded_at
      }
    ])
  end

  defp days_ago(now, days), do: DateTime.add(now, -days * @day, :second)

  defp metric_names do
    from(m in "metrics_events", order_by: m.metric_name, select: m.metric_name)
    |> Repo.all()
  end

  defp metric_count, do: Repo.aggregate("metrics_events", :count)

  defp run(ctx), do: perform_job(RetentionWorker, %{"now" => DateTime.to_iso8601(ctx.now)})

  describe "cron configuration" do
    test "cron entry is configured" do
      plugins = :kanban |> Application.fetch_env!(Oban) |> Keyword.fetch!(:plugins)
      {Oban.Plugins.Cron, opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)

      assert {"23 3 * * *", RetentionWorker} in Keyword.fetch!(opts, :crontab)
    end

    test "the worker's queue is configured with a depth of one" do
      queues = :kanban |> Application.fetch_env!(Oban) |> Keyword.fetch!(:queues)

      assert Keyword.fetch!(queues, :maintenance) == 1
      assert RetentionWorker.__opts__()[:queue] == :maintenance
    end

    test "config.exs ships a 90-day default" do
      config = "config/config.exs" |> Config.Reader.read!(env: :prod) |> Keyword.fetch!(:kanban)

      assert Keyword.fetch!(config, RetentionWorker)[:retention_days] == 90
    end
  end

  describe "perform/1" do
    test "removes only expired rows", ctx do
      put_config(retention_days: 90)
      metric!(days_ago(ctx.now, 91), "old.one")
      metric!(days_ago(ctx.now, 365), "old.two")
      metric!(days_ago(ctx.now, 89), "new.one")
      metric!(ctx.now, "new.two")

      assert :ok = run(ctx)

      assert metric_names() == ["new.one", "new.two"]
    end

    test "row at the cutoff is kept", ctx do
      put_config(retention_days: 30)
      cutoff = days_ago(ctx.now, 30)
      metric!(cutoff, "at.cutoff")
      metric!(DateTime.add(cutoff, -1, :microsecond), "just.before")
      metric!(DateTime.add(cutoff, 1, :microsecond), "just.after")

      assert :ok = run(ctx)

      assert metric_names() == ["at.cutoff", "just.after"]
    end

    test "invalid setting removes nothing", ctx do
      metric!(days_ago(ctx.now, 1_000))
      metric!(ctx.now)

      for config <- [
            [retention_days: 0],
            [retention_days: -5],
            [retention_days: "90"],
            [retention_days: 1.5],
            [retention_days: nil],
            [],
            [batch_size: 10]
          ] do
        put_config(config)

        log = capture_log(fn -> assert :ok = run(ctx) end)

        assert log =~ "metrics retention skipped", "expected a warning for #{inspect(config)}"
        assert metric_count() == 2, "rows were removed for #{inspect(config)}"
      end
    end

    test "a missing config entry removes nothing", ctx do
      Application.delete_env(:kanban, RetentionWorker)
      metric!(days_ago(ctx.now, 1_000))

      log = capture_log(fn -> assert :ok = run(ctx) end)

      assert log =~ "metrics retention skipped"
      assert metric_count() == 1
    end

    test "empty table", ctx do
      put_config(retention_days: 90)
      attach_telemetry(@event)

      assert :ok = run(ctx)

      assert_receive {:telemetry_event, @event, %{count: 0, batches: 1}, %{retention_days: 90}}
      assert metric_count() == 0
    end

    test "works in batches", ctx do
      put_config(retention_days: 7, batch_size: 2)
      attach_telemetry(@event)
      for _ <- 1..5, do: metric!(days_ago(ctx.now, 8))
      metric!(ctx.now, "kept")

      assert :ok = run(ctx)

      # 5 expired rows at 2 per batch: 2 + 2 + 1, and the short batch ends it.
      assert_receive {:telemetry_event, @event, %{count: 5, batches: 3}, _metadata}
      assert metric_names() == ["kept"]
    end

    test "an exact multiple of the batch size ends on an empty batch", ctx do
      put_config(retention_days: 7, batch_size: 2)
      attach_telemetry(@event)
      for _ <- 1..4, do: metric!(days_ago(ctx.now, 8))

      assert :ok = run(ctx)

      assert_receive {:telemetry_event, @event, %{count: 4, batches: 3}, _metadata}
      assert metric_count() == 0
    end

    test "an invalid batch size falls back to the default", ctx do
      put_config(retention_days: 7, batch_size: 0)
      attach_telemetry(@event)
      for _ <- 1..3, do: metric!(days_ago(ctx.now, 8))

      assert :ok = run(ctx)

      assert_receive {:telemetry_event, @event, %{count: 3, batches: 1}, _metadata}
    end

    test "reads the retention period from config at run time", ctx do
      metric!(days_ago(ctx.now, 10))

      put_config(retention_days: 30)
      assert :ok = run(ctx)
      assert metric_count() == 1

      put_config(retention_days: 5)
      assert :ok = run(ctx)
      assert metric_count() == 0
    end

    test "emits retention_completed", ctx do
      put_config(retention_days: 90)
      attach_telemetry(@event)
      metric!(days_ago(ctx.now, 100))
      metric!(days_ago(ctx.now, 200))

      assert :ok = run(ctx)

      assert_receive {:telemetry_event, @event, %{count: 2, batches: 1}, metadata}
      assert metadata == %{retention_days: 90}
    end

    test "does not emit retention_completed when the setting is invalid", ctx do
      put_config(retention_days: 0)
      attach_telemetry(@event)

      capture_log(fn -> assert :ok = run(ctx) end)

      refute_receive {:telemetry_event, @event, _measurements, _metadata}
    end

    test "never touches audit_events", ctx do
      put_config(retention_days: 1)
      old = days_ago(ctx.now, 1_000)

      Repo.insert_all("audit_events", [
        %{action: "login_failed", metadata: %{}, inserted_at: old}
      ])

      metric!(old)

      assert :ok = run(ctx)

      assert metric_count() == 0
      assert Repo.aggregate("audit_events", :count) == 1
    end
  end

  describe "delete_older_than/2" do
    test "returns rows removed and batches run", ctx do
      for _ <- 1..3, do: metric!(days_ago(ctx.now, 2))
      metric!(ctx.now)

      cutoff = days_ago(ctx.now, 1)

      assert RetentionWorker.delete_older_than(cutoff, 2) == {3, 2}
      assert metric_count() == 1
    end
  end
end
