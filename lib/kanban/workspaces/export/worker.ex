defmodule Kanban.Workspaces.Export.Worker do
  @moduledoc """
  Oban worker that writes one workspace export archive (W2222).

  Enqueued by `Kanban.Workspaces.Export.request_export/2` with the export's
  id. It moves the export to running, has `Kanban.Workspaces.Export.Writer`
  write the archive, and records success (path, size, a
  `Kanban.Workspaces.Export.retention_days/0` expiry) or failure (an error
  code, never a message or a path).

  Idempotent, in the `Kanban.AfterGoal.GraceWorker` mould: an export that no
  longer exists, or that is no longer pending or running, makes the job a
  no-op that returns `:ok`, so Oban never retries it forever.

  `max_attempts: 1`, because retrying a whole export does not fix a full or
  unwritable disk; the org-admin can request another. Uniqueness is per
  workspace over the waiting states only. `:executing` is deliberately left
  out: by then the export row is running, and the database's one-active-export
  index already refuses a second export, while a job orphaned in `executing`
  by a killed node (no Lifeline plugin is configured) would otherwise block
  every future export of the workspace. The cleanup worker fails such stale
  exports.
  """

  use Oban.Worker,
    queue: :workspace_exports,
    max_attempts: 1,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:workspace_id],
      states: [:available, :scheduled, :retryable]
    ]

  alias Kanban.Repo
  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias Kanban.Workspaces.Export.Writer
  alias Kanban.Workspaces.Workspace

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"export_id" => export_id}}) do
    case Repo.get(WorkspaceExport, export_id) do
      nil ->
        Logger.info("workspace export #{export_id} not found, skipping")
        :ok

      %WorkspaceExport{status: status} = export when status in ["pending", "running"] ->
        run(export)

      %WorkspaceExport{} ->
        :ok
    end
  end

  def perform(%Oban.Job{}), do: :ok

  defp run(export) do
    case Repo.get(Workspace, export.workspace_id) do
      %Workspace{personal: false} = workspace ->
        export |> Export.mark_running() |> write(workspace)

      _missing_or_personal ->
        Export.mark_failed(export, "workspace_unavailable")
        :ok
    end
  end

  defp write(:skip, _workspace), do: :ok

  defp write({:ok, export}, workspace) do
    case Writer.write_archive(workspace, export.id, Export.export_dir()) do
      {:ok, %{path: path, byte_size: byte_size}} ->
        finish(export, path, byte_size)

      {:error, code} ->
        Export.mark_failed(export, Atom.to_string(code))
        {:error, code}
    end
  end

  # The cleanup worker may have failed an export that ran too long; its late
  # archive is then removed rather than left orphaned on disk.
  defp finish(export, path, byte_size) do
    case Export.mark_succeeded(export, path, byte_size) do
      {:ok, _export} ->
        :ok

      :skip ->
        File.rm(path)
        :ok
    end
  end
end
