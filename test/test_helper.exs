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

# Warm Chrome's caches before any test renders a PDF. On GitHub Actions a
# freshly launched Chrome can pause for a long time before answering its first
# DevTools command, and in on_demand mode every render launches a fresh Chrome,
# so a cold first render (three at once in Kanban.ApplicationTest's concurrency
# test) timed out in NimblePool.checkout!/4. ChromicPDF.warm_up/1 is its
# documented remedy. It runs `chrome --dump-dom about:blank` once and waits for
# it to exit, so it leaves no Chrome behind (D367). It uses the same executable
# and flags the application hands ChromicPDF.
{:ok, _stderr} =
  Kanban.Application.chromic_pdf_options()
  |> Keyword.take([:chrome_executable, :no_sandbox, :chrome_args, :discard_stderr])
  |> ChromicPDF.warm_up()

# capture_log: true routes each test's log output through ExUnit's capture
# handler — it is buffered per test and only printed when that test fails.
# This keeps passing runs quiet (e.g. the intentional Logger.warning from
# Kanban.Tasks.ChangedFilesAudit that many review-bound-task tests trigger)
# while preserving the logs as failure diagnostics. Individual tests that
# assert on log output continue to use ExUnit.CaptureLog.capture_log/1.
ExUnit.start(capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Kanban.Repo, :manual)
