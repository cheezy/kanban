defmodule Kanban.Plans.BootReportTest do
  # async: false - switches the global :plans_enforced application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Kanban.PlansHelpers

  alias Kanban.Plans.BootReport

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    previous = Application.fetch_env(:kanban, :plans_enforced)
    on_exit(fn -> restore_plans_enforced(previous) end)
  end

  test "says enforcement is off when the flag is false or not exactly true" do
    for value <- [false, nil, "true", 1] do
      Application.put_env(:kanban, :plans_enforced, value)

      log = capture_log([level: :info], fn -> assert :ok = BootReport.log_enforcement() end)

      assert log =~ "Paid-plan enforcement is off", "expected off for #{inspect(value)}"
      refute log =~ "enforcement is on"
    end
  end

  test "says enforcement is on when the flag is true" do
    enforce_plans()

    log = capture_log([level: :info], fn -> assert :ok = BootReport.log_enforcement() end)

    assert log =~ "Paid-plan enforcement is on"
  end

  test "Kanban.Application logs it before starting the supervision tree" do
    source = "../../../lib/kanban/application.ex" |> Path.expand(__DIR__) |> File.read!()
    [before_start, _rest] = String.split(source, "|> Supervisor.start_link(opts)", parts: 2)

    assert before_start =~ "Kanban.Plans.BootReport.log_enforcement()"
  end
end
