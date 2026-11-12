defmodule Kanban.AuditStream.ReaderTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Export
  alias Kanban.AuditStream.Reader

  setup do
    organization = organization_fixture()
    other_organization = organization_fixture()
    member = user_fixture()
    organization_member_fixture(organization, member, :org_admin)
    site_admin = admin_fixture()

    %{
      organization: organization,
      other_organization: other_organization,
      member: member,
      site_admin: site_admin
    }
  end

  # A row written through Repo or AuditLog.event/2 carries the sandbox
  # transaction's own id, which is never below its own horizon (§7.2). Rows
  # from insert_raw!/2 carry a chosen small txid instead. Positive reads pass a
  # horizon just above the transaction's id, so both kinds are below it.
  defp own_txid do
    %{rows: [[txid]]} = Repo.query!("SELECT pg_current_xact_id()::text::bigint")
    txid
  end

  defp open_horizon, do: own_txid() + 1

  # `txid` can only be chosen with raw SQL: the schema never writes it.
  defp insert_raw!(organization, attrs \\ []) do
    actor = Keyword.get(attrs, :actor)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO audit_events
          (action, organization_id, actor_user_id, actor_in_organization, ip, metadata,
           inserted_at, txid)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        RETURNING id
        """,
        [
          Keyword.get(attrs, :action, "organization_updated"),
          organization && organization.id,
          actor && actor.id,
          Keyword.get(attrs, :in_organization),
          Keyword.get(attrs, :ip),
          Keyword.get(attrs, :metadata, %{}),
          Keyword.get(attrs, :at, ~N[2026-11-01 00:00:00.000000]),
          Keyword.get(attrs, :txid, 1)
        ]
      )

    id
  end

  defp ids(events), do: Enum.map(events, & &1.id)

  defp stored_events(organization),
    do: from(e in AuditEvent, where: e.organization_id == ^organization.id)

  defp read_all(organization, opts \\ []) do
    Reader.next_batch(organization.id, {0, 0}, Keyword.put_new(opts, :horizon, open_horizon()))
  end

  describe "next_batch/3 scoping and order" do
    test "returns one Organization's events in (txid, id) order", %{
      organization: organization,
      other_organization: other_organization
    } do
      first = insert_raw!(organization, txid: 3)
      second = insert_raw!(organization, txid: 1)
      third = insert_raw!(organization, txid: 2)
      fourth = insert_raw!(organization, txid: 1)
      insert_raw!(other_organization, txid: 1)
      insert_raw!(nil, txid: 1)

      events = read_all(organization)

      assert ids(events) == [second, fourth, third, first]
      assert Enum.map(events, & &1.txid) == [1, 1, 2, 3]
      assert Enum.all?(events, &(&1.organization_id == organization.id))
    end

    test "starts after the cursor pair, not after its txid or its id alone", %{
      organization: organization
    } do
      a = insert_raw!(organization, txid: 2)
      b = insert_raw!(organization, txid: 1)
      c = insert_raw!(organization, txid: 1)

      assert organization.id |> Reader.next_batch({1, b}, horizon: open_horizon()) |> ids() ==
               [c, a]
    end

    test "rows with txid 0 sort first, by id", %{organization: organization} do
      later = insert_raw!(organization, txid: 1)
      old_first = insert_raw!(organization, txid: 0)
      old_second = insert_raw!(organization, txid: 0)

      assert organization |> read_all() |> ids() == [old_first, old_second, later]
    end

    test "a cursor (h, 0) reads every row whose txid is h or above", %{organization: organization} do
      insert_raw!(organization, txid: 4)
      at_h = insert_raw!(organization, txid: 5)
      above = insert_raw!(organization, txid: 6)

      assert organization.id |> Reader.next_batch({5, 0}, horizon: open_horizon()) |> ids() ==
               [at_h, above]
    end

    test "rows with no organization_id are never returned", %{organization: organization} do
      insert_raw!(nil, txid: 1)

      assert read_all(organization) == []
    end

    test "an organization_id that is not an integer never reads", %{organization: organization} do
      insert_raw!(organization, txid: 1)

      # apply/3, so the compiler's type check does not reject the bad calls.
      for {fun, args} <- [
            next_batch: [nil, {0, 0}],
            read_range: [nil, {0, 0}, {9, 9}],
            waiting_counts: [nil, {0, 0}],
            next_batch: [Integer.to_string(organization.id), {0, 0}],
            next_batch: [organization.id, {nil, 0}],
            read_range: [organization.id, {0, 0}, {9, nil}]
          ] do
        error = assert_raise FunctionClauseError, fn -> apply(Reader, fun, args) end
        assert error.module == Reader
      end
    end

    test "empty Organization returns an empty batch", %{
      organization: organization,
      other_organization: other_organization
    } do
      insert_raw!(other_organization, txid: 1)

      assert read_all(organization) == []
      assert Reader.read_range(organization.id, {0, 0}, {100, 1_000_000_000}) == []

      assert Reader.waiting_counts(organization.id, {0, 0}, horizon: open_horizon()) == %{
               events_waiting: 0,
               events_above_horizon: 0,
               oldest_waiting_at: nil
             }
    end
  end

  describe "next_batch/3 horizon" do
    test "default horizon hides the test transaction's own rows", %{organization: organization} do
      :ok = AuditLog.event(:organization_updated, organization_id: organization.id)
      [own] = organization |> stored_events() |> Repo.all()
      final = insert_raw!(organization, txid: 1)

      assert organization.id |> Reader.next_batch({0, 0}) |> ids() == [final]
      assert organization.id |> Reader.next_batch({0, 0}, horizon: own_txid()) |> ids() == [final]

      assert organization.id |> Reader.next_batch({0, 0}, horizon: open_horizon()) |> ids() ==
               [final, own.id]
    end

    test "rows at or above :horizon are not returned", %{organization: organization} do
      below = insert_raw!(organization, txid: 5)
      insert_raw!(organization, txid: 10)

      assert organization.id |> Reader.next_batch({0, 0}, horizon: 10) |> ids() == [below]
    end
  end

  describe "next_batch/3 filters" do
    test "not_before filters by inserted_at only, whatever the txid", %{
      organization: organization
    } do
      insert_raw!(organization, txid: 9, at: ~N[2026-10-31 23:59:59.999999])
      at_start = insert_raw!(organization, txid: 1, at: ~N[2026-11-01 00:00:00.000000])
      later = insert_raw!(organization, txid: 2, at: ~N[2026-11-05 00:00:00.000000])

      assert organization
             |> read_all(not_before: ~U[2026-11-01 00:00:00.000000Z])
             |> ids() == [at_start, later]
    end

    test "excluded actions are left out, as strings or atoms", %{organization: organization} do
      kept = insert_raw!(organization, action: "organization_updated")
      insert_raw!(organization, action: "login_failed")
      insert_raw!(organization, action: "permission_denied")

      assert organization
             |> read_all(excluded_actions: ["login_failed", :permission_denied])
             |> ids() == [kept]
    end

    test "unknown or invalid options raise", %{organization: organization} do
      assert_raise ArgumentError, fn -> Reader.next_batch(organization.id, {0, 0}, limit: 5) end

      for bad <- [
            batch_size: 0,
            max_bytes: -1,
            size_fun: fn -> 1 end,
            horizon: "1",
            not_before: ~N[2026-11-01 00:00:00],
            excluded_actions: "login_failed",
            include_personal_data: nil
          ] do
        assert_raise ArgumentError, fn -> Reader.next_batch(organization.id, {0, 0}, [bad]) end
      end

      assert_raise ArgumentError, fn ->
        Reader.read_range(organization.id, {0, 0}, {1, 1}, batch_size: 2)
      end

      assert_raise ArgumentError, fn ->
        Reader.waiting_counts(organization.id, {0, 0}, max_bytes: 2)
      end
    end
  end

  describe "next_batch/3 batch_size and max_bytes limits" do
    test "batch_size defaults to 500", %{organization: organization} do
      Repo.query!(
        """
        INSERT INTO audit_events (action, organization_id, metadata, inserted_at, txid)
        SELECT 'organization_updated', $1, '{}', now(), 1 FROM generate_series(1, 501)
        """,
        [organization.id]
      )

      batch = read_all(organization)
      assert length(batch) == 500

      last = List.last(batch)

      assert organization.id
             |> Reader.next_batch({last.txid, last.id}, horizon: open_horizon())
             |> length() == 1
    end

    test "batch_size caps the batch", %{organization: organization} do
      first = insert_raw!(organization)
      second = insert_raw!(organization)
      insert_raw!(organization)

      assert organization |> read_all(batch_size: 2) |> ids() == [first, second]
    end

    test "max_bytes stops before an event would go over the limit", %{organization: organization} do
      events = for _ <- 1..4, do: insert_raw!(organization)
      size_fun = fn _event -> 100 end

      assert organization |> read_all(size_fun: size_fun, max_bytes: 250) |> ids() ==
               Enum.take(events, 2)

      assert organization |> read_all(size_fun: size_fun, max_bytes: 300) |> ids() ==
               Enum.take(events, 3)
    end

    test "a single event larger than max_bytes is still returned alone", %{
      organization: organization
    } do
      first = insert_raw!(organization)
      second = insert_raw!(organization)
      opts = [size_fun: fn _event -> 1_000 end, max_bytes: 10]

      assert organization |> read_all(opts) |> ids() == [first]

      assert organization.id
             |> Reader.next_batch({1, first}, [horizon: open_horizon()] ++ opts)
             |> ids() == [second]
    end

    test "the default size is the JSON row_map plus a separator, under 900_000 bytes", %{
      organization: organization
    } do
      big = String.duplicate("x", 400_000)
      events = for _ <- 1..3, do: insert_raw!(organization, metadata: %{"note" => big})

      batch = read_all(organization)
      assert ids(batch) == Enum.take(events, 2)

      sizes = Enum.map(batch, &(&1 |> Export.row_map() |> Jason.encode!() |> byte_size()))
      assert Enum.sum(sizes) + 2 <= 900_000
      assert Enum.sum(sizes) + 2 + hd(sizes) > 900_000
    end

    test "the default size counts exactly one separator per event", %{organization: organization} do
      for _ <- 1..3, do: insert_raw!(organization, metadata: %{"note" => "same size"})
      [first, second, _third] = read_all(organization)
      size = first |> Export.row_map() |> Jason.encode!() |> byte_size() |> Kernel.+(1)
      assert second |> Export.row_map() |> Jason.encode!() |> byte_size() |> Kernel.+(1) == size

      assert organization |> read_all(max_bytes: 2 * size) |> length() == 2
      assert organization |> read_all(max_bytes: 2 * size - 1) |> length() == 1
    end

    test "size_fun receives events as they will be sent", %{organization: organization} do
      insert_raw!(organization, ip: "203.0.113.24", metadata: %{"ip" => "203.0.113.24"})
      test_pid = self()

      size_fun = fn event ->
        send(test_pid, {:sized, event})
        1
      end

      read_all(organization, size_fun: size_fun, include_personal_data: false)

      assert_received {:sized, %AuditEvent{ip: nil, metadata: metadata}}
      assert metadata == %{}
    end
  end

  describe "read_range/4" do
    test "returns exactly the events between the two pairs inclusive", %{
      organization: organization
    } do
      [_r1, r2, r3, r4, _r5] = for txid <- 1..5, do: insert_raw!(organization, txid: txid)

      range = Reader.read_range(organization.id, {2, r2}, {4, r4})
      assert ids(range) == [r2, r3, r4]

      # Rows that arrive later sort after the range: a later id in the last
      # pair's transaction, and a later transaction.
      insert_raw!(organization, txid: 4)
      insert_raw!(organization, txid: 9)

      assert organization.id |> Reader.read_range({2, r2}, {4, r4}) |> ids() == [r2, r3, r4]
      assert Reader.read_range(organization.id, {4, r4}, {2, r2}) == []
    end

    test "applies the filters, redaction and personal-data removal", %{
      organization: organization,
      site_admin: site_admin,
      member: member
    } do
      outside =
        insert_raw!(organization,
          actor: site_admin,
          in_organization: false,
          ip: "198.51.100.7",
          metadata: %{"user_id" => site_admin.id, "email" => site_admin.email, "gate" => "g"}
        )

      inside =
        insert_raw!(organization,
          actor: member,
          in_organization: true,
          ip: "203.0.113.24",
          metadata: %{"details" => %{"email" => member.email, "kept" => 1}},
          at: ~N[2026-11-02 00:00:00.000000]
        )

      insert_raw!(organization, action: "login_failed")
      insert_raw!(organization, at: ~N[2026-10-01 00:00:00.000000])

      [redacted, stripped] =
        Reader.read_range(organization.id, {0, 0}, {1, inside},
          excluded_actions: ["login_failed"],
          not_before: ~U[2026-11-01 00:00:00.000000Z],
          include_personal_data: false
        )

      assert redacted.id == outside
      assert redacted.actor_redacted
      assert redacted.metadata == %{"gate" => "g"}
      assert is_nil(redacted.actor_user_id)

      assert stripped.id == inside
      assert stripped.ip == nil
      assert stripped.actor_user_id == member.id
      assert stripped.metadata == %{"details" => %{"kept" => 1}}
      assert Export.row_map(stripped)["actor_email"] == nil
    end
  end

  describe "waiting_counts/3" do
    test "reports waiting events, those above the horizon and the oldest waiting time", %{
      organization: organization
    } do
      cursor_id = insert_raw!(organization, txid: 5, at: ~N[2026-11-01 00:00:00.000000])
      insert_raw!(organization, txid: 10, at: ~N[2026-11-03 00:00:00.000000])
      insert_raw!(organization, txid: 15, at: ~N[2026-11-02 00:00:00.000000])

      assert Reader.waiting_counts(organization.id, {5, cursor_id}, horizon: 12) == %{
               events_waiting: 2,
               events_above_horizon: 1,
               oldest_waiting_at: ~U[2026-11-02 00:00:00.000000Z]
             }
    end

    test "a held horizon shows as waiting, never zero", %{organization: organization} do
      insert_raw!(organization, txid: 5)
      insert_raw!(organization, txid: 6)

      assert Reader.next_batch(organization.id, {0, 0}, horizon: 1) == []

      assert %{events_waiting: 2, events_above_horizon: 2, oldest_waiting_at: %DateTime{}} =
               Reader.waiting_counts(organization.id, {0, 0}, horizon: 1)
    end

    test "the default horizon counts the open transaction's rows as above it", %{
      organization: organization
    } do
      :ok = AuditLog.event(:organization_updated, organization_id: organization.id)
      insert_raw!(organization, txid: 1)

      assert %{events_waiting: 2, events_above_horizon: 1} =
               Reader.waiting_counts(organization.id, {0, 0})
    end

    test "applies not_before and exclusions", %{organization: organization} do
      insert_raw!(organization, at: ~N[2026-10-01 00:00:00.000000])
      insert_raw!(organization, action: "login_failed")
      insert_raw!(organization, txid: 2, at: ~N[2026-11-04 00:00:00.000000])

      assert Reader.waiting_counts(organization.id, {0, 0},
               horizon: open_horizon(),
               not_before: ~U[2026-11-01 00:00:00.000000Z],
               excluded_actions: [:login_failed],
               include_personal_data: false
             ) == %{
               events_waiting: 1,
               events_above_horizon: 0,
               oldest_waiting_at: ~U[2026-11-04 00:00:00.000000Z]
             }
    end
  end

  describe "next_waiting_at/3" do
    test "is the next sendable event's inserted_at in commit order, or nil", %{
      organization: organization,
      other_organization: other_organization
    } do
      insert_raw!(other_organization, txid: 1, at: ~N[2026-10-01 00:00:00.000000])
      assert Reader.next_waiting_at(organization.id, {0, 0}) == nil

      first = insert_raw!(organization, txid: 2, at: ~N[2026-11-02 00:00:00.000000])
      insert_raw!(organization, txid: 3, at: ~N[2026-11-01 00:00:00.000000])

      assert Reader.next_waiting_at(organization.id, {0, 0}) == ~U[2026-11-02 00:00:00.000000Z]

      assert Reader.next_waiting_at(organization.id, {2, first}) ==
               ~U[2026-11-01 00:00:00.000000Z]

      assert Reader.next_waiting_at(organization.id, {3, first + 1}) == nil
    end

    test "only events below the horizon count, and the filters apply", %{
      organization: organization
    } do
      insert_raw!(organization, txid: 5, action: "board_created")
      assert Reader.next_waiting_at(organization.id, {0, 0}, horizon: 5) == nil
      assert %DateTime{} = Reader.next_waiting_at(organization.id, {0, 0}, horizon: 6)

      assert Reader.next_waiting_at(organization.id, {0, 0}, excluded_actions: ["board_created"]) ==
               nil

      assert Reader.next_waiting_at(organization.id, {0, 0}, not_before: ~U[2026-11-02 00:00:00Z]) ==
               nil

      # The test transaction's own row is above the default horizon.
      AuditLog.event(:organization_updated, organization_id: organization.id)
      assert Reader.next_waiting_at(organization.id, {5, 1_000_000_000}) == nil

      assert_raise ArgumentError, fn ->
        Reader.next_waiting_at(organization.id, {0, 0}, batch_size: 1)
      end
    end
  end

  describe "redaction" do
    test "outside actor keys removed from metadata", %{
      organization: organization,
      site_admin: site_admin
    } do
      insert_raw!(organization,
        actor: site_admin,
        in_organization: false,
        ip: "198.51.100.7",
        metadata: %{
          "user_id" => site_admin.id,
          "email" => site_admin.email,
          "ip" => "198.51.100.7",
          "organization_id" => organization.id
        }
      )

      [event] = read_all(organization)

      for key <- ["user_id", "email", "ip"], do: refute(Map.has_key?(event.metadata, key))
      assert event.metadata == %{"organization_id" => organization.id}
      assert event.ip == nil
      assert event.actor_user == nil
      assert event.actor_user_id == nil
      assert event.actor_redacted
    end

    test "a member's event keeps the actor's identity", %{
      organization: organization,
      member: member
    } do
      insert_raw!(organization,
        actor: member,
        in_organization: true,
        ip: "203.0.113.24",
        metadata: %{"user_id" => member.id, "ip" => "203.0.113.24"}
      )

      [event] = read_all(organization)
      row = Export.row_map(event)

      assert row["actor_email"] == member.email
      assert row["ip"] == "203.0.113.24"
      assert event.metadata == %{"user_id" => member.id, "ip" => "203.0.113.24"}
      refute event.actor_redacted
    end

    test "rows written before actor_in_organization existed fall back to current membership",
         %{organization: organization, member: member, site_admin: site_admin} do
      kept = insert_raw!(organization, actor: member, metadata: %{"user_id" => member.id})
      insert_raw!(organization, actor: site_admin, metadata: %{"user_id" => site_admin.id})

      [inside, outside] = read_all(organization)

      assert inside.id == kept
      assert inside.actor_user_id == member.id
      refute inside.actor_redacted
      assert outside.actor_redacted
      assert outside.metadata == %{}
    end

    test "actor account deleted: actor_user_id falls back to metadata.user_id", %{
      organization: organization
    } do
      insert_raw!(organization, in_organization: true, metadata: %{"user_id" => 123})

      for include <- [true, false] do
        [event] = read_all(organization, include_personal_data: include)
        row = Export.row_map(event)

        assert row["actor_user_id"] == 123
        assert row["actor_email"] == nil
      end
    end
  end

  describe "personal data" do
    test "personal data off removes email and ip at every depth", %{
      organization: organization,
      member: member
    } do
      metadata = %{
        "user_id" => member.id,
        "email" => member.email,
        "ip" => "203.0.113.24",
        "details" => %{
          "ip" => "203.0.113.24",
          "email" => "x@example.com",
          "nested" => %{"email" => "y@example.com", "keep" => true},
          "keep" => "yes"
        },
        "attempts" => [
          %{"ip" => "198.51.100.1", "at" => "2026-11-01"},
          [%{"email" => "z@example.com"}],
          "plain"
        ]
      }

      insert_raw!(organization,
        actor: member,
        in_organization: true,
        ip: "203.0.113.24",
        metadata: metadata
      )

      [event] = read_all(organization, include_personal_data: false)

      assert event.metadata == %{
               "user_id" => member.id,
               "details" => %{"nested" => %{"keep" => true}, "keep" => "yes"},
               "attempts" => [%{"at" => "2026-11-01"}, [%{}], "plain"]
             }

      assert event.ip == nil
      assert event.actor_user_id == member.id
      assert event.actor_user.id == member.id
      assert event.actor_user.email == nil
      assert Export.row_map(event)["actor_email"] == nil

      [untouched] = read_all(organization)
      assert untouched.metadata == metadata
      assert untouched.ip == "203.0.113.24"
      assert untouched.actor_user.email == member.email
    end
  end

  describe "against the /org/audit viewer" do
    test "read back redacted like /org/audit", %{
      organization: organization,
      member: member,
      site_admin: site_admin
    } do
      for actor <- [member, site_admin] do
        :ok =
          AuditLog.event(:organization_updated,
            user_id: actor.id,
            organization_id: organization.id,
            ip: "203.0.113.24",
            email: actor.email
          )
      end

      assert organization |> stored_events() |> Repo.aggregate(:count) == 2

      streamed = read_all(organization)

      viewed =
        [organization_id: organization.id]
        |> AuditLog.list_events_page(redact_actors_outside: organization.id)
        |> Map.fetch!(:entries)
        |> Enum.sort_by(& &1.id)

      assert Enum.map(streamed, &Export.row_map/1) == Enum.map(viewed, &Export.row_map/1)

      [by_member, by_site_admin] = streamed
      assert Export.row_map(by_member)["actor_email"] == member.email
      assert by_site_admin.actor_redacted
      refute Map.has_key?(by_site_admin.metadata, "ip")
      refute Map.has_key?(by_site_admin.metadata, "email")
      assert by_site_admin.ip == nil
    end
  end
end
