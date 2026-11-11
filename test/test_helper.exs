# Orphaned ChromicPDF Chrome (D367). on_demand mode (config/test.exs) starts
# Chrome only when a PDF renders, but ChromicPDF's own teardown only closes
# the pipe, and Chrome on macOS outlives that. So attach/0 sends Chrome the
# DevTools Browser.close command after every print_to_pdf. The after_suite
# callback is a safety net: it closes any resident browser the same way and
# terminates the ChromicPDF child, because ExUnit does not shut the
# application supervisor down cleanly. Neither runs if `mix test` is killed;
# on macOS, Kanban.ChromeWatchdog then stops the Chrome once this VM is gone.
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
#
# The tests tagged :openssl3 run the `openssl pkeyutl` command a signed audit
# export's README gives. They need OpenSSL 3.0 or later; LibreSSL, the openssl
# that ships with macOS, cannot verify Ed25519. Where there is none the tag is
# excluded (Kanban.OpenSSL3). `mix test --only openssl3` still runs them, and
# they then fail with a message naming what is missing.
ExUnit.start(capture_log: true, exclude: Kanban.OpenSSL3.exclusions())

# Attachment blobs. A stored file's row rolls back with the test's sandbox,
# but Kanban.Attachments.Storage.Local has already written its bytes, so
# every run used to leave its blobs under the configured root. Each run gets
# its own directory under that root instead, removed when the suite ends.
# A shared root cannot simply be wiped: two `mix test` runs at once (a hook
# and a developer) would delete each other's files mid-test.
attachments_root =
  Path.join(Kanban.Attachments.Storage.Local.root(), "run-#{System.pid()}")

Application.put_env(
  :kanban,
  Kanban.Attachments.Storage.Local,
  Keyword.put(
    Application.get_env(:kanban, Kanban.Attachments.Storage.Local, []),
    :root,
    attachments_root
  )
)

ExUnit.after_suite(fn _result -> File.rm_rf(attachments_root) end)
Ecto.Adapters.SQL.Sandbox.mode(Kanban.Repo, :manual)
