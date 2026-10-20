defmodule Mix.Tasks.Kanban.ImportWorkspace do
  @shortdoc "Restores a workspace export archive into an Organization"

  @moduledoc """
  Restores a workspace export archive — the zip an org-admin downloads from
  the Export section of workspace settings — into this instance, as a new
  workspace of an existing Organization (W2222). The work is done by
  `Kanban.Workspaces.Export.Importer`.

  ## Usage

      mix kanban.import_workspace --file PATH --org-admin-email EMAIL [--dry-run]

    * `--file` — the export archive (`.zip`). Required.
    * `--org-admin-email` — the email of an enabled org-admin on this
      instance. The workspace is created in their Organization, which must
      already exist; the archive never creates or chooses one. Required.
    * `--dry-run` — check the archive and count what would be imported, then
      roll everything back. Nothing is written.

  The archive's `format_version` must be one this version of Stride
  understands, and the email must belong to an org-admin; otherwise the task
  stops before writing anything. Everything else happens in one transaction,
  so a failure part-way through leaves the database exactly as it was.

  Users are matched by email and never created; a disabled account is never
  matched. Attributions of a user with no account here are left empty and
  their memberships are skipped; their emails are listed at the end. A user
  whose account is not in the Organization is never attributed either: their
  attributions are left empty and they are named under "Skipped". Board
  access goes only to matched members of the Organization: a board owner who
  is not one is replaced by the importing org-admin, and any other board
  member who is not one is skipped and named, to be re-invited. Every board
  access the import gave is listed. The workspace keeps the archive's name, or
  gets an "(imported)" suffix when that name is taken in the Organization.

  It starts only the database connection (`Ecto.Migrator.with_repo/2`), not
  the application, so no job, broadcast or notification runs during an
  import. In a production release, where Mix is not available, call
  `Kanban.Release.import_workspace/3` with `bin/kanban eval`; it starts the
  database connection the same way.
  """
  use Mix.Task

  alias Kanban.Repo
  alias Kanban.Workspaces.Export.Importer

  @switches [file: :string, org_admin_email: :string, dry_run: :boolean]
  @usage "mix kanban.import_workspace --file PATH --org-admin-email EMAIL [--dry-run]"

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      {:ok, file, email, opts} ->
        Mix.Task.run("app.config")

        file
        |> import_with_repo(email, opts)
        |> handle()

      :error ->
        Mix.raise("Usage: #{@usage}. See mix help kanban.import_workspace.")
    end
  end

  defp parse_args(args) do
    args
    |> OptionParser.parse(strict: @switches)
    |> required_args()
  end

  # No stray arguments, no unknown switches, and both required switches.
  defp required_args({opts, [], []}), do: required_opts(opts, opts[:file], opts[:org_admin_email])
  defp required_args(_parsed), do: :error

  defp required_opts(opts, file, email) when is_binary(file) and is_binary(email),
    do: {:ok, file, email, opts}

  defp required_opts(_opts, _file, _email), do: :error

  defp import_with_repo(file, email, opts) do
    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        Importer.import_archive(file, email, dry_run: Keyword.get(opts, :dry_run, false))
      end)

    result
  end

  defp handle({:ok, report}) do
    report_header(report)
    report_reattributed(report.reattributed)
    report_list("Users with no account here (attribution left empty):", report.unmatched_users)
    report_list("Skipped:", Enum.map(report.skipped, &skipped_line/1))
    report_list("Board access given:", Enum.map(report.board_access, &board_access_line/1))
    report_dry_run(report.dry_run)
    :ok
  end

  defp handle({:error, reason}),
    do: Mix.raise("Import failed: #{message(reason)} Nothing was written.")

  defp report_header(report) do
    shell = Mix.shell()
    verb = if report.dry_run, do: "Would import", else: "Imported"
    shell.info(~s(#{verb} workspace "#{report.workspace_name}":))

    report.counts
    |> Enum.sort()
    |> Enum.each(fn {entity, count} -> shell.info("  #{entity}: #{count}") end)
  end

  defp report_reattributed(count) when count > 0,
    do: Mix.shell().info("Reattributed to the importing org-admin: #{count}")

  defp report_reattributed(_count), do: :ok

  defp report_dry_run(true), do: Mix.shell().info("Dry run: nothing was written.")
  defp report_dry_run(_dry_run), do: :ok

  defp skipped_line({entity, why}), do: "#{entity}: #{why}"

  defp board_access_line({email, board, access}), do: ~s(#{email}: #{access} on "#{board}")

  defp report_list(_title, []), do: :ok

  defp report_list(title, items) do
    Mix.shell().info(title)
    Enum.each(items, &Mix.shell().info("  #{&1}"))
  end

  defp message(:not_org_admin),
    do: "that email does not belong to an enabled org-admin on this instance."

  defp message({:unsupported_format_version, version}),
    do:
      "the archive's format_version #{inspect(version)} is not supported by this version of Stride."

  defp message(:invalid_archive), do: "the file is not a workspace export archive."
  defp message(:invalid_manifest), do: "the archive's manifest is missing or malformed."
  defp message(:archive_too_large), do: "the archive is too large to import."
  defp message(:counts_mismatch), do: "the archive's files do not match its manifest."
  defp message({:invalid_file, entity}), do: "the archive's #{entity} file is malformed."

  defp message({:invalid_row, entity, ref, errors}),
    do: "a #{entity} row (#{ref}) was refused: #{inspect(errors)}."

  defp message(other), do: inspect(other) <> "."
end
