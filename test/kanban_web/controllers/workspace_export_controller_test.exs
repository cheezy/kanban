defmodule KanbanWeb.WorkspaceExportControllerTest do
  # Not async: tests point the process-wide :export_dir at their own directory.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspaceExportFixtures

  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces.Export.WorkspaceExport

  setup do
    ctx = Map.put(export_org_fixture(), :export_dir, tmp_export_dir())
    path = Path.join([ctx.export_dir, "#{ctx.workspace.id}", "archive.zip"])
    path |> Path.dirname() |> File.mkdir_p!()
    {:ok, _} = path |> String.to_charlist() |> :zip.create([{~c"manifest.json", "{}"}])

    {:ok, export} =
      ctx.workspace.id
      |> WorkspaceExport.create_changeset(ctx.org_admin.id)
      |> Repo.insert()

    export =
      export
      |> Ecto.Changeset.change(
        status: "succeeded",
        file_path: path,
        byte_size: File.stat!(path).size,
        expires_at: :second |> DateTime.utc_now() |> DateTime.add(1, :day)
      )
      |> Repo.update!()

    Map.put(ctx, :export, export)
  end

  defp download(conn, user, id),
    do: conn |> log_in_user(user) |> get(~p"/workspace/exports/#{id}/download")

  test "an org-admin downloads the archive as a zip attachment", %{conn: conn} = ctx do
    attach_telemetry([[:kanban, :export, :stop]])
    conn = download(conn, ctx.org_admin, ctx.export.id)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/zip"

    assert get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="stride-workspace-export-#{ctx.export.id}.zip")]

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert {:ok, [{~c"manifest.json", "{}"}]} = :zip.unzip(conn.resp_body, [:memory])

    assert_received {:telemetry_event, [:kanban, :export, :stop], _measurements,
                     %{kind: :workspace_export, format: :zip}}
  end

  test "members, guests, outsiders and another Organization's admin get 404",
       %{conn: conn} = ctx do
    other_admin = user_fixture()
    organization_member_fixture(organization_fixture(), other_admin, :org_admin)

    for user <- [ctx.member, ctx.guest, user_fixture(), other_admin] do
      assert download(conn, user, ctx.export.id).status == 404
    end
  end

  test "a former org-admin gets 404", %{conn: conn} = ctx do
    from(m in OrganizationMember, where: m.user_id == ^ctx.org_admin.id)
    |> Repo.update_all(set: [role: :member])

    assert download(conn, ctx.org_admin, ctx.export.id).status == 404
  end

  test "an expired export and a missing file get 404", %{conn: conn} = ctx do
    expired =
      ctx.export
      |> Ecto.Changeset.change(expires_at: :second |> DateTime.utc_now() |> DateTime.add(-1))
      |> Repo.update!()

    assert download(conn, ctx.org_admin, expired.id).status == 404

    expired
    |> Ecto.Changeset.change(expires_at: :second |> DateTime.utc_now() |> DateTime.add(3600))
    |> Repo.update!()

    File.rm!(ctx.export.file_path)
    assert download(conn, ctx.org_admin, ctx.export.id).status == 404
  end

  test "a malformed or unknown id gets 404", %{conn: conn} = ctx do
    for id <- ["abc", "0", "99999999999999999999", "#{ctx.export.id + 1000}"] do
      assert download(conn, ctx.org_admin, id).status == 404
    end
  end

  test "a signed-out visitor is sent to log in", %{conn: conn} = ctx do
    conn = get(conn, ~p"/workspace/exports/#{ctx.export.id}/download")
    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
