defmodule Kanban.Workspaces.ExportTest do
  # Not async: tests point the process-wide :export_dir at their own directory.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspaceExportFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.User
  alias Kanban.ApiTokens
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.Serializer
  alias Kanban.Workspaces.Export.Worker
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias Kanban.Workspaces.Invitations

  setup do
    Map.put(export_org_fixture(), :export_dir, tmp_export_dir())
  end

  defp run_export(ctx) do
    {:ok, export} = Export.request_export(ctx.org_admin, ctx.workspace)
    assert %{success: 1} = Oban.drain_queue(queue: :workspace_exports)
    Repo.get!(WorkspaceExport, export.id)
  end

  defp succeeded_export(ctx, attrs \\ []) do
    path = Path.join([ctx.export_dir, "#{ctx.workspace.id}", "1.zip"])
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, "zip")

    {:ok, export} =
      ctx.workspace.id
      |> WorkspaceExport.create_changeset(ctx.org_admin.id)
      |> Repo.insert()

    export
    |> Ecto.Changeset.change(
      Keyword.merge(
        [
          status: "succeeded",
          file_path: path,
          byte_size: 3,
          expires_at: :second |> DateTime.utc_now() |> DateTime.add(3, :day)
        ],
        attrs
      )
    )
    |> Repo.update!()
  end

  describe "request_export/2" do
    test "an org-admin gets a pending export and exactly one job", ctx do
      assert {:ok, %WorkspaceExport{status: "pending"} = export} =
               Export.request_export(ctx.org_admin, ctx.workspace)

      assert export.requested_by_id == ctx.org_admin.id
      assert_enqueued(worker: Worker, args: %{"export_id" => export.id})
      assert length(all_enqueued(worker: Worker)) == 1
    end

    test "members, guests, outsiders, other admins and disabled admins are refused", ctx do
      other_org = organization_fixture()
      other_admin = user_fixture()
      organization_member_fixture(other_org, other_admin, :org_admin)

      disabled = user_fixture()
      organization_member_fixture(ctx.organization, disabled, :org_admin)

      from(u in User, where: u.id == ^disabled.id)
      |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

      for user <- [ctx.member, ctx.guest, user_fixture(), other_admin, disabled] do
        assert Export.request_export(user, ctx.workspace) == {:error, :unauthorized}
      end

      assert Repo.aggregate(WorkspaceExport, :count) == 0
      refute_enqueued(worker: Worker)
    end

    test "a personal workspace has no export", ctx do
      personal = Workspaces.get_personal_workspace(ctx.org_admin)
      assert Export.request_export(ctx.org_admin, personal) == {:error, :unauthorized}
    end

    test "a second request while one is pending is refused and enqueues nothing more", ctx do
      assert {:ok, _export} = Export.request_export(ctx.org_admin, ctx.workspace)
      assert Export.request_export(ctx.org_admin, ctx.workspace) == {:error, :already_running}

      assert Repo.aggregate(WorkspaceExport, :count) == 1
      assert length(all_enqueued(worker: Worker)) == 1
    end

    test "the database refuses a second active export even without the job check", ctx do
      {:ok, _} =
        ctx.workspace.id
        |> WorkspaceExport.create_changeset(ctx.org_admin.id)
        |> Repo.insert()

      assert {:error, changeset} =
               ctx.workspace.id
               |> WorkspaceExport.create_changeset(ctx.org_admin.id)
               |> Repo.insert()

      assert "an export is already in progress" in errors_on(changeset).workspace_id
    end

    test "Oban treats a second waiting job for the workspace as a conflict", ctx do
      args = %{"export_id" => 1, "workspace_id" => ctx.workspace.id}
      {:ok, _job} = args |> Worker.new() |> Oban.insert()

      assert {:ok, %Oban.Job{conflict?: true}} =
               %{args | "export_id" => 2} |> Worker.new() |> Oban.insert()
    end

    test "a new export can be requested once the previous one finished", ctx do
      run_export(ctx)

      assert {:ok, %WorkspaceExport{status: "pending"}} =
               Export.request_export(ctx.org_admin, ctx.workspace)
    end
  end

  describe "list_exports/2" do
    test "an org-admin sees the workspace's exports, others see none", ctx do
      {:ok, export} = Export.request_export(ctx.org_admin, ctx.workspace)

      assert [%WorkspaceExport{id: id, requested_by: %User{}}] =
               Export.list_exports(ctx.org_admin, ctx.workspace)

      assert id == export.id
      assert Export.list_exports(ctx.member, ctx.workspace) == []
      assert Export.list_exports(ctx.guest, ctx.workspace) == []
    end
  end

  describe "get_export_for_download/2" do
    test "an org-admin can download a finished export", ctx do
      export = succeeded_export(ctx)

      assert {:ok, %WorkspaceExport{id: id}} =
               Export.get_export_for_download(ctx.org_admin, "#{export.id}")

      assert id == export.id
    end

    test "members, guests, outsiders and another Organization's admin get not found", ctx do
      export = succeeded_export(ctx)
      other_org = organization_fixture()
      other_admin = user_fixture()
      organization_member_fixture(other_org, other_admin, :org_admin)

      for user <- [ctx.member, ctx.guest, user_fixture(), other_admin] do
        assert Export.get_export_for_download(user, export.id) == {:error, :not_found}
      end
    end

    test "a former org-admin gets not found", ctx do
      export = succeeded_export(ctx)

      from(m in OrganizationMember, where: m.user_id == ^ctx.org_admin.id)
      |> Repo.update_all(set: [role: :member])

      assert Export.get_export_for_download(ctx.org_admin, export.id) == {:error, :not_found}
    end

    test "expired, pending, failed and missing-file exports are not found", ctx do
      expired =
        succeeded_export(ctx,
          expires_at: :second |> DateTime.utc_now() |> DateTime.add(-1, :second)
        )

      assert Export.get_export_for_download(ctx.org_admin, expired.id) == {:error, :not_found}

      for status <- ["pending", "running", "failed", "expired"] do
        export =
          expired |> Ecto.Changeset.change(status: status, expires_at: nil) |> Repo.update!()

        assert Export.get_export_for_download(ctx.org_admin, export.id) == {:error, :not_found}
      end

      missing =
        expired
        |> Ecto.Changeset.change(
          status: "succeeded",
          file_path: Path.join(ctx.export_dir, "gone.zip"),
          expires_at: :second |> DateTime.utc_now() |> DateTime.add(1, :day)
        )
        |> Repo.update!()

      assert Export.get_export_for_download(ctx.org_admin, missing.id) == {:error, :not_found}
    end

    test "a stored path outside the export directory is never served", ctx do
      # A real file at the place "<export_dir>/../<name>" points to, so only
      # the path check can refuse it.
      outside =
        ctx.export_dir
        |> Path.dirname()
        |> Path.join("outside-#{System.unique_integer([:positive])}.zip")

      File.mkdir_p!(ctx.export_dir)
      File.write!(outside, "secret")
      on_exit(fn -> File.rm(outside) end)
      assert [ctx.export_dir, "..", Path.basename(outside)] |> Path.join() |> File.regular?()

      export =
        succeeded_export(ctx,
          file_path: Path.join([ctx.export_dir, "..", Path.basename(outside)])
        )

      assert Export.get_export_for_download(ctx.org_admin, export.id) == {:error, :not_found}
    end

    test "a symlink inside the export directory is never served", ctx do
      outside = outside_file(ctx)
      link = Path.join([ctx.export_dir, "#{ctx.workspace.id}", "link.zip"])
      link |> Path.dirname() |> File.mkdir_p!()
      :ok = File.ln_s(outside, link)
      assert File.regular?(link)

      export = succeeded_export(ctx, file_path: link)

      assert Export.get_export_for_download(ctx.org_admin, export.id) == {:error, :not_found}
    end

    test "a file under a symlinked directory inside the export directory is never served",
         ctx do
      outside = outside_file(ctx)
      linked_dir = Path.join(ctx.export_dir, "linked-#{ctx.workspace.id}")
      :ok = outside |> Path.dirname() |> File.ln_s(linked_dir)
      path = Path.join(linked_dir, Path.basename(outside))
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(path)

      export = succeeded_export(ctx, file_path: path)

      assert Export.get_export_for_download(ctx.org_admin, export.id) == {:error, :not_found}
    end

    test "malformed ids are not found", ctx do
      for id <- ["abc", "99999999999999999999", nil, -1, "1; drop"] do
        assert Export.get_export_for_download(ctx.org_admin, id) == {:error, :not_found}
      end
    end
  end

  describe "the worker" do
    test "writes a zip with a manifest and every entity file for this workspace only", ctx do
      ctx = seed_workspace(ctx)
      other = org_workspace_fixture(ctx.organization)

      {:ok, _} =
        Kanban.Boards.create_board(ctx.org_admin, %{name: "Other board"}, workspace: other)

      export = run_export(ctx)

      assert export.status == "succeeded"

      assert export.file_path ==
               Path.join([ctx.export_dir, "#{ctx.workspace.id}", "#{export.id}.zip"])

      assert export.byte_size == File.stat!(export.file_path).size
      assert DateTime.diff(export.expires_at, export.completed_at, :day) == 7

      files = read_archive(export.file_path)
      assert files |> Map.keys() |> Enum.sort() == Enum.sort(Serializer.file_names())

      manifest = files["manifest.json"]
      assert manifest["format_version"] == 1
      assert manifest["format"] == "stride-workspace-export"
      assert manifest["workspace"] == %{"name" => ctx.workspace.name}

      for entity <- Serializer.entities() do
        assert manifest["counts"]["#{entity}"] == length(files["#{entity}.json"])
      end

      assert Enum.map(files["boards.json"], & &1["name"]) |> Enum.sort() == [
               "Alpha board",
               "Beta board"
             ]

      assert manifest["counts"]["tasks"] == 6
      assert manifest["counts"]["workspace_members"] == 2
    end

    test "every row of every entity file carries exactly that entity's allow-listed fields",
         ctx do
      ctx = seed_workspace(ctx)
      files = ctx |> run_export() |> Map.fetch!(:file_path) |> read_archive()

      for entity <- Serializer.entities() do
        rows = Map.fetch!(files, Serializer.file_name(entity))
        expected = entity |> Serializer.fields() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

        assert rows != [], "the seeded workspace has no #{entity} rows to check"

        for row <- rows do
          assert row |> Map.keys() |> Enum.sort() == expected,
                 "#{entity} row keys differ from Serializer.fields(#{inspect(entity)})"
        end
      end
    end

    test "keeps cross-board dependencies, unicode and long text exactly", ctx do
      ctx = seed_workspace(ctx)
      files = read_archive(run_export(ctx).file_path)
      tasks = Map.new(files["tasks.json"], &{&1["id"], &1})

      assert tasks[ctx.beta_task.id]["dependencies"] == [ctx.second.identifier]
      assert tasks[ctx.second.id]["dependencies"] == [ctx.first.identifier]
      assert tasks[ctx.first.id]["title"] == "Write the serializer 日本語 ✓"
      assert tasks[ctx.first.id]["description"] == ctx.first.description
      assert tasks[ctx.first.id]["parent_id"] == ctx.goal.id
      assert tasks[ctx.copy.id]["duplicate_of_id"] == ctx.original.id

      assert [%{"file_path" => "lib/a.ex", "note" => "new", "position" => 0}] =
               tasks[ctx.first.id]["key_files"]

      assert [%{"content" => "Looks good 🌍 — ça marche"}] = files["comments.json"]
    end

    test "includes board members outside the Organization as users", ctx do
      ctx = seed_workspace(ctx)
      files = read_archive(run_export(ctx).file_path)

      assert Enum.any?(files["board_users.json"], &(&1["user_id"] == ctx.outsider.id))
      emails = Enum.map(files["users.json"], & &1["email"])
      assert ctx.outsider.email in emails

      assert Enum.all?(
               files["users.json"],
               &(Map.keys(&1) |> Enum.sort() == ["email", "id", "name"])
             )
    end

    test "never writes secrets or Organization contact details", ctx do
      ctx = seed_workspace(ctx)

      organization =
        ctx.organization
        |> Ecto.Changeset.change(
          contact_name: "Contact Person Zed",
          contact_email: "billing-contact-zed@example.com"
        )
        |> Repo.update!()

      {:ok, {_token, plain_board_token}} =
        ApiTokens.create_api_token(ctx.member, ctx.alpha, %{name: "Board token"})

      {:ok, {_token, plain_workspace_token}} =
        ApiTokens.create_workspace_api_token(ctx.org_admin, ctx.workspace, %{
          name: "Workspace token"
        })

      {:ok, invitation} =
        Invitations.invite_to_workspace(
          ctx.org_admin,
          ctx.workspace,
          %{"email" => "invitee-zed@example.com", "role" => "member"},
          &"https://stride.test/invitations/#{&1}"
        )

      user = Repo.get!(User, ctx.member.id)
      bytes = run_export(ctx).file_path |> raw_archive() |> Map.values() |> Enum.join()

      refute bytes =~ "hashed_password"
      refute bytes =~ user.hashed_password
      refute bytes =~ plain_board_token
      refute bytes =~ plain_workspace_token
      refute bytes =~ "token_hash"
      refute bytes =~ "invitee-zed@example.com"
      refute bytes =~ Base.encode16(invitation.token_hash, case: :lower)
      refute bytes =~ organization.name
      refute bytes =~ "Contact Person Zed"
      refute bytes =~ "billing-contact-zed@example.com"
    end

    test "an empty workspace exports empty files", ctx do
      files = read_archive(run_export(ctx).file_path)

      for entity <- Serializer.entities() -- [:workspace_members, :users] do
        assert files["#{entity}.json"] == []
      end
    end

    test "an unwritable export directory fails the export with a code and no path", ctx do
      blocker = Path.join(ctx.export_dir, "blocker")
      File.mkdir_p!(ctx.export_dir)
      File.write!(blocker, "a file, not a directory")
      Application.put_env(:kanban, :export_dir, Path.join(blocker, "exports"))

      {:ok, export} = Export.request_export(ctx.org_admin, ctx.workspace)

      assert {:error, :storage_unavailable} =
               perform_job(Worker, %{"export_id" => export.id, "workspace_id" => ctx.workspace.id})

      export = Repo.get!(WorkspaceExport, export.id)
      assert export.status == "failed"
      assert export.error == "storage_unavailable"
      assert is_nil(export.file_path)
    end

    test "is a no-op for a missing or finished export", ctx do
      assert :ok = perform_job(Worker, %{"export_id" => 0, "workspace_id" => ctx.workspace.id})

      # An hour old, so any write by the worker shows in updated_at.
      an_hour_ago = :second |> DateTime.utc_now() |> DateTime.add(-3600)
      export = succeeded_export(ctx, updated_at: an_hour_ago)

      assert :ok =
               perform_job(Worker, %{"export_id" => export.id, "workspace_id" => ctx.workspace.id})

      assert %WorkspaceExport{status: "succeeded", updated_at: ^an_hour_ago} =
               Repo.get!(WorkspaceExport, export.id)
    end

    test "broadcasts status changes on the workspace topic", ctx do
      :ok = Export.subscribe(ctx.workspace.id)
      run_export(ctx)
      workspace_id = ctx.workspace.id
      assert_received {Export, :export_updated, ^workspace_id}
    end
  end

  describe "Serializer" do
    test "encodes a user and a board with only their allow-listed fields" do
      assert :users
             |> Serializer.encode_row(%{
               id: 1,
               email: "a@b.c",
               name: "A",
               hashed_password: "x"
             })
             |> Map.keys()
             |> Enum.sort() == ["email", "id", "name"]

      board = %Kanban.Boards.Board{
        id: 1,
        name: "B",
        inserted_at: ~N[2026-01-01 00:00:00],
        updated_at: ~N[2026-01-01 00:00:00]
      }

      assert :boards |> Serializer.encode_row(board) |> Map.keys() |> Enum.sort() ==
               Serializer.fields(:boards) |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end

    test "decodes a manifest only for this format and version" do
      manifest =
        "W" |> Serializer.encode_manifest(%{}, DateTime.utc_now()) |> IO.iodata_to_binary()

      assert {:ok, %{"format_version" => 1}} = Serializer.decode_manifest(manifest)

      future = manifest |> Jason.decode!() |> Map.put("format_version", 99) |> Jason.encode!()
      assert Serializer.decode_manifest(future) == {:error, {:unsupported_format_version, 99}}
      assert Serializer.decode_manifest("not json") == {:error, :invalid_manifest}
    end

    test "decoding drops keys outside the allow-list" do
      json =
        Jason.encode!([%{"id" => 1, "email" => "a@b.c", "name" => "A", "hashed_password" => "x"}])

      assert {:ok, [row]} = Serializer.decode_rows(:users, json)
      assert Map.keys(row) |> Enum.sort() == ["email", "id", "name"]

      assert Serializer.decode_rows(:users, ~s({"not": "a list"})) ==
               {:error, {:invalid_file, :users}}
    end
  end

  # A real file next to the export directory, removed after the test.
  defp outside_file(ctx) do
    dir =
      ctx.export_dir
      |> Path.dirname()
      |> Path.join("outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.mkdir_p!(ctx.export_dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "secret.zip")
    File.write!(path, "secret")
    path
  end

  describe "servable_file?/1" do
    test "accepts a regular file inside the export directory", ctx do
      %{file_path: path} = succeeded_export(ctx)

      assert Export.servable_file?(path)
    end

    test "refuses a symlink, a missing file, a directory and a path outside", ctx do
      outside = outside_file(ctx)
      inside_target = Path.join(ctx.export_dir, "real.zip")
      File.write!(inside_target, "zip")
      link_inside = Path.join(ctx.export_dir, "link-inside.zip")
      :ok = File.ln_s(inside_target, link_inside)
      link_outside = Path.join(ctx.export_dir, "link-outside.zip")
      :ok = File.ln_s(outside, link_outside)

      for path <- [
            link_inside,
            link_outside,
            Path.join(ctx.export_dir, "missing.zip"),
            ctx.export_dir,
            outside,
            nil
          ] do
        refute Export.servable_file?(path), inspect(path)
      end
    end
  end

  describe "real_path/1" do
    test "resolves symlinks, relative targets and .. against the real parent", ctx do
      outside = outside_file(ctx)
      outside_dir = Path.dirname(outside)
      {:ok, real_outside_dir} = Export.real_path(outside_dir)

      link_dir = Path.join(ctx.export_dir, "to-outside")
      :ok = File.ln_s(outside_dir, link_dir)
      relative = Path.join(ctx.export_dir, "relative.zip")
      :ok = File.ln_s("to-outside/secret.zip", relative)

      real_secret = Path.join(real_outside_dir, "secret.zip")
      {:ok, real_export_dir} = Export.real_path(ctx.export_dir)

      assert link_dir |> Path.join("secret.zip") |> Export.real_path() == {:ok, real_secret}
      assert Export.real_path(relative) == {:ok, real_secret}

      # ".." after a symlinked directory climbs from the link's target.
      assert [link_dir, "..", "x"] |> Path.join() |> Export.real_path() ==
               {:ok, real_outside_dir |> Path.dirname() |> Path.join("x")}

      assert ctx.export_dir |> Path.join("./missing/./a.zip") |> Export.real_path() ==
               {:ok, Path.join([real_export_dir, "missing", "a.zip"])}
    end

    test "stops at a symlink loop", ctx do
      File.mkdir_p!(ctx.export_dir)
      a = Path.join(ctx.export_dir, "loop-a")
      b = Path.join(ctx.export_dir, "loop-b")
      :ok = File.ln_s(b, a)
      :ok = File.ln_s(a, b)

      assert Export.real_path(a) == {:error, :too_many_links}
      refute Export.servable_file?(a)
    end
  end

  describe "safe_path?/1" do
    test "accepts only paths inside the export directory", ctx do
      assert ctx.export_dir |> Path.join("1/2.zip") |> Export.safe_path?()
      refute ctx.export_dir |> Path.join("../2.zip") |> Export.safe_path?()
      refute Export.safe_path?("/etc/passwd")
      refute Export.safe_path?(nil)
    end
  end
end
