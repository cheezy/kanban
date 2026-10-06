# Orphaned ChromicPDF Chrome (D367). on_demand mode (config/test.exs) starts
# Chrome only when a PDF renders, but ChromicPDF's own teardown only closes
# the pipe, and Chrome on macOS outlives that. So attach/0 sends Chrome the
# DevTools Browser.close command after every print_to_pdf. The after_suite
# callback is a safety net: it closes any resident browser the same way and
# terminates the ChromicPDF child, because ExUnit does not shut the
# application supervisor down cleanly. Neither runs if `mix test` is killed.
# Kanban.ChromicPDFCleanup's moduledoc has the details.
Kanban.ChromicPDFCleanup.attach()
ExUnit.after_suite(fn _result -> Kanban.ChromicPDFCleanup.stop() end)

# capture_log: true routes each test's log output through ExUnit's capture
# handler — it is buffered per test and only printed when that test fails.
# This keeps passing runs quiet (e.g. the intentional Logger.warning from
# Kanban.Tasks.ChangedFilesAudit that many review-bound-task tests trigger)
# while preserving the logs as failure diagnostics. Individual tests that
# assert on log output continue to use ExUnit.CaptureLog.capture_log/1.
ExUnit.start(capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Kanban.Repo, :manual)
