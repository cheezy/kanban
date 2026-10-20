defmodule Kanban.Workspaces.Export.Importer do
  @moduledoc """
  Restores a workspace export archive into this instance (W2222), for
  `mix kanban.import_workspace`.

  The archive becomes a **new** workspace of the Organization of the org-admin
  named by email. The archive never chooses or creates an Organization, and a
  personal workspace is never a target. Nothing is written unless:

    * the archive passes `Kanban.Workspaces.Export.Importer.Archive.read/1`
      (shape, size, a known `format_version`, consistent counts), and
    * the email belongs to an enabled org-admin.

  Everything is then written in one transaction, so an import either lands
  whole or not at all; a dry run does all the work and rolls it back.

  Every row goes through its schema's changeset — imported content is
  untrusted — but not through the context functions that broadcast, notify,
  emit telemetry or enforce WIP limits, since an import restores state rather
  than acting on a board. Source ids are never reused: every reference is
  remapped to the rows this import creates. Task identifiers and
  `dependencies` are kept verbatim, because identifiers are unique per board
  and each board is new. Users are matched by email and never created
  (`Kanban.Workspaces.Export.Importer.Users`): an unmatched user's
  attributions become empty and their memberships are skipped, and the report
  lists their emails. A disabled account is never matched. A matched user
  outside the Organization is never attributed either: their task, comment and
  history attributions are left empty and the report names them, so an
  archive cannot make imported rows name an account outside the
  Organization. A board whose owner is unmatched or not a member of the
  Organization is owned by the importing org-admin, as is a review whose
  reviewer is unmatched; both are counted as reattributed. Board access is
  given only to matched users who belong to the Organization — anyone else
  in the archive's board members is skipped and named in the report, to be
  re-invited — and the report lists every board access it gave. Workspace
  member and guest rows are kept only for matched users who belong to the
  Organization and are not its org-admins. In-progress tasks keep their claim
  timestamps.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns.Column
  alias Kanban.Labels.Label
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Export.Importer.Archive
  alias Kanban.Workspaces.Export.Importer.Tasks
  alias Kanban.Workspaces.Export.Importer.Users
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @roles %{"member" => :member, "guest" => :guest}
  @board_access ["read_only", "modify"]
  @timestamps ["inserted_at", "updated_at"]
  @name_max_length 100
  @max_name_attempts 50

  @type report :: %{
          dry_run: boolean(),
          workspace_name: String.t(),
          counts: %{atom() => non_neg_integer()},
          unmatched_users: [String.t()],
          skipped: [{atom(), String.t()}],
          reattributed: non_neg_integer(),
          board_access: [{String.t(), String.t(), String.t()}]
        }

  @doc """
  Imports the archive at `path` into a new workspace of the Organization of
  the org-admin with `org_admin_email`. Pass `dry_run: true` to check and
  count without writing.
  """
  @spec import_archive(String.t(), String.t(), keyword()) ::
          {:ok, report()} | {:error, term()}
  def import_archive(path, org_admin_email, opts \\ [])
      when is_binary(path) and is_binary(org_admin_email) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    with {:ok, archive} <- Archive.read(path),
         {:ok, admin, organization_id} <- resolve_admin(org_admin_email) do
      transact(archive, admin, organization_id, dry_run?)
    end
  end

  defp transact(archive, admin, organization_id, dry_run?) do
    fn -> run(archive, admin, organization_id, dry_run?) end
    |> Repo.transaction(timeout: :infinity)
    |> transaction_result()
  end

  defp transaction_result({:ok, report}), do: {:ok, %{report | dry_run: false}}
  defp transaction_result({:error, {:dry_run, report}}), do: {:ok, %{report | dry_run: true}}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp resolve_admin(email) do
    with %User{disabled_at: nil} = admin <- email |> String.trim() |> Accounts.get_user_by_email(),
         %OrganizationMember{role: :org_admin, organization_id: organization_id} <-
           Organizations.get_membership(admin) do
      {:ok, admin, organization_id}
    else
      _ -> {:error, :not_org_admin}
    end
  end

  defp run(%{manifest: manifest, rows: rows}, admin, organization_id, dry_run?) do
    ctx =
      %{
        admin: admin,
        organization_id: organization_id,
        rows: rows,
        skipped: [],
        reattributed: 0,
        granted: []
      }
      |> Users.match()
      |> create_workspace(manifest["workspace"]["name"])
      |> insert_members()
      |> insert_boards()
      |> insert_board_users()
      |> insert_columns()
      |> insert_labels()
      |> Tasks.import_all()

    report = %{
      dry_run: dry_run?,
      workspace_name: ctx.workspace.name,
      counts: ctx.counts,
      unmatched_users: ctx.unmatched_users,
      skipped: Enum.reverse(ctx.skipped),
      reattributed: ctx.reattributed,
      board_access: Enum.reverse(ctx.granted)
    }

    if dry_run?, do: Repo.rollback({:dry_run, report}), else: report
  end

  @doc false
  # Maps a source user id to the local user id, or nil when unmatched.
  def user(ctx, source_id), do: Users.user(ctx, source_id)

  defp create_workspace(ctx, name) do
    name = free_name(ctx.organization_id, name)

    case Workspaces.create_org_workspace(%{name: name}, ctx.admin) do
      {:ok, workspace} -> Map.put(ctx, :workspace, workspace)
      {:error, reason} -> fail(:workspace, name, reason)
    end
  end

  # The archive's name, else "<name> (imported)", "<name> (imported 2)", …
  # Checked before inserting: a unique violation would abort the transaction.
  defp free_name(organization_id, name) do
    base = name |> to_string() |> String.trim() |> String.slice(0, @name_max_length - 16)
    base = if base == "", do: "Imported workspace", else: base

    [base, "#{base} (imported)" | Enum.map(2..@max_name_attempts, &"#{base} (imported #{&1})")]
    |> Enum.find(base, &(not name_taken?(organization_id, &1)))
  end

  defp name_taken?(organization_id, name) do
    lowered = String.downcase(name)

    query =
      from w in Workspace,
        where: w.organization_id == ^organization_id and is_nil(w.archived_at),
        where: fragment("lower(?)", w.name) == ^lowered

    Repo.exists?(query)
  end

  defp insert_members(ctx) do
    {count, ctx} =
      ctx.rows.workspace_members
      |> Enum.uniq_by(& &1["user_id"])
      |> Enum.reduce({0, ctx}, &insert_member/2)

    put_count(ctx, :workspace_members, count)
  end

  defp insert_member(row, {count, ctx}) do
    case member_target(ctx, row) do
      {:ok, user_id, role} ->
        insert_workspace_member(ctx.workspace.id, user_id, role, row)
        {count + 1, ctx}

      {:skip, reason} ->
        {count, skip(ctx, :workspace_members, reason)}
    end
  end

  defp insert_workspace_member(workspace_id, user_id, role, row) do
    workspace_id
    |> WorkspaceMember.changeset(user_id, role)
    |> cast_timestamps(row)
    |> insert!(:workspace_members, row["user_id"])
  end

  defp member_target(ctx, row) do
    user_id = user(ctx, row["user_id"])
    role = Map.get(@roles, row["role"])
    user = user_id && %User{id: user_id}

    cond do
      is_nil(user_id) ->
        {:skip, "member user not found on this instance"}

      is_nil(role) ->
        {:skip, "unknown member role"}

      not Organizations.member?(user, ctx.organization_id) ->
        {:skip, "user is not in the Organization"}

      Organizations.org_admin?(user, ctx.organization_id) ->
        {:skip, "user is an org-admin"}

      true ->
        {:ok, user_id, role}
    end
  end

  defp insert_boards(ctx) do
    inserted = Enum.map(ctx.rows.boards, &insert_board(&1, ctx.workspace.id))
    boards = board_ids(inserted)
    names = board_names(inserted)

    ctx
    |> Map.put(:boards, boards)
    |> Map.put(:board_names, names)
    |> put_count(:boards, map_size(boards))
  end

  defp board_ids(inserted),
    do: Map.new(inserted, fn {source_id, board} -> {source_id, board.id} end)

  defp board_names(inserted),
    do: Map.new(inserted, fn {_source_id, board} -> {board.id, board.name} end)

  defp insert_board(row, workspace_id) do
    attrs = row |> Map.take(["name", "description", "field_visibility", "read_only"]) |> compact()

    board =
      %Board{workspace_id: workspace_id}
      |> Board.owner_changeset(attrs)
      |> Ecto.Changeset.change(ai_optimized_board: row["ai_optimized_board"] == true)
      |> cast_timestamps(row)
      |> insert!(:boards, row["name"])

    {row["id"], board}
  end

  defp insert_board_users(ctx) do
    {count, ctx} =
      ctx.rows.board_users
      |> Enum.group_by(& &1["board_id"])
      |> Enum.reduce({0, ctx}, &insert_board_group/2)

    put_count(ctx, :board_users, count)
  end

  defp insert_board_group({source_board_id, rows}, {count, ctx}) do
    case Map.fetch(ctx.boards, source_board_id) do
      {:ok, board_id} ->
        {added, ctx} = insert_board_members(ctx, board_id, rows)
        {count + added, ctx}

      :error ->
        {count, skip(ctx, :board_users, "board not in the archive")}
    end
  end

  # The owner first — the source owner when matched and in the Organization,
  # else the importing org-admin — then every other matched Organization
  # member, once each.
  defp insert_board_members(ctx, board_id, rows) do
    {owners, others} = Enum.split_with(rows, &(&1["access"] == "owner"))
    acc = insert_first_owner(ctx, board_id, owners)
    {_seen, count, ctx} = Enum.reduce(others, acc, &insert_other_member(&1, &2, board_id))
    {count, ctx}
  end

  defp insert_first_owner(ctx, board_id, [owner | _]), do: insert_owner(ctx, board_id, owner)
  defp insert_first_owner(ctx, _board_id, []), do: {MapSet.new(), 0, ctx}

  defp insert_other_member(row, {seen, count, ctx} = acc, board_id) do
    user_id = user(ctx, row["user_id"])

    case other_member_action(ctx, seen, row, user_id) do
      {:skip, reason} -> {seen, count, skip(ctx, :board_users, reason)}
      :ignore -> acc
      :insert -> add_other_member(acc, board_id, user_id, row)
    end
  end

  defp add_other_member({seen, count, ctx}, board_id, user_id, row) do
    ctx = insert_board_user(ctx, board_id, user_id, row["access"], row)
    {MapSet.put(seen, user_id), count + 1, ctx}
  end

  defp other_member_action(ctx, seen, row, user_id) do
    cond do
      is_nil(user_id) -> {:skip, "board member not found on this instance"}
      MapSet.member?(seen, user_id) or row["access"] not in @board_access -> :ignore
      not org_member?(ctx, user_id) -> {:skip, outside_reason(ctx, row)}
      true -> :insert
    end
  end

  defp insert_owner(ctx, board_id, row) do
    user_id = user(ctx, row["user_id"])

    {user_id, ctx} =
      if user_id && org_member?(ctx, user_id),
        do: {user_id, ctx},
        else: {ctx.admin.id, Map.update!(ctx, :reattributed, &(&1 + 1))}

    ctx = insert_board_user(ctx, board_id, user_id, "owner", row)
    {MapSet.new([user_id]), 1, ctx}
  end

  # Board access is never given to someone outside the importing
  # Organization: a crafted archive could otherwise name any local account.
  defp org_member?(ctx, user_id),
    do: Organizations.member?(%User{id: user_id}, ctx.organization_id)

  defp outside_reason(ctx, row),
    do: "board member #{Map.get(ctx.emails, row["user_id"])} is not in the Organization"

  defp insert_board_user(ctx, board_id, user_id, access, row) do
    %BoardUser{}
    |> BoardUser.changeset(%{board_id: board_id, user_id: user_id, access: access})
    |> cast_timestamps(row)
    |> insert!(:board_users, board_id)

    email = if user_id == ctx.admin.id, do: ctx.admin.email, else: email_of(ctx, user_id)
    %{ctx | granted: [{email, Map.get(ctx.board_names, board_id), access} | ctx.granted]}
  end

  defp email_of(ctx, user_id) do
    Enum.find_value(ctx.users, fn {source_id, local_id} ->
      if local_id == user_id, do: Map.get(ctx.emails, source_id)
    end)
  end

  defp insert_columns(ctx),
    do: insert_board_rows(ctx, :columns, Column, ["name", "position", "wip_limit"])

  defp insert_labels(ctx), do: insert_board_rows(ctx, :labels, Label, ["name", "color"])

  defp insert_board_rows(ctx, entity, schema, fields) do
    {map, ctx} =
      ctx.rows
      |> Map.fetch!(entity)
      |> Enum.reduce({%{}, ctx}, &insert_board_row(&1, &2, entity, schema, fields))

    ctx |> Map.put(entity, map) |> put_count(entity, map_size(map))
  end

  defp insert_board_row(row, {map, ctx}, entity, schema, fields) do
    case Map.fetch(ctx.boards, row["board_id"]) do
      {:ok, board_id} ->
        record =
          schema
          |> struct(board_id: board_id)
          |> schema.changeset(Map.take(row, fields))
          |> cast_timestamps(row)
          |> insert!(entity, row["name"])

        {Map.put(map, row["id"], record.id), ctx}

      :error ->
        {map, skip(ctx, entity, "board not in the archive")}
    end
  end

  @doc false
  def cast_timestamps(changeset, row, fields \\ @timestamps) do
    Ecto.Changeset.cast(
      changeset,
      Map.take(row, fields),
      Enum.map(fields, &String.to_existing_atom/1)
    )
  end

  @doc false
  # Inserts or rolls the whole import back, naming the row that failed.
  def insert!(changeset, entity, ref) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, reason} -> fail(entity, ref, reason)
    end
  end

  @doc false
  def fail(entity, ref, %Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", fn _ -> interpolation(value) end)
        end)
      end)

    Repo.rollback({:invalid_row, entity, to_string(ref), errors})
  end

  def fail(entity, ref, reason), do: Repo.rollback({:invalid_row, entity, to_string(ref), reason})

  defp interpolation(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: to_string(value)

  defp interpolation(value), do: inspect(value)

  @doc false
  def skip(ctx, entity, reason), do: %{ctx | skipped: [{entity, reason} | ctx.skipped]}

  @doc false
  def put_count(ctx, entity, count), do: %{ctx | counts: Map.put(ctx.counts, entity, count)}

  defp compact(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
