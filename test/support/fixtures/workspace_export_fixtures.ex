defmodule Kanban.WorkspaceExportFixtures do
  @moduledoc """
  Test helpers for workspace exports and imports (W2222): an Organization
  with an org-admin, a member and a guest, a workspace seeded with every kind
  of exported row, a private export directory per test, and a reader for the
  written archive.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Kanban.AccountsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.LabelsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Boards
  alias Kanban.Boards.BoardUser
  alias Kanban.Labels.TaskLabel
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment

  @doc "An Organization, its org-admin, a member and a guest, and a workspace."
  def export_org_fixture do
    organization = organization_fixture()
    org_admin = user_fixture(%{name: "Ada Admin"})
    organization_member_fixture(organization, org_admin, :org_admin)
    member = user_fixture(%{name: "Mia Member"})
    organization_member_fixture(organization, member, :member)
    guest = user_fixture()
    organization_member_fixture(organization, guest, :member)

    workspace =
      org_workspace_fixture(organization, name: "Platform #{System.unique_integer([:positive])}")

    workspace_member_fixture(workspace, member, :member)
    workspace_member_fixture(workspace, guest, :guest)

    %{
      organization: organization,
      org_admin: org_admin,
      member: member,
      guest: guest,
      workspace: workspace
    }
  end

  @doc """
  Fills `ctx.workspace` with two boards: columns with WIP limits, a goal with
  two children (one depending on the other), a cross-board dependency, an
  archived duplicate, labels on a task, a unicode comment that mentions the
  org-admin, move history, and a board member outside the Organization.
  """
  def seed_workspace(ctx) do
    boards = seed_boards(ctx)
    goal_tasks = seed_goal_tasks(ctx, boards.todo)
    beta_task = seed_beta_task(boards.beta_column, goal_tasks.second)
    duplicates = seed_archived_duplicate(boards.todo)
    label = seed_move_and_label(boards, goal_tasks.first)
    seed_comment(ctx, boards.outsider, goal_tasks.first)

    ctx
    |> Map.merge(Map.take(boards, [:outsider, :alpha, :beta]))
    |> Map.merge(goal_tasks)
    |> Map.merge(duplicates)
    |> Map.merge(%{beta_task: beta_task, label: label})
  end

  # Two boards in the workspace, their access grants (one to a user outside
  # the Organization) and their columns.
  defp seed_boards(ctx) do
    outsider = user_fixture(%{name: "Otto Outsider"})

    {:ok, alpha} =
      Boards.create_board(ctx.member, %{name: "Alpha board"}, workspace: ctx.workspace)

    {:ok, beta} =
      Boards.create_ai_optimized_board(ctx.org_admin, %{name: "Beta board"},
        workspace: ctx.workspace
      )

    grant(alpha, outsider, :modify)
    grant(alpha, ctx.guest, :read_only)

    todo = column_fixture(alpha, %{name: "To do", wip_limit: 5})
    done = column_fixture(alpha, %{name: "Done", wip_limit: 0})
    beta_column = column_fixture(beta, %{name: "Backlog"})

    %{
      outsider: outsider,
      alpha: alpha,
      beta: beta,
      todo: todo,
      done: done,
      beta_column: beta_column
    }
  end

  # A goal with two children, the second depending on the first.
  defp seed_goal_tasks(ctx, todo) do
    {:ok, goal} =
      Tasks.create_task(todo, %{
        title: "Ship the export",
        type: :goal,
        created_by_id: ctx.member.id
      })

    {:ok, first} =
      Tasks.create_task(todo, %{
        title: "Write the serializer 日本語 ✓",
        description: String.duplicate("Ünïcode description. ", 3_000),
        parent_id: goal.id,
        assigned_to_id: ctx.member.id,
        key_files: [%{file_path: "lib/a.ex", note: "new", position: 0}],
        verification_steps: [
          %{step_type: "command", step_text: "mix test", expected_result: "pass", position: 0}
        ]
      })

    {:ok, second} =
      Tasks.create_task(todo, %{
        title: "Write the importer",
        parent_id: goal.id,
        dependencies: [first.identifier]
      })

    %{goal: goal, first: first, second: second}
  end

  # A task on the other board that depends on `second` (a cross-board dependency).
  defp seed_beta_task(beta_column, second) do
    {:ok, beta_task} = Tasks.create_task(beta_column, %{title: "Beta work"})

    {1, _} =
      from(t in Task, where: t.id == ^beta_task.id)
      |> Repo.update_all(set: [dependencies: [second.identifier]])

    beta_task
  end

  # An original task and a copy archived as its duplicate.
  defp seed_archived_duplicate(todo) do
    {:ok, original} = Tasks.create_task(todo, %{title: "Original"})
    {:ok, copy} = Tasks.create_task(todo, %{title: "Copy"})

    {:ok, _archived} =
      Tasks.archive_task(copy, %{archive_reason: :duplicate, duplicate_of_id: original.id})

    %{original: original, copy: copy}
  end

  # Moves `first` to Done (move history) and labels it. Returns the label.
  defp seed_move_and_label(boards, first) do
    {:ok, _moved} =
      Task
      |> Repo.get!(first.id)
      |> Tasks.move_task(boards.done, 0)

    label = label_fixture(boards.alpha, %{name: "backend", color: :blue})
    Repo.insert!(%TaskLabel{task_id: first.id, label_id: label.id})
    label
  end

  # A unicode comment by the outsider that mentions the org-admin.
  defp seed_comment(ctx, outsider, first) do
    %TaskComment{
      task_id: first.id,
      author_user_id: outsider.id,
      mentioned_user_ids: [ctx.org_admin.id]
    }
    |> TaskComment.changeset(%{content: "Looks good 🌍 — ça marche"})
    |> Repo.insert!()
  end

  @doc "Gives `user` `access` to `board`."
  def grant(board, user, access) do
    %BoardUser{}
    |> BoardUser.changeset(%{board_id: board.id, user_id: user.id, access: access})
    |> Repo.insert!()
  end

  @doc """
  Points `:export_dir` at a fresh directory for this test and removes it
  afterwards. Returns the directory.
  """
  def tmp_export_dir do
    dir =
      Path.join([
        System.tmp_dir!(),
        "stride_export_test",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    previous = Application.get_env(:kanban, :export_dir)
    Application.put_env(:kanban, :export_dir, dir)

    on_exit(fn ->
      Application.put_env(:kanban, :export_dir, previous)
      File.rm_rf(dir)
    end)

    Path.expand(dir)
  end

  @doc "Reads a written archive into a map of file name => decoded JSON."
  def read_archive(path) do
    {:ok, files} = path |> String.to_charlist() |> :zip.unzip([:memory])
    Map.new(files, fn {name, data} -> {List.to_string(name), Jason.decode!(data)} end)
  end

  @doc "Reads a written archive into a map of file name => raw bytes."
  def raw_archive(path) do
    {:ok, files} = path |> String.to_charlist() |> :zip.unzip([:memory])
    Map.new(files, fn {name, data} -> {List.to_string(name), data} end)
  end
end
