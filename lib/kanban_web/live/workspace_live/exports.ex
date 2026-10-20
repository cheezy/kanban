defmodule KanbanWeb.WorkspaceLive.Exports do
  @moduledoc """
  The Export section of `KanbanWeb.WorkspaceLive.Settings` (W2222):
  requesting and listing workspace exports, kept out of the LiveView to hold
  it under the size limit. Socket-free: each function returns a result the
  LiveView turns into assigns and a flash.

  `Kanban.Workspaces.Export` re-checks the org-admin role on every request
  and list, so these never authorize anything themselves. Requesting only
  enqueues the job; the LiveView learns of progress from the export topic and
  never waits for it.
  """

  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.WorkspaceExport

  @doc "The workspace's recent exports for an org-admin, and none for anyone else."
  def list(actor, workspace), do: Export.list_exports(actor, workspace)

  @doc "Subscribes the LiveView to the workspace's export status changes."
  def subscribe(workspace), do: Export.subscribe(workspace.id)

  @doc """
  Requests an export of `workspace` as `actor`. Returns `{:ok, message}`,
  `{:error, :unauthorized}` or `{:error, message}` with a flash message.
  """
  def request(actor, workspace) do
    case Export.request_export(actor, workspace) do
      {:ok, _export} ->
        {:ok,
         gettext("Export requested. Its status and download link appear here when it is ready.")}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, :already_running} ->
        {:error, gettext("An export of this workspace is already in progress.")}

      {:error, _reason} ->
        {:error, gettext("The export could not be requested. Please try again.")}
    end
  end

  @doc "True while one of `exports` is pending or running."
  def active?(exports), do: Enum.any?(exports, &(&1.status in ["pending", "running"]))

  @doc "True when `export` can be downloaded now."
  def downloadable?(%WorkspaceExport{status: "succeeded", expires_at: %DateTime{} = expires_at}),
    do: DateTime.after?(expires_at, DateTime.utc_now())

  def downloadable?(_export), do: false

  @doc "The label shown for an export's status."
  def status_label("pending"), do: gettext("Pending")
  def status_label("running"), do: gettext("Running")
  def status_label("succeeded"), do: gettext("Ready to download")
  def status_label("failed"), do: gettext("Failed")
  def status_label("expired"), do: gettext("Expired")
  def status_label(_status), do: "—"

  @doc "The explanation shown for a failed export's error code."
  def error_label("storage_unavailable"),
    do: gettext("The archive could not be written to storage.")

  def error_label("workspace_unavailable"), do: gettext("The workspace is no longer available.")
  def error_label("timed_out"), do: gettext("The export took too long and was stopped.")
  def error_label(_code), do: gettext("The export failed. Please try again.")

  @doc "A byte count in B, KB, MB or GB, or a dash when unknown."
  def format_bytes(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1024 * 1024,
    do: scaled(bytes, 1024, "KB")

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1024 * 1024 * 1024,
    do: scaled(bytes, 1024 * 1024, "MB")

  def format_bytes(bytes) when is_integer(bytes), do: scaled(bytes, 1024 * 1024 * 1024, "GB")
  def format_bytes(_bytes), do: "—"

  defp scaled(bytes, unit, label),
    do: "#{:erlang.float_to_binary(bytes / unit, decimals: 1)} #{label}"
end
