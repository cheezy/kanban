defmodule Kanban.Push.SummaryWorkerTest do
  @moduledoc """
  Tests for `Kanban.Push.SummaryWorker`: the one summary push after quiet
  hours, its send-time checks, overlapping runs, daylight-saving nights and
  quiet hours a settings change ends. Pushes only ever reach the
  `Kanban.Push.APNsMock` and `Kanban.Push.FCMMock` doubles.
  """
  # async: false - the lost-plan test switches the global :plans_enforced
  # application env on, and the overlap test puts Mox in global mode.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Mox
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.Scope
  alias Kanban.Columns
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Notifications
  alias Kanban.Notifications.PushSettings
  alias Kanban.Push.APNsMock
  alias Kanban.Push.FCMMock
  alias Kanban.Push.PayloadBuilder
  alias Kanban.Push.SummaryWorker
  alias Kanban.Tasks

  @summary [:kanban, :push, :summarized]
  @sent [:kanban, :push, :sent]
  @failed [:kanban, :push, :failed]

  # London is on UTC in January, so these read the same on its clock.
  @morning ~U[2026-01-15 07:05:00Z]

  setup :verify_on_exit!

  setup do
    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    attach_telemetry([@summary, @sent, @failed])
    %{owner: owner, board: board, cols: cols, scope: Scope.for_user(owner)}
  end

  defp pending_review!(ctx) do
    attrs = %{
      needs_review: true,
      completed_at: DateTime.truncate(DateTime.utc_now(), :second),
      completed_by_agent: "Claude"
    }

    {:ok, task} = ctx.cols["Review"] |> task_fixture() |> Tasks.update_task(attrs)
    task
  end

  defp ios_device!(ctx, attrs \\ %{}) do
    device_fixture(
      ctx.scope,
      Map.merge(%{push_token: "ios-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  defp android_device!(ctx, attrs) do
    device_fixture(
      ctx.scope,
      Map.merge(
        %{
          client_id: "stride-android",
          platform: :android,
          name: "Test Pixel",
          push_token: "android-#{System.unique_integer([:positive])}"
        },
        attrs
      )
    )
  end

  # 22:00 to 07:00 in London, with no summary taken yet.
  defp quiet!(ctx, set \\ []) do
    defaults = [
      quiet_hours_enabled: true,
      quiet_start: ~T[22:00:00],
      quiet_end: ~T[07:00:00],
      time_zone: "Europe/London",
      last_summary_at: nil
    ]

    {1, _} =
      PushSettings
      |> where([s], s.user_id == ^ctx.owner.id)
      |> Repo.update_all(set: Keyword.merge(defaults, set))

    :ok
  end

  defp run(now), do: perform_job(SummaryWorker, %{now: DateTime.to_iso8601(now)})

  defp last_summary_at(ctx), do: Repo.get!(PushSettings, ctx.owner.id).last_summary_at

  defp expect_sends(n) do
    test_pid = self()

    expect(APNsMock, :send, n, fn %Device{id: id}, payload ->
      send(test_pid, {:pushed, id, payload})
      :ok
    end)
  end

  describe "the cron run" do
    test "sends one summary after quiet hours when decisions wait", ctx do
      device = ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx)
      expect_sends(1)

      assert :ok = run(@morning)

      assert_received {:pushed, id, payload}
      assert id == device.id
      assert payload.title == "1 thing waited overnight"
      assert payload.body == nil
      assert payload.badge == 1
      assert payload.collapse_id == "quiet_hours_summary"
      assert payload.data == %{kind: "quiet_hours_summary", route: "now"}
      assert last_summary_at(ctx) == @morning

      assert_received {:telemetry_event, @summary, %{count: 1}, %{outcome: :sent}}

      assert_received {:telemetry_event, @sent, %{count: 1},
                       %{platform: :ios, event_type: :quiet_hours_summary}}

      # Later runs the same morning send nothing more.
      assert :ok = run(DateTime.add(@morning, 15, :minute))
      assert :ok = run(DateTime.add(@morning, 90, :minute))
      refute_received {:pushed, _, _}
    end

    test "sends the next night's summary the next morning", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx)
      expect_sends(2)

      assert :ok = run(@morning)
      assert :ok = run(DateTime.add(@morning, 1, :day))

      assert_received {:pushed, _, _}
      assert_received {:pushed, _, _}
    end

    test "sends nothing when nothing waits", ctx do
      ios_device!(ctx)
      quiet!(ctx)

      assert :ok = run(@morning)

      assert_received {:telemetry_event, @summary, _, %{outcome: :nothing_waiting}}
      # The period is taken, so a decision arriving later gets no late summary.
      assert last_summary_at(ctx) == @morning
      pending_review!(ctx)
      assert :ok = run(DateTime.add(@morning, 15, :minute))
      refute_received {:telemetry_event, @summary, _, _}
    end

    test "two overlapping runs send one summary", ctx do
      set_mox_global()
      ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx)
      expect_sends(1)

      results =
        [@morning, DateTime.add(@morning, 1, :second)]
        |> Enum.map(fn now -> Task.async(fn -> run(now) end) end)
        |> Task.await_many(10_000)

      assert results == [:ok, :ok]
      assert_received {:pushed, _, _}
      refute_received {:pushed, _, _}
    end

    test "a run that loses the claim to another sends nothing", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx)
      settings = Repo.get!(PushSettings, ctx.owner.id)
      assert {:due, period_end} = SummaryWorker.due(settings, @morning)

      # Another run took the period between this one reading and claiming it.
      assert Notifications.PushSettingsStore.claim_summary(settings, period_end, @morning) ==
               :claimed

      assert Notifications.PushSettingsStore.claim_summary(settings, period_end, @morning) ==
               :taken
    end

    test "sends nothing while quiet hours still hold", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx)

      assert :ok = run(~U[2026-01-15 06:50:00Z])
      # The next night: this morning's period ended hours ago.
      assert :ok = run(~U[2026-01-15 23:30:00Z])

      # A new period began within two hours of the last one ending.
      quiet!(ctx, quiet_start: ~T[08:00:00])
      assert :ok = run(~U[2026-01-15 08:30:00Z])

      refute_received {:pushed, _, _}
      refute_received {:telemetry_event, @summary, _, _}
    end

    test "never reaches a period that ended more than two hours ago", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx)

      assert :ok = run(~U[2026-01-15 09:01:00Z])
      refute_received {:pushed, _, _}
      assert last_summary_at(ctx) == nil

      # Missed runs inside the two hours catch up.
      expect_sends(1)
      assert :ok = run(~U[2026-01-15 08:55:00Z])
      assert_received {:pushed, _, _}
    end

    test "a gap too short for a run still gets its summary, once", ctx do
      # 07:10 to 07:05: the five-minute gap holds no 15-minute run.
      ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx, quiet_start: ~T[07:10:00], quiet_end: ~T[07:05:00])
      expect_sends(1)

      assert :ok = run(~U[2026-01-15 07:00:00Z])
      refute_received {:pushed, _, _}

      assert :ok = run(~U[2026-01-15 07:15:00Z])
      assert_received {:pushed, _, _}

      assert :ok = run(~U[2026-01-15 07:30:00Z])
      refute_received {:pushed, _, _}
    end

    test "is in step with a daylight-saving night", ctx do
      # 25 October 2026 London: 01:30 is read twice; quiet hours end at the
      # first reading, 00:30 UTC, and the repeated hour sends nothing more.
      ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx, quiet_end: ~T[01:30:00])
      expect_sends(1)

      assert :ok = run(~U[2026-10-25 00:15:00Z])
      refute_received {:pushed, _, _}

      assert :ok = run(~U[2026-10-25 00:30:00Z])
      assert_received {:pushed, _, _}

      assert :ok = run(~U[2026-10-25 01:30:00Z])
      assert :ok = run(~U[2026-10-25 01:45:00Z])
      refute_received {:pushed, _, _}
    end

    test "sends after a spring-forward night ends in the skipped hour", ctx do
      # 29 March 2026 London: 01:30 does not exist; quiet hours end at 02:00
      # BST, 01:00 UTC.
      ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx, quiet_end: ~T[01:30:00])

      assert :ok = run(~U[2026-03-29 00:45:00Z])
      refute_received {:pushed, _, _}

      expect_sends(1)
      assert :ok = run(~U[2026-03-29 01:00:00Z])
      assert_received {:pushed, _, _}
    end

    test "uses the settings time zone, not the device zone", ctx do
      ios_device!(ctx, %{time_zone: "Asia/Tokyo"})
      pending_review!(ctx)
      quiet!(ctx)

      # 07:05 in Tokyo (22:05 UTC) is when the device's zone would end them.
      assert :ok = run(~U[2026-01-14 22:05:00Z])
      refute_received {:pushed, _, _}

      expect_sends(1)
      assert :ok = run(@morning)
      assert_received {:pushed, _, _}
    end
  end

  describe "send-time checks" do
    test "a revoked device gets nothing", ctx do
      device = ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx)
      {:ok, revoked} = Devices.revoke_device(ctx.scope, device)
      # Revoking clears the token; put one back so only revoked_at keeps it out.
      revoked |> Ecto.Changeset.change(push_token: "left-behind") |> Repo.update!()

      assert :ok = run(@morning)
      refute_received {:pushed, _, _}
      assert_received {:telemetry_event, @summary, _, %{outcome: :no_device}}
    end

    test "a device revoked while the run sends gets nothing", ctx do
      first = ios_device!(ctx)
      second = ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx)
      test_pid = self()

      # Both are listed; the second is revoked during the first one's send.
      expect(APNsMock, :send, fn %Device{id: id}, _payload ->
        other = if id == first.id, do: second.id, else: first.id
        Device |> where(id: ^other) |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])
        send(test_pid, {:pushed, id})
        :ok
      end)

      assert :ok = run(@morning)
      assert_received {:pushed, _id}
      refute_received {:pushed, _id}
      assert_received {:telemetry_event, @summary, _, %{outcome: :sent}}
    end

    test "a lost plan sends nothing", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx)
      enforce_plans()

      assert :ok = run(@morning)
      refute_received {:pushed, _, _}
      assert_received {:telemetry_event, @summary, _, %{outcome: :plan_locked}}
    end

    test "every decision switch off sends nothing", ctx do
      ios_device!(ctx)
      pending_review!(ctx)

      switches = Map.new(PushSettings.decision_events(), &{Atom.to_string(&1), false})

      {:ok, _view} =
        Notifications.update_push_settings(ctx.scope, %{"switches" => switches},
          via: :web,
          feature: :notifications
        )

      quiet!(ctx)

      assert :ok = run(@morning)
      refute_received {:pushed, _, _}
      assert_received {:telemetry_event, @summary, _, %{outcome: :switched_off}}
    end

    test "a disabled user is not looked at", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx)

      Kanban.Accounts.User
      |> where(id: ^ctx.owner.id)
      |> Repo.update_all(set: [disabled_at: @morning])

      assert :ok = run(@morning)
      refute_received {:pushed, _, _}
      refute_received {:telemetry_event, @summary, _, _}
    end

    test "a rate-limited summary is given back and the next run sends it", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx)

      expect(APNsMock, :send, fn _device, _payload -> {:error, :rate_limited} end)
      assert :ok = run(@morning)
      assert last_summary_at(ctx) == nil

      assert_received {:telemetry_event, @failed, _,
                       %{event_type: :quiet_hours_summary, reason: :rate_limited}}

      assert_received {:telemetry_event, @summary, _, %{outcome: :failed}}

      expect_sends(1)
      assert :ok = run(DateTime.add(@morning, 15, :minute))
      assert_received {:pushed, _, _}
    end

    test "a dead token is cleared and the period stays taken", ctx do
      device = ios_device!(ctx)
      pending_review!(ctx)
      quiet!(ctx)

      expect(APNsMock, :send, fn _device, _payload -> :unregistered end)
      assert :ok = run(@morning)

      assert Repo.reload!(device).push_token == nil
      assert last_summary_at(ctx) == @morning
      assert_received {:telemetry_event, @summary, _, %{outcome: :failed}}
    end
  end

  describe "locale" do
    test "summary text is in the device locale", ctx do
      ios_device!(ctx, %{locale: "ja-JP"})
      android_device!(ctx, %{locale: "fr-FR"})
      pending_review!(ctx)
      pending_review!(ctx)
      quiet!(ctx)
      test_pid = self()

      expect(APNsMock, :send, fn _device, payload ->
        send(test_pid, {:ios, payload})
        :ok
      end)

      expect(FCMMock, :send, fn _device, payload ->
        send(test_pid, {:android, payload})
        :ok
      end)

      assert :ok = run(@morning)

      assert_received {:ios, %{title: "2 件が夜の間に待っていました", badge: 2}}
      assert_received {:android, %{title: "2 éléments ont attendu cette nuit", badge: 2}}
    end

    test "every locale has the summary's plural forms" do
      expected = %{
        "de" => {"1 Sache hat über Nacht gewartet", "3 Sachen haben über Nacht gewartet"},
        "en" => {"1 thing waited overnight", "3 things waited overnight"},
        "es" => {"1 cosa esperó durante la noche", "3 cosas esperaron durante la noche"},
        "fr" => {"1 élément a attendu cette nuit", "3 éléments ont attendu cette nuit"},
        "ja" => {"1 件が夜の間に待っていました", "3 件が夜の間に待っていました"},
        "pt" => {"1 item esperou durante a noite", "3 itens esperaram durante a noite"},
        "zh" => {"1 项事务在夜间等待处理", "3 项事务在夜间等待处理"}
      }

      assert Map.keys(expected) == KanbanWeb.Gettext |> Gettext.known_locales() |> Enum.sort()

      for {locale, {one, many}} <- expected do
        assert PayloadBuilder.summary(1, locale).title == one
        assert PayloadBuilder.summary(3, locale).title == many
      end
    end
  end

  describe "quiet hours a settings change ends" do
    defp change!(ctx, attrs) do
      {:ok, _view} =
        Notifications.update_push_settings(ctx.scope, attrs, via: :ios, feature: :notifications)
    end

    # Marks an enqueued job as running, as Oban does when it starts it;
    # perform_job/2 then runs its code without touching the row.
    defp running!(job_id) do
      {1, _} =
        Oban.Job
        |> where([j], j.id == ^job_id)
        |> Repo.update_all(set: [state: "executing", attempted_at: DateTime.utc_now()])

      :ok
    end

    # Quiet hours from an hour ago to an hour from now in London, entered
    # while they hold, so no stamp is set.
    defp quiet_now!(ctx) do
      local = DateTime.now!("Europe/London")
      clock = fn s -> local |> DateTime.add(s) |> DateTime.to_time() |> Time.truncate(:second) end
      quiet!(ctx, quiet_start: clock.(-3600), quiet_end: clock.(3600))
    end

    test "moving to a zone where they are over sends one summary", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet_now!(ctx)

      # Auckland is 12 or 13 hours from London, far outside the two hours.
      change!(ctx, %{"time_zone" => "Pacific/Auckland"})

      assert [%Oban.Job{args: %{"user_id" => user_id} = args}] =
               all_enqueued(worker: SummaryWorker)

      assert user_id == ctx.owner.id

      expect_sends(1)
      assert :ok = perform_job(SummaryWorker, args)
      assert_received {:pushed, _, _}
      assert_received {:telemetry_event, @summary, _, %{outcome: :sent}}

      # Neither the job again nor the cron sends a second one.
      assert :ok = perform_job(SummaryWorker, args)
      assert :ok = run(DateTime.add(DateTime.utc_now(), 15, :minute))
      refute_received {:pushed, _, _}
    end

    test "turning them off while they hold sends one summary", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet_now!(ctx)

      change!(ctx, %{"quiet_hours_enabled" => false})

      assert [%Oban.Job{args: args}] = all_enqueued(worker: SummaryWorker)
      expect_sends(1)
      assert :ok = perform_job(SummaryWorker, args)
      assert_received {:pushed, _, _}
    end

    test "a change that keeps them holding enqueues nothing", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet_now!(ctx)

      change!(ctx, %{"mode" => "every"})
      change!(ctx, %{"time_zone" => "Europe/Dublin"})

      refute_enqueued(worker: SummaryWorker)
      assert last_summary_at(ctx) == nil
    end

    test "a one-person job sends nothing once quiet hours hold again", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet_now!(ctx)
      args = %{"user_id" => ctx.owner.id, "ended_at" => DateTime.to_iso8601(DateTime.utc_now())}

      assert :ok = perform_job(SummaryWorker, args)
      assert :ok = perform_job(SummaryWorker, %{"user_id" => ctx.owner.id, "ended_at" => "bad"})
      refute_received {:pushed, _, _}
    end

    test "a rate-limited one-person summary is retried", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet_now!(ctx)
      change!(ctx, %{"quiet_hours_enabled" => false})
      assert [%Oban.Job{args: args}] = all_enqueued(worker: SummaryWorker)

      expect(APNsMock, :send, fn _device, _payload -> {:error, :unavailable} end)
      assert {:error, :unavailable} = perform_job(SummaryWorker, args)
      assert last_summary_at(ctx) == nil

      expect_sends(1)
      assert :ok = perform_job(SummaryWorker, args)
      assert_received {:pushed, _, _}
    end

    test "turning them back on outside quiet hours keeps the summary owed", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet_now!(ctx)
      change!(ctx, %{"quiet_hours_enabled" => false})

      # Back on, with hours that do not hold now, before the job has run.
      local = DateTime.now!("Europe/London")

      hhmm = fn s ->
        local |> DateTime.add(s) |> DateTime.to_time() |> Time.to_iso8601() |> binary_part(0, 5)
      end

      change!(ctx, %{
        "quiet_hours_enabled" => true,
        "quiet_start" => hhmm.(3 * 3600),
        "quiet_end" => hhmm.(5 * 3600)
      })

      jobs = all_enqueued(worker: SummaryWorker)
      assert jobs != []
      expect_sends(1)
      for job <- jobs, do: assert(:ok = perform_job(SummaryWorker, job.args))
      assert_received {:pushed, _, _}
      refute_received {:pushed, _, _}
    end

    test "a change made while the one-person summary is being sent sends no second one", ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet_now!(ctx)
      change!(ctx, %{"quiet_hours_enabled" => false})
      assert [%Oban.Job{id: job_id, args: args}] = all_enqueued(worker: SummaryWorker)
      running!(job_id)
      test_pid = self()

      # The period ended ten seconds ago and the job read its clock five
      # seconds ago, so the change below comes seconds after the job's claim.
      ago = &(DateTime.utc_now() |> DateTime.add(-&1) |> DateTime.to_iso8601())
      args = Map.merge(args, %{"ended_at" => ago.(10), "now" => ago.(5)})

      # The change lands while the job, having taken its period, is sending.
      expect(APNsMock, :send, fn %Device{id: id}, payload ->
        change!(ctx, %{"quiet_hours_enabled" => true, "time_zone" => "Pacific/Auckland"})
        send(test_pid, {:pushed, id, payload})
        :ok
      end)

      assert :ok = perform_job(SummaryWorker, args)
      assert_received {:pushed, _, _}

      for job <- all_enqueued(worker: SummaryWorker),
          do: assert(:ok = perform_job(SummaryWorker, job.args))

      refute_received {:pushed, _, _}
    end

    test "a change made before a running one-person job takes its period keeps the summary",
         ctx do
      ios_device!(ctx)
      pending_review!(ctx)
      quiet_now!(ctx)
      change!(ctx, %{"quiet_hours_enabled" => false})
      assert [%Oban.Job{id: job_id, args: args}] = all_enqueued(worker: SummaryWorker)
      running!(job_id)

      # Back on outside quiet hours while the job has started but not yet
      # taken its period: no second job, and no stamp that would take it.
      change!(ctx, %{"quiet_hours_enabled" => true, "time_zone" => "Pacific/Auckland"})
      assert last_summary_at(ctx) == nil
      # all_enqueued/1 lists queued jobs only, so the running job is not in it.
      assert all_enqueued(worker: SummaryWorker) == []

      expect_sends(1)
      assert :ok = perform_job(SummaryWorker, args)
      assert_received {:pushed, _, _}
    end

    test "a change before the next run keeps an ended period's summary", ctx do
      ios_device!(ctx)
      pending_review!(ctx)

      # Quiet hours that ended half an hour ago, not yet summarised.
      local = DateTime.now!("Europe/London")
      clock = fn s -> local |> DateTime.add(s) |> DateTime.to_time() |> Time.truncate(:second) end
      quiet!(ctx, quiet_start: clock.(-3 * 3600), quiet_end: clock.(-1800))

      change!(ctx, %{"time_zone" => "Europe/Dublin"})

      assert [%Oban.Job{args: args}] = all_enqueued(worker: SummaryWorker)
      expect_sends(1)
      assert :ok = perform_job(SummaryWorker, args)
      assert_received {:pushed, _, _}

      assert :ok = run(DateTime.add(DateTime.utc_now(), 60, :second))
      refute_received {:pushed, _, _}
    end

    test "turning them on after they ended sends no summary for that period", ctx do
      ios_device!(ctx)
      pending_review!(ctx)

      # A period that ended half an hour ago on London's clock.
      local = DateTime.now!("Europe/London")
      clock = fn s -> local |> DateTime.add(s) |> DateTime.to_time() |> Time.truncate(:second) end

      change!(ctx, %{
        "quiet_hours_enabled" => true,
        "quiet_start" => clock.(-3 * 3600) |> Time.to_iso8601() |> binary_part(0, 5),
        "quiet_end" => clock.(-1800) |> Time.to_iso8601() |> binary_part(0, 5),
        "time_zone" => "Europe/London"
      })

      refute_enqueued(worker: SummaryWorker)
      assert %DateTime{} = last_summary_at(ctx)

      assert :ok = run(DateTime.add(DateTime.utc_now(), 60, :second))
      refute_received {:pushed, _, _}
    end
  end

  describe "configuration" do
    test "runs every 15 minutes on the :push queue from the Oban crontab" do
      crontab =
        Application.fetch_env!(:kanban, Oban)
        |> Keyword.fetch!(:plugins)
        |> Enum.find_value(fn
          {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
          _plugin -> nil
        end)

      assert {"*/15 * * * *", SummaryWorker} in crontab
      assert SummaryWorker.__opts__()[:queue] == :push
    end
  end
end
