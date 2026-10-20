defmodule Mix.Tasks.Kanban.ImportWorkspaceTest do
  # async: false — swaps the process-wide Mix shell and points :export_dir at
  # a directory of its own.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Ecto.Query
  import ExUnit.CaptureIO
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspaceExportFixtures

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns.Column
  alias Kanban.Labels.Label
  alias Kanban.Labels.TaskLabel
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias Kanban.Tasks.TaskHistory
  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.Serializer
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember
  alias Mix.Tasks.Kanban.ImportWorkspace

  @tables [
    Workspace,
    Board,
    Column,
    Label,
    Task,
    TaskLabel,
    TaskComment,
    TaskHistory,
    BoardUser,
    WorkspaceMember
  ]

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous_shell) end)

    ctx = export_org_fixture()
    dir = tmp_export_dir()
    Map.put(ctx, :dir, dir)
  end

  defp export_archive(ctx) do
    {:ok, export} = Export.request_export(ctx.org_admin, ctx.workspace)
    %{success: 1} = Oban.drain_queue(queue: :workspace_exports)
    source = Repo.get!(WorkspaceExport, export.id).file_path
    copy = Path.join(ctx.dir, "copy-#{export.id}.zip")
    File.cp!(source, copy)
    copy
  end

  defp import!(args), do: capture_io(fn -> assert ImportWorkspace.run(args) == :ok end)

  defp counts, do: Map.new(@tables, &{&1, Repo.aggregate(&1, :count)})

  # Everything the round trip must preserve, keyed by identifiers and emails
  # rather than ids.
  defp snapshot(workspace_id) do
    boards = workspace_boards(workspace_id)
    board_ids = ids(boards)
    tasks = board_tasks(board_ids)
    task_ids = ids(tasks)
    emails = user_emails()

    %{
      boards: board_rows(boards),
      columns: column_rows(board_ids),
      tasks: task_rows(tasks),
      comments: comment_rows(task_ids, emails),
      history: history_rows(task_ids),
      board_users: board_user_rows(board_ids, emails),
      members: member_rows(workspace_id, emails)
    }
  end

  defp ids(records), do: Enum.map(records, & &1.id)

  defp workspace_boards(workspace_id) do
    from(b in Board, where: b.workspace_id == ^workspace_id, order_by: b.name)
    |> Repo.all()
  end

  defp board_tasks(board_ids) do
    from(t in Task,
      join: c in Column,
      on: c.id == t.column_id,
      join: b in Board,
      on: b.id == c.board_id,
      where: b.id in ^board_ids,
      preload: [:parent, :duplicate_of, :labels, :assigned_to, column: c],
      order_by: [b.name, t.identifier]
    )
    |> Repo.all()
  end

  defp user_emails do
    from(u in User, select: {u.id, u.email})
    |> Repo.all()
    |> Map.new()
  end

  defp board_rows(boards), do: Enum.map(boards, &{&1.name, &1.ai_optimized_board, &1.read_only})

  defp column_rows(board_ids) do
    from(c in Column,
      join: b in Board,
      on: b.id == c.board_id,
      where: b.id in ^board_ids,
      order_by: [b.name, c.position],
      select: {b.name, c.name, c.position, c.wip_limit}
    )
    |> Repo.all()
  end

  defp task_rows(tasks), do: Enum.map(tasks, &task_row/1)

  defp task_row(t) do
    {t.column.name, t.identifier, t.title, t.description, t.type, t.status, t.position,
     t.dependencies, t.parent && t.parent.identifier, t.duplicate_of && t.duplicate_of.identifier,
     t.archive_reason, Enum.map(t.labels, & &1.name), t.assigned_to && t.assigned_to.email,
     Enum.map(t.key_files, &{&1.file_path, &1.note}), t.inserted_at}
  end

  defp comment_rows(task_ids, emails) do
    from(c in TaskComment,
      where: c.task_id in ^task_ids,
      select: {c.content, c.author_user_id, c.mentioned_user_ids, c.inserted_at}
    )
    |> Repo.all()
    |> Enum.map(fn {content, author, mentions, at} ->
      {content, emails[author], Enum.map(mentions, &emails[&1]), at}
    end)
  end

  defp history_rows(task_ids) do
    from(h in TaskHistory,
      join: t in Task,
      on: t.id == h.task_id,
      where: h.task_id in ^task_ids,
      order_by: [t.identifier, h.inserted_at, h.type],
      select: {t.identifier, h.type, h.from_column, h.to_column, h.inserted_at}
    )
    |> Repo.all()
  end

  defp board_user_rows(board_ids, emails) do
    from(bu in BoardUser,
      join: b in Board,
      on: b.id == bu.board_id,
      where: b.id in ^board_ids,
      select: {b.name, bu.user_id, bu.access}
    )
    |> Repo.all()
    |> Enum.map(fn {board, user_id, access} -> {board, emails[user_id], access} end)
    |> Enum.sort()
  end

  defp member_rows(workspace_id, emails) do
    from(m in WorkspaceMember,
      where: m.workspace_id == ^workspace_id,
      select: {m.user_id, m.role}
    )
    |> Repo.all()
    |> Enum.map(fn {user_id, role} -> {emails[user_id], role} end)
    |> Enum.sort()
  end

  defp delete_source(ctx) do
    from(b in Board, where: b.workspace_id == ^ctx.workspace.id) |> Repo.delete_all()
    Workspace |> Repo.get!(ctx.workspace.id) |> Repo.delete!()
  end

  defp clear_author(rows, email) do
    Enum.map(rows, fn
      {content, ^email, mentions, at} -> {content, nil, mentions, at}
      row -> row
    end)
  end

  defp imported_workspace(name), do: from(w in Workspace, where: w.name == ^name) |> Repo.one!()

  test "an export round-trips with identical rows, remapped ids and preserved links", ctx do
    ctx = seed_workspace(ctx)
    path = export_archive(ctx)
    before = snapshot(ctx.workspace.id)
    source_task_ids = Enum.map([ctx.goal, ctx.first, ctx.second], & &1.id)
    delete_source(ctx)

    output = import!(["--file", path, "--org-admin-email", ctx.org_admin.email])

    assert output =~ ~s(Imported workspace "#{ctx.workspace.name}")
    workspace = imported_workspace(ctx.workspace.name)
    assert workspace.organization_id == ctx.organization.id
    refute workspace.personal

    # Board access and attributions only ever name members of the
    # Organization: the outsider's modify access on Alpha is skipped and named,
    # not restored, and their comment loses its author.
    expected =
      before
      |> Map.update!(:board_users, fn rows ->
        List.delete(rows, {"Alpha board", ctx.outsider.email, :modify})
      end)
      |> Map.update!(:comments, &clear_author(&1, ctx.outsider.email))

    assert length(expected.board_users) == length(before.board_users) - 1
    after_import = snapshot(workspace.id)
    assert after_import == expected
    assert output =~ "board member #{ctx.outsider.email} is not in the Organization"

    assert output =~
             "users: #{ctx.outsider.email} is not in the Organization; " <>
               "their attributions were left empty"

    assert output =~ "Board access given:"
    assert output =~ ~s(#{ctx.member.email}: owner on "Alpha board")
    refute output =~ ~s(#{ctx.outsider.email}: modify)

    new_task_ids =
      from(t in Task,
        where: t.title in ["Ship the export", "Write the serializer 日本語 ✓", "Write the importer"],
        select: t.id
      )
      |> Repo.all()

    assert new_task_ids |> MapSet.new() |> MapSet.disjoint?(MapSet.new(source_task_ids))
  end

  test "a dry run writes nothing", ctx do
    ctx = seed_workspace(ctx)
    path = export_archive(ctx)
    before = counts()

    output = import!(["--file", path, "--org-admin-email", ctx.org_admin.email, "--dry-run"])

    assert output =~ "Would import workspace"
    assert output =~ "Dry run: nothing was written."
    assert counts() == before
  end

  test "a name already taken in the Organization gets an (imported) suffix", ctx do
    path = export_archive(ctx)

    import!(["--file", path, "--org-admin-email", ctx.org_admin.email])

    assert imported_workspace("#{ctx.workspace.name} (imported)")
  end

  test "an unmatched user leaves the attribution empty and is reported", ctx do
    ctx = seed_workspace(ctx)
    path = export_archive(ctx)
    outsider_email = ctx.outsider.email
    delete_source(ctx)
    User |> Repo.get!(ctx.outsider.id) |> Repo.delete!()

    output = import!(["--file", path, "--org-admin-email", ctx.org_admin.email])

    assert output =~ outsider_email
    workspace = imported_workspace(ctx.workspace.name)

    [comment] =
      from(c in TaskComment,
        join: t in Task,
        on: t.id == c.task_id,
        join: col in Column,
        on: col.id == t.column_id,
        join: b in Board,
        on: b.id == col.board_id,
        where: b.workspace_id == ^workspace.id
      )
      |> Repo.all()

    assert comment.author_user_id == nil
    assert comment.content == "Looks good 🌍 — ça marche"
  end

  test "an unmatched board owner is replaced by the importing org-admin", ctx do
    ctx = seed_workspace(ctx)
    path = export_archive(ctx)
    delete_source(ctx)

    from(m in Kanban.Organizations.OrganizationMember, where: m.user_id == ^ctx.member.id)
    |> Repo.delete_all()

    User |> Repo.get!(ctx.member.id) |> Repo.delete!()

    output = import!(["--file", path, "--org-admin-email", ctx.org_admin.email])

    assert output =~ "Reattributed to the importing org-admin: 1"
    board = from(b in Board, where: b.name == "Alpha board") |> Repo.one!()
    assert Repo.get_by!(BoardUser, board_id: board.id, access: :owner).user_id == ctx.org_admin.id
  end

  test "attributions to an account outside the Organization are left empty", ctx do
    ctx = seed_workspace(ctx)
    outsider = ctx.outsider

    {1, _} =
      from(t in Task, where: t.id == ^ctx.first.id)
      |> Repo.update_all(
        set: [
          assigned_to_id: outsider.id,
          created_by_id: outsider.id,
          completed_by_id: outsider.id
        ]
      )

    from(c in TaskComment, where: c.author_user_id == ^outsider.id)
    |> Repo.update_all(set: [mentioned_user_ids: [ctx.org_admin.id, outsider.id]])

    Repo.insert!(%TaskHistory{
      task_id: ctx.first.id,
      type: :assignment,
      from_user_id: outsider.id,
      to_user_id: ctx.member.id
    })

    path = export_archive(ctx)
    delete_source(ctx)

    output = import!(["--file", path, "--org-admin-email", ctx.org_admin.email])

    assert output =~ "#{outsider.email} is not in the Organization; their attributions"
    workspace = imported_workspace(ctx.workspace.name)
    task_ids = workspace.id |> workspace_boards() |> ids() |> board_tasks() |> ids()

    first = Repo.get_by!(Task, title: "Write the serializer 日本語 ✓")
    assert first.id in task_ids
    assert {first.assigned_to_id, first.created_by_id, first.completed_by_id} == {nil, nil, nil}

    # A member of the Organization keeps their attribution.
    goal = Repo.get_by!(Task, title: "Ship the export")
    assert goal.id in task_ids
    assert goal.created_by_id == ctx.member.id

    [comment] = from(c in TaskComment, where: c.task_id in ^task_ids) |> Repo.all()
    assert comment.author_user_id == nil
    assert comment.mentioned_user_ids == [ctx.org_admin.id]

    assert [{nil, member_id}] =
             from(h in TaskHistory,
               where: h.task_id in ^task_ids and h.type == :assignment,
               select: {h.from_user_id, h.to_user_id}
             )
             |> Repo.all()

    assert member_id == ctx.member.id

    refute from(t in Task,
             where:
               t.id in ^task_ids and
                 (t.assigned_to_id == ^outsider.id or t.created_by_id == ^outsider.id or
                    t.completed_by_id == ^outsider.id or t.reviewed_by_id == ^outsider.id or
                    t.archived_by_id == ^outsider.id)
           )
           |> Repo.exists?()
  end

  test "a board owner outside the Organization is replaced by the importing org-admin", ctx do
    ctx = seed_workspace(ctx)
    path = export_archive(ctx)
    delete_source(ctx)

    # The account still exists here, but no longer belongs to the Organization.
    from(m in Kanban.Organizations.OrganizationMember, where: m.user_id == ^ctx.member.id)
    |> Repo.delete_all()

    output = import!(["--file", path, "--org-admin-email", ctx.org_admin.email])

    assert output =~ "Reattributed to the importing org-admin: 1"
    board = from(b in Board, where: b.name == "Alpha board") |> Repo.one!()
    assert Repo.get_by!(BoardUser, board_id: board.id, access: :owner).user_id == ctx.org_admin.id
    refute Repo.get_by(BoardUser, board_id: board.id, user_id: ctx.member.id)
  end

  test "a disabled account is never matched", ctx do
    ctx = seed_workspace(ctx)
    path = export_archive(ctx)
    delete_source(ctx)

    from(u in User, where: u.id == ^ctx.guest.id)
    |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

    output = import!(["--file", path, "--org-admin-email", ctx.org_admin.email])

    assert output =~ "Users with no account here"
    assert output =~ ctx.guest.email
    workspace = imported_workspace(ctx.workspace.name)

    guest_board_access =
      from(bu in BoardUser,
        join: b in Board,
        on: b.id == bu.board_id,
        where: b.workspace_id == ^workspace.id and bu.user_id == ^ctx.guest.id
      )

    refute Repo.exists?(guest_board_access)

    refute Repo.get_by(WorkspaceMember, workspace_id: workspace.id, user_id: ctx.guest.id)
  end

  describe "refusals write nothing" do
    setup ctx do
      Map.put(ctx, :path, export_archive(ctx))
    end

    test "an email that is not an enabled org-admin", ctx do
      disabled = user_fixture()
      organization_member_fixture(ctx.organization, disabled, :org_admin)

      from(u in User, where: u.id == ^disabled.id)
      |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

      before = counts()

      for email <- [ctx.member.email, "nobody@example.com", disabled.email] do
        assert_raise Mix.Error, ~r/does not belong to an enabled org-admin/, fn ->
          capture_io(fn ->
            ImportWorkspace.run(["--file", ctx.path, "--org-admin-email", email])
          end)
        end
      end

      assert counts() == before
    end

    test "an unsupported format_version", ctx do
      files = raw_archive(ctx.path)

      manifest =
        files["manifest.json"]
        |> Jason.decode!()
        |> Map.put("format_version", 99)
        |> Jason.encode!()

      path = rezip(ctx, Map.put(files, "manifest.json", manifest))
      before = counts()

      assert_raise Mix.Error, ~r/format_version 99 is not supported/, fn ->
        capture_io(fn ->
          ImportWorkspace.run(["--file", path, "--org-admin-email", ctx.org_admin.email])
        end)
      end

      assert counts() == before
    end

    test "an archive with an unexpected file or mismatched counts", ctx do
      files = raw_archive(ctx.path)
      extra = rezip(ctx, Map.put(files, "../evil.json", "[]"))

      mismatched =
        rezip(ctx, Map.put(files, "boards.json", ~s([{"id": 1, "name": "Ghost board"}])))

      assert_raise Mix.Error, ~r/not a workspace export archive/, fn ->
        capture_io(fn ->
          ImportWorkspace.run(["--file", extra, "--org-admin-email", ctx.org_admin.email])
        end)
      end

      assert_raise Mix.Error, ~r/do not match its manifest/, fn ->
        capture_io(fn ->
          ImportWorkspace.run(["--file", mismatched, "--org-admin-email", ctx.org_admin.email])
        end)
      end
    end

    test "a zip bomb with false size headers stops at the inflate limit", ctx do
      ctx = seed_workspace(ctx)
      path = export_archive(ctx)
      previous = Application.get_env(:kanban, Kanban.Workspaces.Export.Importer.Archive)
      on_exit(fn -> restore_env(Kanban.Workspaces.Export.Importer.Archive, previous) end)

      # Every declared size says 1 byte, so only the real inflated output can
      # trip the limit — which sits well below what the archive holds.
      lying = Path.join(ctx.dir, "lying.zip")
      File.write!(lying, declare_tiny_sizes(File.read!(path)))
      honest_total = files_total(raw_archive(path))

      Application.put_env(:kanban, Kanban.Workspaces.Export.Importer.Archive,
        max_uncompressed: div(honest_total, 2)
      )

      before = counts()

      assert_raise Mix.Error, ~r/too large to import/, fn ->
        capture_io(fn ->
          ImportWorkspace.run(["--file", lying, "--org-admin-email", ctx.org_admin.email])
        end)
      end

      assert counts() == before

      # Honest headers past the limit are refused before anything is inflated.
      assert_raise Mix.Error, ~r/too large to import/, fn ->
        capture_io(fn ->
          ImportWorkspace.run(["--file", path, "--org-admin-email", ctx.org_admin.email])
        end)
      end
    end

    test "a row that fails its changeset rolls the whole import back", ctx do
      ctx = seed_workspace(ctx)
      path = export_archive(ctx)
      files = raw_archive(path)

      tasks =
        files["tasks.json"]
        |> Jason.decode!()
        |> Enum.map(&Map.put(&1, "status", "not-a-status"))
        |> Jason.encode!()

      bad = rezip(ctx, Map.put(files, "tasks.json", tasks))
      before = counts()

      assert_raise Mix.Error, ~r/a tasks row .* was refused/, fn ->
        capture_io(fn ->
          ImportWorkspace.run(["--file", bad, "--org-admin-email", ctx.org_admin.email])
        end)
      end

      assert counts() == before
    end

    test "missing options print the usage", ctx do
      assert_raise Mix.Error, ~r/Usage: mix kanban.import_workspace/, fn ->
        ImportWorkspace.run(["--file", ctx.path])
      end

      assert_raise Mix.Error, ~r/Usage/, fn -> ImportWorkspace.run(["--bogus"]) end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:kanban, key)
  defp restore_env(key, value), do: Application.put_env(:kanban, key, value)

  defp files_total(files), do: files |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

  # Rewrites the uncompressed-size field of every local header (offset 22) and
  # central directory header (offset 24) to 1, leaving the data intact.
  defp declare_tiny_sizes(zip) do
    zip
    |> patch_size(<<"PK", 3, 4>>, 22)
    |> patch_size(<<"PK", 1, 2>>, 24)
  end

  defp patch_size(zip, signature, field_offset) do
    zip
    |> :binary.matches(signature)
    |> Enum.reduce(zip, fn {at, _length}, acc ->
      position = at + field_offset
      <<head::binary-size(^position), _size::binary-size(4), rest::binary>> = acc
      head <> <<1::little-32>> <> rest
    end)
  end

  defp rezip(ctx, files) do
    path = Path.join(ctx.dir, "rezip-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(files, fn {name, data} -> {String.to_charlist(name), data} end)
    {:ok, _} = path |> String.to_charlist() |> :zip.create(entries)
    path
  end

  test "the archive lists every entity the serializer knows" do
    assert length(Serializer.file_names()) == length(Serializer.entities()) + 1
  end
end
