defmodule Kanban.Repo.Migrations.CreateWorkspaces do
  @moduledoc """
  Workspaces, their members, and the nullable `boards.workspace_id` (W2216).

  A workspace is either personal (`personal` true, no Organization, exactly one
  owner row) or an org workspace (`personal` false, an Organization, no owner
  row). The database enforces that split, not only `Kanban.Workspaces`:

    * `workspaces_personal_iff_no_organization` ties `personal` to a null
      `organization_id`, and `workspaces_personal_immutable` stops the flag
      from being flipped later, which would get around the member rules below.
    * `workspace_members_one_owner_per_workspace` and
      `workspace_members_one_owned_workspace_per_user` are partial unique
      indexes on owner rows.
    * The `workspace_members_enforce_workspace_kind` trigger rejects an owner
      row on an org workspace and a member or guest row on a personal
      workspace.

  Both triggers raise a `check_violation` that names a constraint, so Ecto's
  `check_constraint/3` turns each rejection into a changeset error.

  There is no plan, seat or billing column: whether an Organization pays will be
  derived from the workspace's `organization_id` (by `Kanban.Plans`, planned in
  W2398), never stored here. `boards.workspace_id` stays nullable until W2217
  has backfilled every board.
  """

  use Ecto.Migration

  def up do
    create table(:workspaces) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :personal, :boolean, null: false, default: false
      add :organization_id, references(:organizations, on_delete: :restrict)
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspaces, [:slug])
    create index(:workspaces, [:organization_id])

    create constraint(:workspaces, :workspaces_personal_iff_no_organization,
             check: "personal = (organization_id IS NULL)"
           )

    create table(:workspace_members) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_members, [:workspace_id, :user_id])
    create index(:workspace_members, [:user_id])

    create constraint(:workspace_members, :workspace_members_role_check,
             check: "role IN ('owner', 'member', 'guest')"
           )

    create unique_index(:workspace_members, [:workspace_id],
             where: "role = 'owner'",
             name: :workspace_members_one_owner_per_workspace
           )

    create unique_index(:workspace_members, [:user_id],
             where: "role = 'owner'",
             name: :workspace_members_one_owned_workspace_per_user
           )

    execute """
    CREATE FUNCTION workspace_members_enforce_workspace_kind() RETURNS trigger AS $$
    DECLARE
      ws_personal boolean;
    BEGIN
      SELECT personal INTO ws_personal FROM workspaces WHERE id = NEW.workspace_id;

      -- A missing workspace is left to the foreign key to report.
      IF NOT FOUND THEN
        RETURN NEW;
      END IF;

      IF NEW.role = 'owner' AND NOT ws_personal THEN
        RAISE EXCEPTION 'an org workspace cannot have an owner row'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'workspace_members_no_owner_on_org_workspace';
      END IF;

      IF NEW.role <> 'owner' AND ws_personal THEN
        RAISE EXCEPTION 'a personal workspace cannot have a member or guest row'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'workspace_members_no_member_on_personal_workspace';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER workspace_members_enforce_workspace_kind
    BEFORE INSERT OR UPDATE OF workspace_id, role ON workspace_members
    FOR EACH ROW EXECUTE FUNCTION workspace_members_enforce_workspace_kind()
    """

    execute """
    CREATE FUNCTION workspaces_personal_immutable() RETURNS trigger AS $$
    BEGIN
      IF NEW.personal IS DISTINCT FROM OLD.personal THEN
        RAISE EXCEPTION 'a workspace cannot change between personal and org'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'workspaces_personal_immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER workspaces_personal_immutable
    BEFORE UPDATE OF personal ON workspaces
    FOR EACH ROW EXECUTE FUNCTION workspaces_personal_immutable()
    """

    alter table(:boards) do
      add :workspace_id, references(:workspaces, on_delete: :restrict)
    end

    create index(:boards, [:workspace_id])
  end

  def down do
    drop index(:boards, [:workspace_id])

    alter table(:boards) do
      remove :workspace_id
    end

    # Dropping the tables drops their triggers with them.
    drop table(:workspace_members)
    drop table(:workspaces)

    execute "DROP FUNCTION IF EXISTS workspace_members_enforce_workspace_kind()"
    execute "DROP FUNCTION IF EXISTS workspaces_personal_immutable()"
  end
end
