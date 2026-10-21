defmodule Kanban.Workspaces.Export.ImporterTest do
  # async: false — points the process-wide :export_dir at a directory of its own.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.WorkspaceExportFixtures

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias Kanban.Tasks.TaskHistory
  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.Importer
  alias Kanban.Workspaces.Export.Serializer
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias Kanban.Workspaces.Workspace

  @not_storable ["contains characters that are not allowed"]

  setup do
    ctx = seed_workspace(export_org_fixture())
    dir = tmp_export_dir()
    ctx = Map.put(ctx, :dir, dir)
    path = export_archive(ctx)
    from(b in Board, where: b.workspace_id == ^ctx.workspace.id) |> Repo.delete_all()
    Map.put(ctx, :files, read_archive(path))
  end

  defp export_archive(ctx) do
    {:ok, export} = Export.request_export(ctx.org_admin, ctx.workspace)
    %{success: 1} = Oban.drain_queue(queue: :workspace_exports)
    Repo.get!(WorkspaceExport, export.id).file_path
  end

  # Writes `files` (name => decoded JSON) as an archive whose manifest counts
  # match its rows, and imports it as the org-admin.
  defp import_files(ctx, files) do
    path = Path.join(ctx.dir, "crafted-#{System.unique_integer([:positive])}.zip")
    entries = files |> recount() |> Enum.map(&zip_entry/1)
    {:ok, _} = path |> String.to_charlist() |> :zip.create(entries)
    Importer.import_archive(path, ctx.org_admin.email)
  end

  defp recount(files) do
    counts =
      Map.new(Serializer.entities(), fn entity ->
        {Atom.to_string(entity), length(files[Serializer.file_name(entity)])}
      end)

    put_in(files, ["manifest.json", "counts"], counts)
  end

  defp zip_entry({name, data}), do: {String.to_charlist(name), Jason.encode!(data)}

  defp update_rows(files, entity, fun),
    do: Map.update!(files, Serializer.file_name(entity), &Enum.map(&1, fun))

  defp row(files, entity, id),
    do: Enum.find(files[Serializer.file_name(entity)], &(&1["id"] == id))

  # Sets `changes` on the task row exported from `task`.
  defp change_task(files, task, changes) do
    update_rows(files, :tasks, fn
      %{"id" => id} = row when id == task.id -> Map.merge(row, changes)
      row -> row
    end)
  end

  defp table_counts,
    do: Enum.map([Workspace, Board, Task, BoardUser], &Repo.aggregate(&1, :count))

  defp assert_refused(ctx, files, expected) do
    before = table_counts()
    assert {:error, {:invalid_row, _entity, _ref, _errors} = error} = import_files(ctx, files)
    assert expected.(error)
    assert table_counts() == before
  end

  describe "task hierarchy and identifiers" do
    test "a parent on another board is refused", ctx do
      files = change_task(ctx.files, ctx.beta_task, %{"parent_id" => ctx.goal.id})

      assert_refused(ctx, files, fn error ->
        error == {:invalid_row, :tasks, ctx.beta_task.identifier, :parent_on_another_board}
      end)
    end

    test "an archived duplicate of a task on another board is refused", ctx do
      files =
        change_task(ctx.files, ctx.beta_task, %{
          "archive_reason" => "duplicate",
          "archived_at" => "2026-01-01T00:00:00Z",
          "duplicate_of_id" => ctx.original.id
        })

      assert_refused(ctx, files, fn error ->
        error == {:invalid_row, :tasks, ctx.beta_task.identifier, :duplicate_on_another_board}
      end)
    end

    test "a task that is its own parent is refused", ctx do
      files = change_task(ctx.files, ctx.second, %{"parent_id" => ctx.second.id})

      assert_refused(ctx, files, fn error ->
        error == {:invalid_row, :tasks, ctx.second.identifier, :parent_is_itself}
      end)
    end

    test "a parent cycle is refused", ctx do
      files = change_task(ctx.files, ctx.goal, %{"parent_id" => ctx.first.id})

      assert_refused(ctx, files, fn {:invalid_row, :tasks, ref, reason} ->
        reason == :parent_cycle and ref in [ctx.goal.identifier, ctx.first.identifier]
      end)
    end

    test "two tasks with one identifier on one board are refused", ctx do
      files = change_task(ctx.files, ctx.second, %{"identifier" => ctx.first.identifier})

      assert_refused(ctx, files, fn error ->
        error == {:invalid_row, :tasks, ctx.first.identifier, :duplicate_identifier}
      end)
    end

    test "the same identifier on two boards is kept", ctx do
      files = change_task(ctx.files, ctx.beta_task, %{"identifier" => ctx.first.identifier})

      assert {:ok, %{counts: %{tasks: 6}}} = import_files(ctx, files)
    end

    test "a missing identifier or one with control or bidi characters is refused", ctx do
      row_number =
        Enum.find_index(ctx.files["tasks.json"], &(&1["id"] == ctx.second.id)) + 1

      for identifier <- [nil, "W\u202E9", "W9\n", "W9\u0000"] do
        files = change_task(ctx.files, ctx.second, %{"identifier" => identifier})

        assert_refused(ctx, files, fn error ->
          error == {:invalid_row, :tasks, "row #{row_number}", :invalid_identifier}
        end)
      end
    end
  end

  describe "values no column can hold" do
    test "a NUL byte in a history column name is a row error", ctx do
      files =
        update_rows(ctx.files, :task_history, fn
          %{"type" => "move"} = row -> Map.put(row, "from_column", "To\u0000do")
          row -> row
        end)

      assert_refused(ctx, files, fn {:invalid_row, :task_history, _ref, errors} ->
        errors == %{from_column: @not_storable}
      end)
    end

    test "a NUL byte in the workspace name is a row error", ctx do
      files = put_in(ctx.files, ["manifest.json", "workspace", "name"], "Plat\u0000form")

      assert_refused(ctx, files, fn error ->
        error == {:invalid_row, :workspace, "manifest", %{name: @not_storable}}
      end)
    end

    test "a position outside the 32-bit integer range is a row error", ctx do
      for position <- [1_000_000_000_000_000_000_000_000_000_000, -2_147_483_649, 2_147_483_648] do
        files = change_task(ctx.files, ctx.second, %{"position" => position})

        assert_refused(ctx, files, fn error ->
          error ==
            {:invalid_row, :tasks, ctx.second.identifier,
             %{position: ["must be between -2147483648 and 2147483647"]}}
        end)
      end
    end

    test "validate_int4/1 refuses only changed integer fields outside the 32-bit range" do
      in_range = Ecto.Changeset.change(%Task{}, position: 2_147_483_647, title: "x")
      assert Importer.validate_int4(in_range).valid?

      too_low = Ecto.Changeset.change(%Task{}, position: -2_147_483_649)

      assert errors_on(Importer.validate_int4(too_low)) == %{
               position: ["must be between -2147483648 and 2147483647"]
             }

      # An id is a bigint column, so it is left to its own type.
      assert %Task{}
             |> Ecto.Changeset.change(parent_id: 10 ** 12)
             |> Importer.validate_int4()
             |> Map.fetch!(:valid?)
    end

    test "a column position outside the range is a row error too", ctx do
      [%{"id" => column_id} | _] = ctx.files["columns.json"]

      files =
        update_rows(ctx.files, :columns, fn
          %{"id" => ^column_id} = row -> Map.put(row, "position", 10 ** 30)
          row -> row
        end)

      assert_refused(ctx, files, fn {:invalid_row, :columns, _ref, errors} ->
        errors == %{position: ["must be between -2147483648 and 2147483647"]}
      end)
    end
  end

  describe "board owners" do
    test "a board with no access rows at all is owned by the importing org-admin", ctx do
      files =
        Map.update!(ctx.files, "board_users.json", fn rows ->
          Enum.reject(rows, &(&1["board_id"] == ctx.beta.id))
        end)

      assert {:ok, report} = import_files(ctx, files)
      assert report.reattributed == 1
      assert {ctx.org_admin.email, "Beta board", "owner"} in report.board_access

      board = imported_board("Beta board", report.workspace_name)

      assert [%BoardUser{access: :owner, user_id: user_id}] =
               from(bu in BoardUser, where: bu.board_id == ^board.id) |> Repo.all()

      assert user_id == ctx.org_admin.id
    end

    test "a board whose access rows name no owner is owned by the importing org-admin", ctx do
      files =
        Map.update!(ctx.files, "board_users.json", fn rows ->
          Enum.reject(rows, &(&1["board_id"] == ctx.alpha.id and &1["access"] == "owner"))
        end)

      assert {:ok, report} = import_files(ctx, files)
      assert report.reattributed == 1

      board = imported_board("Alpha board", report.workspace_name)
      owner = Repo.get_by!(BoardUser, board_id: board.id, access: :owner)
      assert owner.user_id == ctx.org_admin.id
      # The other members keep their access.
      assert Repo.get_by!(BoardUser, board_id: board.id, user_id: ctx.guest.id).access ==
               :read_only
    end
  end

  describe "crafted values refuse cleanly instead of raising" do
    test "a board field_visibility value that is not true or false", ctx do
      for value <- ["x\u0000", %{"deep" => [1]}] do
        files =
          update_rows(
            ctx.files,
            :boards,
            &Map.put(&1, "field_visibility", %{"pitfalls" => value})
          )

        assert_refused(ctx, files, fn {:invalid_row, :boards, _ref, errors} ->
          errors == %{field_visibility: ["values must be true or false"]}
        end)
      end
    end

    test "a NUL byte in a goal's after_goal result or attempts", ctx do
      for field <- ["after_goal_result", "after_goal_attempts"] do
        value =
          if field == "after_goal_result",
            do: %{"out" => "a\u0000"},
            else: [%{"out" => "a\u0000"}]

        files = change_task(ctx.files, ctx.goal, %{field => value})

        assert_refused(ctx, files, fn {:invalid_row, :tasks, ref, errors} ->
          ref == ctx.goal.identifier and
            errors == %{String.to_existing_atom(field) => @not_storable}
        end)
      end
    end

    test "a comment agent name that is not a string", ctx do
      for name <- [%{"x" => 1}, [-1], 42] do
        files = update_rows(ctx.files, :comments, &Map.put(&1, "author_agent_name", name))

        assert_refused(ctx, files, fn {:invalid_row, :comments, _ref, errors} ->
          errors == %{author_agent_name: ["is invalid"]}
        end)
      end
    end

    test "a refused row is named by its name cut to 60 characters and its archive id", ctx do
      too_long = String.duplicate("é", 300)
      [first | _] = ctx.files[Serializer.file_name(:columns)]
      files = update_rows(ctx.files, :columns, &Map.put(&1, "name", too_long))

      assert {:error, {:invalid_row, :columns, ref, _errors}} = import_files(ctx, files)
      assert ref == ~s("#{String.duplicate("é", 60)}…", id #{first["id"]})
    end

    test "column and history names longer than their columns", ctx do
      too_long = String.duplicate("é", 256)
      files = update_rows(ctx.files, :columns, &Map.put(&1, "name", too_long))

      assert_refused(ctx, files, fn {:invalid_row, :columns, _ref, errors} ->
        errors == %{name: ["should be at most 255 character(s)"]}
      end)

      files =
        update_rows(ctx.files, :task_history, fn
          %{"type" => "move"} = row -> Map.put(row, "to_column", too_long)
          row -> row
        end)

      assert_refused(ctx, files, fn {:invalid_row, :task_history, _ref, errors} ->
        errors == %{to_column: ["should be at most 255 character(s)"]}
      end)
    end

    test "an archive user whose email is not a usable string has no account here", ctx do
      files =
        Map.update!(ctx.files, "users.json", fn rows ->
          Enum.map(rows, fn
            %{"id" => id} = row when id == ctx.outsider.id ->
              Map.put(row, "email", "x\u0000" <> row["email"])

            row ->
              row
          end) ++ [%{"id" => 987_654, "email" => %{"a" => 1}, "name" => "Odd"}]
        end)

      assert {:ok, report} = import_files(ctx, files)
      assert report.unmatched_users == []
      assert {:board_users, "board member an unknown user has no account here"} in report.skipped
    end
  end

  describe "repeated source ids" do
    test "two boards, columns, labels, tasks or users with one id are refused", ctx do
      before = table_counts()

      for entity <- [:boards, :columns, :labels, :tasks, :users] do
        [first | _] = rows = ctx.files[Serializer.file_name(entity)]
        files = Map.put(ctx.files, Serializer.file_name(entity), rows ++ [first])
        assert import_files(ctx, files) == {:error, {:duplicate_id, entity}}
      end

      assert table_counts() == before
    end

    test "comments and history rows may repeat an id, since nothing refers to them", ctx do
      [comment | _] = rows = ctx.files["comments.json"]
      files = Map.put(ctx.files, "comments.json", rows ++ [comment])

      assert {:ok, report} = import_files(ctx, files)
      assert report.counts.comments == length(rows) + 1
    end
  end

  describe "rows older versions wrote" do
    test "a comment longer than the cap is shortened to it and reported", ctx do
      max = TaskComment.content_max_length()
      long = String.duplicate("ab", max)

      files =
        update_rows(ctx.files, :comments, fn row -> Map.put(row, "content", long) end)

      assert {:ok, report} = import_files(ctx, files)
      assert report.counts.comments == length(files["comments.json"])

      assert {:comments,
              "comment on #{ctx.first.identifier}: shortened from #{2 * max} to #{max} characters"} in report.repaired

      comment = imported_comment(report.workspace_name)
      assert comment.content == String.slice(long, 0, max)
    end

    test "unknown required capabilities are dropped and reported", ctx do
      files =
        change_task(ctx.files, ctx.second, %{
          "required_capabilities" => ["pubsub_integration", "testing", "forms"]
        })

      assert {:ok, report} = import_files(ctx, files)

      assert report.repaired == [
               {:tasks, "task #{ctx.second.identifier}: dropped 2 unknown required capabilities"}
             ]

      task = imported_task(ctx.second.identifier, report.workspace_name)
      assert task.required_capabilities == ["testing"]
    end

    test "a clean archive reports no repairs", ctx do
      assert {:ok, %{repaired: []}} = import_files(ctx, ctx.files)
    end
  end

  describe "skipped members" do
    test "name the user and say whether their account is disabled or missing", ctx do
      from(u in User, where: u.id == ^ctx.guest.id)
      |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

      files =
        Map.update!(ctx.files, "users.json", fn rows ->
          Enum.map(rows, fn
            %{"id" => id} = row when id == ctx.member.id ->
              Map.put(row, "email", "gone-#{System.unique_integer([:positive])}@example.com")

            row ->
              row
          end)
        end)

      missing = Enum.find(files["users.json"], &(&1["id"] == ctx.member.id))["email"]

      assert {:ok, report} = import_files(ctx, files)
      assert report.disabled_users == [ctx.guest.email]
      assert report.unmatched_users == [missing]

      assert {:workspace_members, "member #{ctx.guest.email} has a disabled account here"} in report.skipped

      assert {:board_users, "board member #{ctx.guest.email} has a disabled account here"} in report.skipped

      assert {:workspace_members, "member #{missing} has no account here"} in report.skipped
    end
  end

  test "a clean archive still imports, history included", ctx do
    assert {:ok, report} = import_files(ctx, ctx.files)
    assert report.counts.tasks == 6
    assert report.reattributed == 0
    assert report.counts.task_history == length(ctx.files["task_history.json"])
    assert Repo.aggregate(TaskHistory, :count) >= report.counts.task_history
    assert row(ctx.files, :tasks, ctx.second.id)["identifier"] == ctx.second.identifier
  end

  # Tasks on the boards of the imported workspace named `workspace_name`.
  defp imported_tasks(workspace_name) do
    from(t in Task,
      join: c in assoc(t, :column),
      join: b in Board,
      on: b.id == c.board_id,
      join: w in Workspace,
      on: w.id == b.workspace_id,
      where: w.name == ^workspace_name
    )
  end

  defp imported_task(identifier, workspace_name) do
    workspace_name
    |> imported_tasks()
    |> where([t], t.identifier == ^identifier)
    |> Repo.one!()
  end

  defp imported_comment(workspace_name) do
    task_ids = workspace_name |> imported_tasks() |> select([t], t.id)
    from(tc in TaskComment, where: tc.task_id in subquery(task_ids)) |> Repo.one!()
  end

  defp imported_board(name, workspace_name) do
    from(b in Board,
      join: w in Workspace,
      on: w.id == b.workspace_id,
      where: b.name == ^name and w.name == ^workspace_name
    )
    |> Repo.one!()
  end
end
