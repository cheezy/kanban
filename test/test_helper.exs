# capture_log: true routes each test's log output through ExUnit's capture
# handler — it is buffered per test and only printed when that test fails.
# This keeps passing runs quiet (e.g. the intentional Logger.warning from
# Kanban.Tasks.ChangedFilesAudit that many review-bound-task tests trigger)
# while preserving the logs as failure diagnostics. Individual tests that
# assert on log output continue to use ExUnit.CaptureLog.capture_log/1.
ExUnit.start(capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Kanban.Repo, :manual)
