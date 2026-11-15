defmodule Kanban.AuditStream.UniqueNameMigrationTest do
  # Not async: seeding duplicate names needs the unique name index dropped, and
  # DROP INDEX holds an ACCESS EXCLUSIVE lock on audit_stream_destinations until
  # this test's sandbox transaction rolls back.
  use Kanban.DataCase, async: false

  import Ecto.Query
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditStream.Destination
  alias Kanban.Repo

  @migration "priv/repo/migrations/20261115002500_unique_audit_stream_destination_names_ignoring_case.exs"
  @index "audit_stream_destinations_organization_id_lower_name_index"

  @migration_module Kanban.Repo.Migrations.UniqueAuditStreamDestinationNamesIgnoringCase

  # `mix test` runs ecto.migrate first, so on a fresh database the module is
  # already in memory; requiring the file again would redefine it with a
  # warning.
  setup_all do
    Code.ensure_loaded?(@migration_module) or Code.require_file(@migration)
    %{migration: @migration_module}
  end

  setup do
    Repo.query!("DROP INDEX #{@index}")
    %{organization: organization_fixture()}
  end

  defp run(migration), do: Enum.each(migration.dedupe_statements(), &Repo.query!/1)

  # With the index dropped the changeset's constraint mapping never fires, so
  # duplicates insert freely.
  defp destination(organization, name, inserted_at) do
    destination =
      %Destination{organization_id: organization.id}
      |> Destination.changeset(%{
        kind: "https",
        name: name,
        url: "https://siem.example.org/ingest",
        credential: "https-header-value-0123456789",
        settings: %{"format" => "ndjson", "header_name" => "X-Api-Key"}
      })
      |> Repo.insert!()

    Destination
    |> where([d], d.id == ^destination.id)
    |> Repo.update_all(set: [inserted_at: inserted_at])

    destination
  end

  defp reload(%Destination{id: id}), do: Repo.get!(Destination, id)
  defp name_of(destination), do: reload(destination).name

  defp snapshot do
    Destination
    |> select([d], {d.id, d.name, d.lock_version})
    |> order_by([d], d.id)
    |> Repo.all()
  end

  defp at(seconds), do: DateTime.add(~U[2026-01-01 00:00:00Z], seconds)

  test "renames later case-duplicates with the first free suffix, oldest keeps its name", %{
    migration: migration,
    organization: organization
  } do
    newest = destination(organization, "SIEM", at(20))
    oldest = destination(organization, "Siem", at(0))
    tied_low = destination(organization, "siem", at(10))
    tied_high = destination(organization, "Siem", at(10))

    run(migration)

    assert name_of(oldest) == "Siem"
    assert name_of(tied_low) == "siem (2)"
    assert name_of(tied_high) == "Siem (3)"
    assert name_of(newest) == "SIEM (4)"

    assert reload(oldest).lock_version == 1
    assert reload(newest).lock_version == 2
  end

  test "skips a suffix another destination already uses, ignoring case", %{
    migration: migration,
    organization: organization
  } do
    oldest = destination(organization, "Siem", at(0))
    taken = destination(organization, "SIEM (2)", at(5))
    later = destination(organization, "siem", at(10))

    run(migration)

    assert name_of(oldest) == "Siem"
    assert name_of(taken) == "SIEM (2)"
    assert name_of(later) == "siem (3)"
  end

  test "never compares or renames across Organizations", %{
    migration: migration,
    organization: organization
  } do
    here = destination(organization, "Siem", at(10))
    elsewhere = destination(organization_fixture(), "SIEM", at(0))

    run(migration)

    assert name_of(here) == "Siem"
    assert name_of(elsewhere) == "SIEM"
  end

  test "a renamed name stays within 80 characters", %{
    migration: migration,
    organization: organization
  } do
    long = String.duplicate("a", 80)
    destination(organization, long, at(0))
    later = destination(organization, String.upcase(long), at(10))

    run(migration)

    renamed = name_of(later)
    assert renamed == String.duplicate("A", 76) <> " (2)"
    assert String.length(renamed) == 80

    assert reload(later) |> Destination.changeset(%{name: renamed}) |> Map.get(:valid?)
  end

  test "running the dedupe twice changes nothing", %{
    migration: migration,
    organization: organization
  } do
    destination(organization, "Siem", at(0))
    destination(organization, "SIEM", at(10))
    destination(organization, "Ops", at(20))

    run(migration)
    after_first = snapshot()
    run(migration)

    assert snapshot() == after_first
  end

  test "running the dedupe on a table with no duplicates changes nothing", %{
    migration: migration,
    organization: organization
  } do
    destination(organization, "Siem", at(0))
    destination(organization, "Ops", at(10))
    before = snapshot()

    run(migration)

    assert snapshot() == before
  end

  test "the index builds after the dedupe and then refuses a case duplicate", %{
    migration: migration,
    organization: organization
  } do
    destination(organization, "Siem", at(0))
    destination(organization, "siem", at(10))

    run(migration)

    Repo.query!("""
    CREATE UNIQUE INDEX #{@index} ON audit_stream_destinations (organization_id, lower(name))
    """)

    assert {:error, changeset} =
             %Destination{organization_id: organization.id}
             |> Destination.changeset(%{
               kind: "https",
               name: "SIEM",
               url: "https://siem.example.org/ingest",
               credential: "https-header-value-0123456789",
               settings: %{"format" => "ndjson", "header_name" => "X-Api-Key"}
             })
             |> Repo.insert()

    assert errors_on(changeset)[:name] == ["has already been taken"]
  end
end
