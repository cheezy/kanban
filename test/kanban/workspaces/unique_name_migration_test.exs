defmodule Kanban.Workspaces.UniqueNameMigrationTest do
  # Not async: seeding duplicate names needs the unique name index dropped, and
  # DROP INDEX holds an ACCESS EXCLUSIVE lock on workspaces until this test's
  # sandbox transaction rolls back.
  use Kanban.DataCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace

  @migration "priv/repo/migrations/20261019003700_unique_workspace_names_per_organization.exs"
  @index "workspaces_organization_id_lower_name_index"

  setup_all do
    [{migration, _bytecode}] = Code.require_file(@migration)
    %{migration: migration}
  end

  setup do
    Repo.query!("DROP INDEX #{@index}")
    %{organization: organization_fixture()}
  end

  defp run(migration), do: Enum.each(migration.dedupe_statements(), &Repo.query!/1)

  # With the index dropped the changeset's constraint mapping never fires, so
  # the fixture inserts duplicates freely.
  defp workspace(organization, name, inserted_at, attrs \\ %{}) do
    workspace = org_workspace_fixture(organization, Map.put(attrs, :name, name))

    Workspace
    |> where([w], w.id == ^workspace.id)
    |> Repo.update_all(set: [inserted_at: inserted_at])

    workspace
  end

  defp name_of(%Workspace{id: id}), do: Repo.get!(Workspace, id).name

  defp snapshot do
    Workspace |> select([w], {w.id, w.name}) |> order_by([w], w.id) |> Repo.all()
  end

  defp at(seconds), do: DateTime.add(~U[2026-01-01 00:00:00Z], seconds)

  test "keeps the oldest name and numbers later duplicates by age", %{
    migration: migration,
    organization: organization
  } do
    newest = workspace(organization, "DESIGN", at(20))
    oldest = workspace(organization, "Design", at(0))
    tied_low = workspace(organization, "design", at(10))
    tied_high = workspace(organization, "Design", at(10))

    run(migration)

    assert name_of(oldest) == "Design"
    assert name_of(tied_low) == "design (2)"
    assert name_of(tied_high) == "Design (3)"
    assert name_of(newest) == "DESIGN (4)"
  end

  test "skips a suffix a live workspace already uses", %{
    migration: migration,
    organization: organization
  } do
    oldest = workspace(organization, "Design", at(0))
    taken = workspace(organization, "design (2)", at(5))
    later = workspace(organization, "Design", at(10))

    run(migration)

    assert name_of(oldest) == "Design"
    assert name_of(taken) == "design (2)"
    assert name_of(later) == "Design (3)"
  end

  test "leaves archived, personal and other Organizations' workspaces alone", %{
    migration: migration,
    organization: organization
  } do
    archived = workspace(organization, "Design", at(0), %{archived_at: at(1)})
    live = workspace(organization, "design", at(5))
    elsewhere = workspace(organization_fixture(), "Design", at(10))
    personal = for _ <- 1..2, do: user_fixture() |> Workspaces.get_personal_workspace()

    run(migration)

    assert name_of(archived) == "Design"
    assert name_of(live) == "design"
    assert name_of(elsewhere) == "Design"
    assert Enum.map(personal, &name_of/1) == ["Personal", "Personal"]
  end

  test "keeps every renamed name within the 100 characters the changeset allows", %{
    migration: migration,
    organization: organization
  } do
    long = String.duplicate("a", 100)
    workspace(organization, long, at(0))
    later = workspace(organization, long, at(10))

    run(migration)

    renamed = name_of(later)
    assert renamed == String.duplicate("a", 96) <> " (2)"
    assert Workspace.create_changeset(%{name: renamed}, false, organization.id).valid?
  end

  test "is a no-op on a second run", %{migration: migration, organization: organization} do
    workspace(organization, "Design", at(0))
    workspace(organization, "Design", at(10))
    workspace(organization, "Ops", at(20))

    run(migration)
    after_first = snapshot()
    run(migration)

    assert snapshot() == after_first
  end

  test "the index builds after the dedupe and then refuses a duplicate", %{
    migration: migration,
    organization: organization
  } do
    workspace(organization, "Design", at(0))
    workspace(organization, "design", at(10))

    run(migration)

    Repo.query!("""
    CREATE UNIQUE INDEX #{@index} ON workspaces (organization_id, lower(name))
    WHERE personal = false AND archived_at IS NULL
    """)

    assert {:error, changeset} =
             %{name: "DESIGN"}
             |> Workspace.create_changeset(false, organization.id)
             |> Repo.insert()

    assert errors_on(changeset) == %{name: ["has already been taken"]}
  end
end
