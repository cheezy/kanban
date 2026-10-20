defmodule Kanban.AuditLog.ExportTest do
  # Calls Kanban.AuditLog.Export directly; test/kanban/audit_log_test.exs covers
  # the same functions through the Kanban.AuditLog delegates.
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Export

  @base ~U[2026-10-03 00:00:00.000000Z]

  defp insert_event!(action, seconds, attrs \\ %{}) do
    %AuditEvent{action: action, inserted_at: DateTime.add(@base, seconds), metadata: %{}}
    |> struct!(attrs)
    |> Repo.insert!()
  end

  defp json(filters, opts), do: filters |> Export.export_stream(:json, opts) |> Enum.join()

  describe "export_stream/3" do
    test "returns every matching row, newest first, across keyset batches" do
      for i <- 1..5, do: insert_event!("export_test", i)

      rows = [action: "export_test"] |> json(batch_size: 2) |> Jason.decode!()

      assert Enum.map(rows, & &1["inserted_at"]) ==
               for(i <- 5..1//-1, do: @base |> DateTime.add(i) |> DateTime.to_iso8601())
    end

    test ":max_rows is a TOTAL cap, not a batch size" do
      for i <- 1..5, do: insert_event!("export_test", i)

      assert [action: "export_test"]
             |> json(max_rows: 2, batch_size: 500)
             |> Jason.decode!()
             |> length() == 2

      assert [action: "export_test"]
             |> json(max_rows: 4, batch_size: 1)
             |> Jason.decode!()
             |> length() == 4
    end

    test ":redact_actors_outside strips an outside actor's identity" do
      organization = organization_fixture()
      outsider = user_fixture()

      insert_event!("export_test", 1, %{
        organization_id: organization.id,
        actor_user_id: outsider.id,
        actor_in_organization: false,
        ip: "203.0.113.7",
        metadata: %{"user_id" => outsider.id}
      })

      body = json([action: "export_test"], redact_actors_outside: organization.id)

      refute body =~ outsider.email
      refute body =~ "203.0.113.7"
      assert json([action: "export_test"], []) =~ outsider.email
    end

    test "rejects an unknown option" do
      assert_raise ArgumentError, fn -> Export.export_stream([], :json, max_row: 1) end
    end

    test "the Kanban.AuditLog delegate yields the same chunks" do
      for i <- 1..3, do: insert_event!("export_test", i)
      opts = [max_rows: 2, batch_size: 1]

      via_context = [action: "export_test"] |> AuditLog.export_stream(:csv, opts) |> Enum.join()
      direct = [action: "export_test"] |> Export.export_stream(:csv, opts) |> Enum.join()

      assert via_context == direct
    end
  end

  describe "export_truncated?/3" do
    test "is true only when the cap would omit a matching row" do
      for i <- 1..3, do: insert_event!("export_test", i)
      pending = %{action: "other", organization_id: nil, actor_user_id: nil, inserted_at: @base}

      refute Export.export_truncated?([action: "export_test"], 3, pending)
      assert Export.export_truncated?([action: "export_test"], 2, pending)

      assert Export.export_truncated?([action: "export_test"], 3, %{
               pending
               | action: "export_test"
             })

      assert AuditLog.export_truncated?([action: "export_test"], 2, pending) ==
               Export.export_truncated?([action: "export_test"], 2, pending)
    end
  end
end
