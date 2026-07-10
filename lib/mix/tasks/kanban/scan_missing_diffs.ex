defmodule Mix.Tasks.Kanban.ScanMissingDiffs do
  @shortdoc "Alerts on review tasks whose changed_files diff is missing"

  @moduledoc """
  Sweeps every task currently in a Review column and reports the ones whose
  work changed files but whose `changed_files` diff never arrived (task
  W1660). Each hit re-emits the `[:kanban, :task, :changed_files_missing]`
  telemetry event and a warning through
  `Kanban.Tasks.ChangedFilesAudit.scan_missing_diffs/0`, so existing gaps
  (not just newly-completing tasks) are surfaced.

  This is the standing-alert counterpart to the completion-time safety net
  added in D128 — run it on demand or from a scheduler to catch diffs that
  slipped through before the net existed.

  ## Usage

      mix kanban.scan_missing_diffs

  Reads the database, so the app is started first. Read-only — it never
  mutates a task; use `mix kanban.backfill_changed_files` to repopulate one.
  """
  use Mix.Task

  alias Kanban.Tasks.ChangedFilesAudit

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    ChangedFilesAudit.scan_missing_diffs()
    |> report()
  end

  defp report([]) do
    Mix.shell().info("No review tasks are missing their changed_files diff.")
    :ok
  end

  defp report(tasks) do
    Mix.shell().info("#{length(tasks)} review task(s) missing a changed_files diff:")

    Enum.each(tasks, fn task ->
      Mix.shell().info("  #{task.identifier} (id #{task.id}) — #{task.title}")
    end)

    :ok
  end
end
