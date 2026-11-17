defmodule KanbanWeb.WorkspaceLive.ExportsTest do
  # Not async: request/2 enqueues a real export, so the tests point the
  # process-wide :export_dir at their own directory.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.WorkspaceExportFixtures

  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.Worker
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias KanbanWeb.WorkspaceLive.Exports

  @dash "—"

  defp export(attrs), do: struct(WorkspaceExport, attrs)

  defp in_days(days), do: :second |> DateTime.utc_now() |> DateTime.add(days, :day)

  describe "request/2" do
    setup do
      tmp_export_dir()
      export_org_fixture()
    end

    test "request/2 returns {:ok, message} for an org-admin", ctx do
      assert Exports.request(ctx.org_admin, ctx.workspace) ==
               {:ok,
                "Export requested. Its status and download link appear here when it is ready."}

      assert [%WorkspaceExport{status: "pending"} = export] = Repo.all(WorkspaceExport)
      assert export.workspace_id == ctx.workspace.id
      assert_enqueued(worker: Worker, args: %{"export_id" => export.id})
    end

    test "request/2 refuses a non-admin", ctx do
      for user <- [ctx.member, ctx.guest] do
        assert Exports.request(user, ctx.workspace) == {:error, :unauthorized}
      end

      assert Repo.aggregate(WorkspaceExport, :count) == 0
      refute_enqueued(worker: Worker)
    end

    test "request/2 reports an export already in progress", ctx do
      assert {:ok, _message} = Exports.request(ctx.org_admin, ctx.workspace)

      assert Exports.request(ctx.org_admin, ctx.workspace) ==
               {:error, "An export of this workspace is already in progress."}

      assert Repo.aggregate(WorkspaceExport, :count) == 1
    end
  end

  describe "list/2 and subscribe/1" do
    setup do
      tmp_export_dir()
      export_org_fixture()
    end

    test "list/2 shows an org-admin the workspace's exports and a non-admin none", ctx do
      assert Exports.list(ctx.org_admin, ctx.workspace) == []
      {:ok, export} = Export.request_export(ctx.org_admin, ctx.workspace)

      assert [%WorkspaceExport{id: id}] = Exports.list(ctx.org_admin, ctx.workspace)
      assert id == export.id
      assert Exports.list(ctx.member, ctx.workspace) == []
      assert Exports.list(ctx.guest, ctx.workspace) == []
    end

    test "subscribe/1 delivers the workspace's export status changes", ctx do
      assert Exports.subscribe(ctx.workspace) == :ok
      workspace_id = ctx.workspace.id

      {:ok, _export} = Export.request_export(ctx.org_admin, ctx.workspace)

      assert_receive {Export, :export_updated, ^workspace_id}
    end
  end

  describe "active?/1" do
    test "is true when any export is pending or running" do
      assert Exports.active?([export(status: "pending")])
      assert Exports.active?([export(status: "succeeded"), export(status: "running")])
    end

    test "is false for an empty list or only terminal statuses" do
      refute Exports.active?([])

      refute Exports.active?([
               export(status: "succeeded"),
               export(status: "failed"),
               export(status: "expired")
             ])
    end
  end

  describe "downloadable?/1" do
    test "downloadable?/1 follows status and expiry" do
      future = in_days(3)
      past = in_days(-3)

      assert [status: "succeeded", expires_at: future] |> export() |> Exports.downloadable?()

      refute [status: "succeeded", expires_at: past] |> export() |> Exports.downloadable?()
      refute [status: "succeeded", expires_at: nil] |> export() |> Exports.downloadable?()

      for status <- ["pending", "running", "failed", "expired"] do
        refute [status: status, expires_at: future] |> export() |> Exports.downloadable?()
      end
    end

    test "is false for anything that is not an export" do
      refute Exports.downloadable?(nil)
      refute Exports.downloadable?(%{status: "succeeded", expires_at: in_days(3)})
    end
  end

  describe "status_label/1" do
    test "status_label/1 covers every status" do
      assert Exports.status_label("pending") == "Pending"
      assert Exports.status_label("running") == "Running"
      assert Exports.status_label("succeeded") == "Ready to download"
      assert Exports.status_label("failed") == "Failed"
      assert Exports.status_label("expired") == "Expired"
    end

    test "returns a dash for an unknown status" do
      assert Exports.status_label("cancelled") == @dash
    end
  end

  describe "error_label/1" do
    test "error_label/1 covers every code" do
      assert Exports.error_label("storage_unavailable") ==
               "The archive could not be written to storage."

      assert Exports.error_label("workspace_unavailable") ==
               "The workspace is no longer available."

      assert Exports.error_label("timed_out") == "The export took too long and was stopped."
    end

    test "falls back to a generic message for an unknown or missing code" do
      generic = "The export failed. Please try again."

      assert Exports.error_label("disk_on_fire") == generic
      assert Exports.error_label(nil) == generic
    end
  end

  describe "format_bytes/1" do
    test "format_bytes/1 switches unit at each boundary" do
      assert Exports.format_bytes(0) == "0 B"
      assert Exports.format_bytes(1023) == "1023 B"
      assert Exports.format_bytes(1024) == "1.0 KB"
      assert Exports.format_bytes(1024 * 1024 - 1) == "1024.0 KB"
      assert Exports.format_bytes(1024 * 1024) == "1.0 MB"
      assert Exports.format_bytes(1024 * 1024 * 1024 - 1) == "1024.0 MB"
      assert Exports.format_bytes(1024 * 1024 * 1024) == "1.0 GB"
      assert Exports.format_bytes(5 * 1024 * 1024 * 1024 + 512 * 1024 * 1024) == "5.5 GB"
    end

    test "format_bytes/1 and status_label/1 return a dash for nil" do
      assert Exports.format_bytes(nil) == @dash
      assert Exports.status_label(nil) == @dash
      assert Exports.format_bytes(1.5) == @dash
      refute Exports.active?([])
    end
  end
end
