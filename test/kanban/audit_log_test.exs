defmodule Kanban.AuditLogTest do
  # async: false because two tests lower the global Logger level to capture the
  # :info audit line (the suite otherwise runs at :warning). DataCase, because
  # every event/2 call now also inserts an audit_events row.
  use Kanban.DataCase, async: false

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Filters
  alias Kanban.AuditLog.Hardening
  alias Kanban.AuditLog.Hardening.Purge
  alias Kanban.AuditLog.Query

  setup do
    original = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original) end)
    :ok
  end

  defp attach(action) do
    test_pid = self()
    event = [:kanban, :audit, action]
    handler_id = "audit-test-#{action}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {:audit, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "emits a telemetry event with count and sanitized metadata" do
    attach(:login_failed)

    AuditLog.event(:login_failed, email: "a@example.com", ip: {203, 0, 113, 5})

    assert_receive {:audit, %{count: 1}, metadata}
    assert metadata.email == "a@example.com"
    assert metadata.ip == "203.0.113.5"
  end

  test "formats IPv6 tuples to strings" do
    attach(:api_token_auth_failed)

    AuditLog.event(:api_token_auth_failed,
      ip: {8193, 3512, 0, 0, 0, 0, 0, 1},
      reason: "not_found"
    )

    assert_receive {:audit, _m, metadata}
    assert metadata.ip == "2001:db8::1"
    assert metadata.reason == "not_found"
  end

  test "drops sensitive keys before emitting" do
    attach(:login_failed)

    AuditLog.event(:login_failed,
      email: "a@example.com",
      password: "hunter2",
      token: "raw-secret-token"
    )

    assert_receive {:audit, _m, metadata}
    assert metadata.email == "a@example.com"
    refute Map.has_key?(metadata, :password)
    refute Map.has_key?(metadata, :token)
  end

  test "drops credential-shaped keys the exact-match list never anticipated (D159)" do
    attach(:password_reset_requested)

    AuditLog.event(:password_reset_requested,
      user_id: 7,
      reset_token: "raw-reset-token",
      api_key: "raw-api-key",
      refresh_token: "raw-refresh",
      session_token: "raw-session",
      otp_secret: "123456"
    )

    assert_receive {:audit, _m, metadata}
    # The row id survives; every credential-shaped key is redacted.
    assert metadata.user_id == 7
    refute Map.has_key?(metadata, :reset_token)
    refute Map.has_key?(metadata, :api_key)
    refute Map.has_key?(metadata, :refresh_token)
    refute Map.has_key?(metadata, :session_token)
    refute Map.has_key?(metadata, :otp_secret)
  end

  test "keeps benign *_id keys even when they contain a sensitive substring (D159)" do
    attach(:api_token_created)

    AuditLog.event(:api_token_created, user_id: 1, board_id: 2, token_id: 3)

    assert_receive {:audit, _m, metadata}
    assert metadata.user_id == 1
    assert metadata.board_id == 2
    # token_id is a row id, not the token value, so it is not redacted.
    assert metadata.token_id == 3
  end

  test "writes a structured security_audit log line without interpolating values" do
    log =
      capture_log(fn ->
        AuditLog.event(:sudo_mode_entered, user_id: 42)
      end)

    # user_id 42 has no users row, so the insert fails the actor foreign key and
    # is retried once with a nil actor: the row is stored and no persist-failure
    # line is logged. The assertion stays pinned to the info line because other
    # persist failures are logged as "security_audit_persist_failed" (action and
    # exception type only, never values), which a bare substring would match.
    assert log =~ "[info] security_audit\n"
    refute log =~ "security_audit_persist_failed"
  end

  test "sensitive values never reach the log output" do
    Logger.put_process_level(self(), :info)
    on_exit(fn -> Logger.delete_process_level(self()) end)

    log =
      capture_log([level: :info], fn ->
        AuditLog.event(:login_failed, email: "a@example.com", password: "hunter2")
      end)

    refute log =~ "hunter2"
  end

  defmodule OpaqueStruct do
    @moduledoc false
    defstruct [:secret_value]
  end

  defmodule ExitingStruct do
    @moduledoc false
    defstruct []

    defimpl String.Chars do
      def to_string(_struct), do: exit(:boom)
    end
  end

  defp only_event! do
    assert [event] = Repo.all(AuditEvent)
    event
  end

  describe "persistence" do
    test "event/2 inserts exactly one row with the action, actor and sanitized metadata" do
      user = user_fixture()

      assert :ok = AuditLog.event(:sudo_mode_entered, user_id: user.id, board_id: 9)

      event = only_event!()
      assert event.action == "sudo_mode_entered"
      assert event.actor_user_id == user.id
      assert event.metadata == %{"user_id" => user.id, "board_id" => 9}
      assert %DateTime{} = event.inserted_at
    end

    test "credential-shaped keys never reach the stored metadata, *_id keys do" do
      user = user_fixture()

      AuditLog.event(:password_reset_requested,
        user_id: user.id,
        token_id: 3,
        password: "hunter2",
        reset_token: "raw-reset-token",
        api_key: "raw-api-key"
      )

      event = only_event!()
      assert event.metadata == %{"user_id" => user.id, "token_id" => 3}
      refute inspect(event) =~ "hunter2"
      refute inspect(event) =~ "raw-reset-token"
      refute inspect(event) =~ "raw-api-key"
    end

    test "IP tuples persist as formatted strings in the ip column" do
      AuditLog.event(:login_failed, email: "a@example.com", ip: {203, 0, 113, 5})
      AuditLog.event(:login_failed, email: "b@example.com", ip: {8193, 3512, 0, 0, 0, 0, 0, 1})

      AuditLog.event(:login_failed, email: "c@example.com", ip: {999, 0, 0, 1})

      ips = AuditLog.list_events([], order: :asc) |> Enum.map(& &1.ip)
      assert ips == ["203.0.113.5", "2001:db8::1", "unknown"]
    end

    test "string IPs are stored normalized when they parse and as unknown when not" do
      AuditLog.event(:login_failed, email: "a@example.com", ip: "203.0.113.5")
      AuditLog.event(:login_failed, email: "b@example.com", ip: " 2001:DB8::1 ")
      AuditLog.event(:login_failed, email: "c@example.com", ip: "=tw7+1")
      AuditLog.event(:login_failed, email: "d@example.com", ip: "")
      AuditLog.event(:login_failed, email: "e@example.com", ip: String.duplicate("1", 300))

      events = AuditLog.list_events([], order: :asc)

      assert Enum.map(events, & &1.ip) ==
               ["203.0.113.5", "2001:db8::1", "unknown", "unknown", "unknown"]

      # The value as given is still kept in the metadata.
      assert Enum.at(events, 2).metadata["ip"] == "=tw7+1"
    end

    test "non-JSON-safe values are stringified instead of raising" do
      pid = self()

      assert :ok =
               AuditLog.event(:odd_values,
                 tuple: {:a, 1},
                 pid: pid,
                 ref: make_ref(),
                 atom: :some_atom,
                 uri: URI.parse("https://example.com/x"),
                 opaque: %OpaqueStruct{secret_value: "do-not-store"},
                 nested: %{level: [:x, {1, 2}], password: "nested-secret"},
                 unusual: %{{:a, 1} => "tuple-keyed", 5 => "integer-keyed"},
                 opts: [mode: :fast, api_token: "kw-secret"],
                 improper: [1 | 2],
                 date: ~D[2026-10-06],
                 fun: &String.upcase/1,
                 deep: %{"inner" => [%{api_key: "deep-secret", kept: 1}]},
                 with_nul: "a\0b",
                 invalid_utf8: <<0xFF, 0xFE>>
               )

      metadata = only_event!().metadata
      assert metadata["tuple"] == "{:a, 1}"
      assert metadata["pid"] == inspect(pid)
      assert metadata["ref"] =~ "#Reference<"
      assert metadata["atom"] == "some_atom"
      assert metadata["uri"] == "https://example.com/x"
      assert metadata["opaque"] == "%Kanban.AuditLogTest.OpaqueStruct{}"
      assert metadata["nested"] == %{"level" => ["x", "{1, 2}"]}
      assert metadata["unusual"] == %{"{:a, 1}" => "tuple-keyed", "5" => "integer-keyed"}
      assert metadata["opts"] == %{"mode" => "fast"}
      assert metadata["improper"] == "[1 | 2]"
      assert metadata["date"] == "2026-10-06"
      assert metadata["fun"] == "&String.upcase/1"
      assert metadata["deep"] == %{"inner" => [%{"kept" => 1}]}
      assert metadata["with_nul"] == "a\uFFFDb"
      assert metadata["invalid_utf8"] == "<<255, 254>>"
      refute inspect(metadata) =~ "secret"
    end

    test "very long string values are truncated" do
      AuditLog.event(:login_failed, email: String.duplicate("a", 10_000))

      assert String.length(only_event!().metadata["email"]) == 2_000
    end

    test "an empty keyword list stores a row with empty metadata and no actor" do
      assert :ok = AuditLog.event(:heartbeat, [])

      event = only_event!()
      assert event.metadata == %{}
      assert event.actor_user_id == nil
      assert event.ip == nil
    end

    test "a nil user_id (anonymous event) stores a nil actor" do
      AuditLog.event(:login_failed, user_id: nil, email: "anon@example.com")

      assert only_event!().actor_user_id == nil
    end
  end

  describe "failure handling" do
    test "an unknown actor inside a caller's transaction still stores the row and keeps the transaction" do
      user = user_fixture()

      assert {:ok, :committed} =
               Repo.transact(fn ->
                 assert :ok = AuditLog.event(:ghost_actor, user_id: 2_000_000_000)
                 assert :ok = AuditLog.event(:real_actor, user_id: user.id)
                 {:ok, :committed}
               end)

      assert [ghost, real] = AuditLog.list_events([], order: :asc)
      assert ghost.action == "ghost_actor"
      assert ghost.actor_user_id == nil
      assert ghost.metadata == %{"user_id" => 2_000_000_000}
      assert real.actor_user_id == user.id
    end

    test "an unknown actor outside a transaction still stores the row" do
      assert :ok = AuditLog.event(:ghost_actor, user_id: 2_000_000_000, board_id: 4)

      event = only_event!()
      assert event.actor_user_id == nil
      assert event.metadata == %{"user_id" => 2_000_000_000, "board_id" => 4}
    end

    test "an event the changeset rejects is logged by error key, not stored" do
      log =
        capture_log([level: :error], fn ->
          assert :ok = AuditLog.event(:"", email: "rejected@example.com")
        end)

      assert log =~ "reason={:invalid, [:action]}"
      refute log =~ "rejected@example.com"
      assert Repo.all(AuditEvent) == []
    end

    test "an exit while building the row is caught and logged" do
      log =
        capture_log([level: :error], fn ->
          assert :ok = AuditLog.event(:exits, value: %ExitingStruct{})
        end)

      assert log =~ "security_audit_persist_failed action=exits reason=:exit"
      assert Repo.all(AuditEvent) == []
    end

    test "an event inside a transaction that later rolls back leaves no row" do
      assert {:error, :rolled_back} =
               Repo.transact(fn ->
                 AuditLog.event(:login_failed, email: "a@example.com")
                 # The row is written inside the caller's transaction...
                 assert Repo.aggregate(AuditEvent, :count) == 1
                 {:error, :rolled_back}
               end)

      # ...so it follows that transaction's outcome.

      assert Repo.all(AuditEvent) == []
    end

    test "if the insert fails event/2 logs an error, never the values, and still returns :ok" do
      Repo.transact(fn ->
        # Poison the transaction so the audit insert cannot succeed.
        assert {:error, _} = Repo.query("SELECT 1 / 0")

        log =
          capture_log([level: :error], fn ->
            assert :ok = AuditLog.event(:login_failed, email: "leak-check@example.com")
          end)

        assert log =~ "security_audit_persist_failed"
        refute log =~ "leak-check@example.com"
        {:error, :done}
      end)

      assert Repo.all(AuditEvent) == []
    end
  end

  describe "append-only trigger" do
    setup do
      # These tests describe the hardened trigger. A test database the
      # migrations could not harden would fail here, loudly, rather than pass
      # the flag tests for the wrong reason.
      runner = fn sql -> Repo.query!(sql) end

      %{rows: [[table_owner, connected_as]]} =
        Repo.query!(
          "SELECT pg_get_userbyid(relowner), current_user FROM pg_class WHERE oid = 'audit_events'::regclass"
        )

      assert table_owner == Hardening.owner_role(), "the test database is not hardened"
      assert Purge.status(runner, app_role: connected_as) == :hardened

      user = user_fixture()
      AuditLog.event(:sudo_mode_entered, user_id: user.id)
      %{event: only_event!(), user: user}
    end

    test "Repo.update on a stored row raises from the trigger", %{event: event} do
      changeset = Ecto.Changeset.change(event, action: "rewritten")

      assert_raise Postgrex.Error, ~r/append-only: UPDATE/, fn -> Repo.update(changeset) end
      assert Repo.get!(AuditEvent, event.id).action == "sudo_mode_entered"
    end

    test "a direct update that only nulls the actor is still rejected" do
      assert_raise Postgrex.Error, ~r/append-only: UPDATE/, fn ->
        Repo.update_all(AuditEvent, set: [actor_user_id: nil])
      end
    end

    test "a plain Repo.delete is rejected", %{event: event} do
      assert_raise Postgrex.Error,
                   ~r/append-only: DELETE is not permitted outside the retention purge/,
                   fn -> Repo.delete(event) end

      assert Repo.get(AuditEvent, event.id)
    end

    test "TRUNCATE is rejected even when the purge flag is set" do
      error =
        assert_raise Postgrex.Error, ~r/append-only: TRUNCATE is not permitted/, fn ->
          Repo.transact(fn ->
            Repo.query!("SELECT set_config('kanban.audit_purge', 'on', true)")
            Repo.query!("TRUNCATE audit_events")
            {:ok, :truncated}
          end)
        end

      # TRUNCATE is rejected unconditionally, so its message must not suggest
      # the retention purge could allow it.
      refute Exception.message(error) =~ "retention purge"
      assert Repo.aggregate(AuditEvent, :count) == 1
    end

    test "delete_all and TRUNCATE are rejected" do
      assert_raise Postgrex.Error,
                   ~r/append-only: DELETE is not permitted outside the retention purge/,
                   fn -> Repo.delete_all(AuditEvent) end

      error =
        assert_raise Postgrex.Error, ~r/append-only: TRUNCATE is not permitted/, fn ->
          Repo.query!("TRUNCATE audit_events")
        end

      refute Exception.message(error) =~ "retention purge"
      assert Repo.aggregate(AuditEvent, :count) == 1
    end

    test "a delete with the purge flag set is rejected in hardened mode", %{event: event} do
      # The suite connects as a superuser, which may set the flag and holds the
      # DELETE right. The owner-aware trigger ignores the flag and admits a
      # delete only from the table's owner.
      assert_raise Postgrex.Error,
                   ~r/append-only: DELETE is not permitted outside the retention purge/,
                   fn ->
                     Repo.transact(fn ->
                       Repo.query!("SELECT set_config('kanban.audit_purge', 'on', true)")
                       Repo.delete(event)
                     end)
                   end

      assert Repo.get(AuditEvent, event.id)
    end

    test "deleting the actor nulls actor_user_id and leaves the rest intact",
         %{event: event, user: user} do
      Repo.delete!(user)

      reloaded = Repo.get!(AuditEvent, event.id)
      assert reloaded.actor_user_id == nil
      assert reloaded.action == event.action
      assert reloaded.metadata == event.metadata
      assert reloaded.inserted_at == event.inserted_at
    end
  end

  describe "list_events/2 and stream_events/2" do
    setup do
      user = user_fixture()
      AuditLog.event(:login_failed, email: "first@example.com")
      AuditLog.event(:api_token_created, user_id: user.id, token_id: 1)
      AuditLog.event(:login_failed, email: "third@example.com")
      %{user: user}
    end

    test "lists newest first and filters by action and actor", %{user: user} do
      assert ["login_failed", "api_token_created", "login_failed"] =
               Enum.map(AuditLog.list_events(), & &1.action)

      assert [%{metadata: %{"email" => "third@example.com"}}, _] =
               AuditLog.list_events(action: :login_failed)

      assert [%{action: "api_token_created"}] =
               AuditLog.list_events(actor_user_id: user.id)

      assert [_] = AuditLog.list_events(action: "api_token_created")
      assert length(AuditLog.list_events(action: nil)) == 3
    end

    test "honours :limit, :order and the time window" do
      assert [%{metadata: %{"email" => "first@example.com"}}] =
               AuditLog.list_events([], order: :asc, limit: 1)

      future = DateTime.add(DateTime.utc_now(), 3600)
      assert AuditLog.list_events(since: future) == []
      assert length(AuditLog.list_events(until: future)) == 3

      past = DateTime.add(DateTime.utc_now(), -3600)
      assert AuditLog.list_events(until: past) == []
      assert length(AuditLog.list_events(since: past)) == 3
    end

    test "stream_events/2 yields matching rows oldest first inside a transaction" do
      {:ok, emails} =
        Repo.transact(fn ->
          emails =
            [action: :login_failed]
            |> AuditLog.stream_events(max_rows: 1)
            |> Enum.map(& &1.metadata["email"])

          {:ok, emails}
        end)

      assert emails == ["first@example.com", "third@example.com"]

      assert {:ok, 3} = Repo.transact(fn -> {:ok, Enum.count(AuditLog.stream_events())} end)
    end
  end

  describe "list_events_page/2" do
    setup do
      base = ~U[2026-10-01 12:00:00.000000Z]
      user = user_fixture(%{email: "actor-#{System.unique_integer([:positive])}@example.com"})

      # Five events, the last two sharing a timestamp so ties must break on id.
      e1 = insert_event!("login_failed", base, metadata: %{"email" => "Victim@Example.com"})
      e2 = insert_event!("api_token_created", DateTime.add(base, 60), actor: user)

      e3 =
        insert_event!("login_failed", DateTime.add(base, 86_400),
          metadata: %{"email" => "other@example.com"}
        )

      e4 = insert_event!("permission_denied", DateTime.add(base, 2 * 86_400), actor: user)
      e5 = insert_event!("permission_denied", DateTime.add(base, 2 * 86_400), actor: user)

      %{user: user, events: [e1, e2, e3, e4, e5], base: base}
    end

    test "returns the newest page first with the actor preloaded", %{events: events, user: user} do
      %{entries: entries, next_cursor: nil} = AuditLog.list_events_page()

      assert Enum.map(entries, & &1.id) == events |> Enum.reverse() |> Enum.map(& &1.id)
      assert hd(entries).actor_user.email == user.email
      assert List.last(entries).actor_user == nil
    end

    test "walks every row exactly once across keyset pages, ties broken by id",
         %{events: events} do
      ids = walk_pages([], nil, 2)

      assert ids == events |> Enum.reverse() |> Enum.map(& &1.id)
      assert ids == Enum.uniq(ids)
    end

    test "next_cursor is nil exactly on the last page" do
      assert %{entries: [_, _, _, _], next_cursor: cursor} =
               AuditLog.list_events_page([], limit: 4)

      assert is_binary(cursor)

      assert %{entries: [_], next_cursor: nil} =
               AuditLog.list_events_page([], limit: 4, cursor: Query.decode_cursor(cursor))
    end

    test "clamps the page size to 1..200 and defaults a non-integer limit", %{events: events} do
      assert %{entries: [_]} = AuditLog.list_events_page([], limit: 0)
      assert %{entries: entries} = AuditLog.list_events_page([], limit: "x")
      assert length(entries) == length(events)

      # 205 more rows (210 in all): an oversized limit is capped at exactly 200
      # and the page says there is more.
      now = DateTime.utc_now()

      Repo.insert_all(
        AuditEvent,
        for(
          i <- 1..205,
          do: %{action: "clamp_test", metadata: %{}, inserted_at: DateTime.add(now, i)}
        )
      )

      assert %{entries: capped, next_cursor: cursor} =
               AuditLog.list_events_page([], limit: 10_000)

      assert length(capped) == 200
      assert is_binary(cursor)
    end

    test "filters by action" do
      %{entries: entries} = AuditLog.list_events_page(action: "login_failed")
      assert Enum.all?(entries, &(&1.action == "login_failed"))
      assert length(entries) == 2
    end

    test "filters by actor email case-insensitively, matching the actor or the recorded email",
         %{user: user} do
      %{entries: actor_entries} =
        AuditLog.list_events_page(actor_email: String.upcase(user.email))

      assert length(actor_entries) == 3
      assert Enum.all?(actor_entries, &(&1.actor_user_id == user.id))

      %{entries: [victim]} = AuditLog.list_events_page(actor_email: "victim@example.com")
      assert victim.metadata["email"] == "Victim@Example.com"

      assert %{entries: []} = AuditLog.list_events_page(actor_email: "%@example.com")
    end

    test "filters by an inclusive UTC date range", %{base: base} do
      parsed = Filters.parse(%{"from" => "2026-10-02", "to" => "2026-10-02"})
      %{entries: [only]} = AuditLog.list_events_page(parsed.filters)
      assert DateTime.compare(only.inserted_at, DateTime.add(base, 86_400)) == :eq

      parsed = Filters.parse(%{"to" => "2026-10-01"})
      %{entries: first_day} = AuditLog.list_events_page(parsed.filters)
      assert length(first_day) == 2
    end

    test "returns an empty page when nothing matches" do
      assert AuditLog.list_events_page(action: "nothing_here") == %{entries: [], next_cursor: nil}
    end
  end

  describe "list_events/2 with a :cursor filter" do
    test "returns only rows older than the cursor position" do
      base = ~U[2026-10-01 00:00:00.000000Z]
      older = insert_event!("login_failed", base)
      newer = insert_event!("login_failed", DateTime.add(base, 1))

      assert [%{id: id}] = AuditLog.list_events(cursor: {newer.inserted_at, newer.id})
      assert id == older.id
    end
  end

  describe "list_actions/0" do
    test "lists each stored action once, alphabetically" do
      AuditLog.event(:sudo_mode_entered)
      AuditLog.event(:login_failed)
      AuditLog.event(:login_failed)

      assert AuditLog.list_actions() == ["login_failed", "sudo_mode_entered"]
    end
  end

  describe "export_stream/3" do
    setup do
      user = user_fixture()
      base = ~U[2026-10-01 00:00:00.000000Z]

      insert_event!("login_failed", base, metadata: %{"email" => "=cmd|' /C calc'!A0"})

      insert_event!("api_token_created", DateTime.add(base, 1),
        actor: user,
        ip: "203.0.113.5",
        metadata: %{"user_id" => user.id, "note" => ~s(say "hi",\nthen 日本 ✓)}
      )

      %{user: user}
    end

    test "CSV has a header then one neutralised, quoted row per event, newest first",
         %{user: user} do
      csv = [] |> AuditLog.export_stream(:csv) |> Enum.join()
      [header, newest, oldest] = String.split(csv, "\r\n", trim: true)

      assert header == "id,inserted_at,action,actor_user_id,actor_email,ip,metadata"
      assert newest =~ ",api_token_created,#{user.id},#{user.email},203.0.113.5,"
      assert oldest =~ ",login_failed,,,,"
      # The metadata cell starts with "{" so it is not itself a formula, and the
      # embedded formula text is inside a quoted JSON string.
      refute oldest =~ ~r/(^|,)=/
    end

    test "CSV neutralises a cell that begins with a formula trigger" do
      insert_event!("=SUM(A1)", ~U[2026-10-02 00:00:00.000000Z])

      csv = [action: "=SUM(A1)"] |> AuditLog.export_stream(:csv) |> Enum.join()
      assert csv =~ ",'=SUM(A1),"
    end

    test "JSON is a valid array of objects with metadata intact", %{user: user} do
      json = [] |> AuditLog.export_stream(:json) |> Enum.join()

      assert [newest, oldest] = Jason.decode!(json)
      assert newest["action"] == "api_token_created"
      assert newest["actor_email"] == user.email
      assert newest["metadata"]["note"] == ~s(say "hi",\nthen 日本 ✓)
      assert oldest["metadata"] == %{"email" => "=cmd|' /C calc'!A0"}
      assert oldest["actor_email"] == nil
    end

    test "honours filters and returns an empty array / header-only CSV when nothing matches" do
      assert [action: "nope"] |> AuditLog.export_stream(:json) |> Enum.join() == "[]"

      assert [action: "nope"] |> AuditLog.export_stream(:csv) |> Enum.join() ==
               "id,inserted_at,action,actor_user_id,actor_email,ip,metadata\r\n"

      json = [action: "login_failed"] |> AuditLog.export_stream(:json) |> Enum.join()
      assert [%{"action" => "login_failed"}] = Jason.decode!(json)
    end

    test "reads in keyset batches without losing or repeating rows" do
      base = ~U[2026-10-03 00:00:00.000000Z]
      for i <- 1..7, do: insert_event!("batch_test", DateTime.add(base, div(i, 2)))

      json = [action: "batch_test"] |> AuditLog.export_stream(:json, batch_size: 2) |> Enum.join()
      ids = json |> Jason.decode!() |> Enum.map(& &1["id"])

      assert length(ids) == 7
      assert ids == Enum.uniq(ids)

      csv = [action: "batch_test"] |> AuditLog.export_stream(:csv, batch_size: 3) |> Enum.join()
      assert csv |> String.split("\r\n", trim: true) |> length() == 8
    end

    test "ignores a cursor in the filters and always exports from the newest row" do
      json =
        [cursor: {~U[2000-01-01 00:00:00Z], 1}]
        |> AuditLog.export_stream(:json)
        |> Enum.join()

      assert length(Jason.decode!(json)) == 2
    end

    test "a deleted actor keeps its id from the metadata and has no email", %{user: user} do
      Repo.delete!(user)

      json = [action: "api_token_created"] |> AuditLog.export_stream(:json) |> Enum.join()

      assert [%{"actor_user_id" => id, "actor_email" => nil}] = Jason.decode!(json)
      assert id == user.id
    end
  end

  defp insert_event!(action, inserted_at, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    Repo.insert!(%AuditEvent{
      action: action,
      inserted_at: inserted_at,
      actor_user_id: actor && actor.id,
      ip: Keyword.get(opts, :ip),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  defp walk_pages(acc, cursor, size) do
    %{entries: entries, next_cursor: next} =
      AuditLog.list_events_page([], limit: size, cursor: cursor)

    acc = acc ++ Enum.map(entries, & &1.id)

    if next, do: walk_pages(acc, Query.decode_cursor(next), size), else: acc
  end
end
