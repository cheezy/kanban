defmodule Kanban.TelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Kanban.TelemetryHelpers

  alias Kanban.Telemetry
  alias Kanban.Telemetry.Catalog
  alias Kanban.TelemetrySourceScan

  @emitted [:kanban, :telemetry_test, :emitted]
  @leaked [:kanban, :telemetry_test, :leaked]
  @work [:kanban, :telemetry_test, :work]
  @dropped [:kanban, :telemetry, :metadata_dropped]
  @real [:kanban, :task, :changed_files_missing]

  # Kanban.AuditLog never sends these to telemetry; the stored row keeps them.
  @audit_omitted_keys [:email, :ip, :filters]

  # Test-only entries, passed with the :catalog option so the real catalog
  # carries no fake events. @leaked deliberately declares forbidden keys.
  @test_catalog [
    %{
      name: @emitted,
      kind: :event,
      domain: :telemetry_test,
      measurements: [:count],
      metadata: [:task_id, :board_id],
      description: "Test event.",
      legacy: false
    },
    %{
      name: @leaked,
      kind: :event,
      domain: :telemetry_test,
      measurements: [:count],
      metadata: [:task_id, :email, :ip, :title, :description, :body, :token],
      description: "Test event that wrongly declares forbidden keys.",
      legacy: false
    },
    %{
      name: @work,
      kind: :span,
      domain: :telemetry_test,
      measurements: [:rows],
      metadata: [:task_id, :result_status],
      description: "Test span.",
      legacy: false
    }
  ]

  @entry_fields [:name, :kind, :domain, :measurements, :metadata, :description, :legacy]
  @leaked_values ["a@example.com", "203.0.113.5", "Secret title", "Private body", "tok-123"]
  @particles ~w(out in up off down)
  # Irregular past tenses that do not end in "ed" (notification.read, digest.sent).
  @irregular_past ~w(read sent)

  def raising_handler(_event, _measurements, _metadata, _config), do: raise("handler boom")

  defp emit_test(event, measurements, metadata, opts \\ []) do
    Telemetry.emit(event, measurements, metadata, [catalog: @test_catalog] ++ opts)
  end

  defp span_test(prefix, metadata, fun, opts \\ []) do
    Telemetry.span(prefix, metadata, fun, [catalog: @test_catalog] ++ opts)
  end

  defp peer_loop(test_pid) do
    receive do
      {:emit, task_id} ->
        emit_test(@emitted, %{count: 1}, %{task_id: task_id})
        peer_loop(test_pid)

      {:telemetry_event, _event, _measurements, metadata} ->
        send(test_pid, {:peer_got, metadata})
        peer_loop(test_pid)
    end
  end

  describe "emit/3" do
    test "emit executes a declared event" do
      attach_telemetry(@real)

      assert :ok =
               Telemetry.emit(@real, %{count: 1}, %{task_id: 7, identifier: "D9", board_id: 55})

      assert_receive {:telemetry_event, @real, %{count: 1},
                      %{task_id: 7, identifier: "D9", board_id: 55}}
    end

    test "emit accepts keyword measurements and metadata" do
      attach_telemetry(@emitted)

      emit_test(@emitted, [count: 2], task_id: 1, board_id: 2)

      assert_receive {:telemetry_event, @emitted, %{count: 2}, %{task_id: 1, board_id: 2}}
    end

    test "emit maps declared string keys to atoms" do
      attach_telemetry(@emitted)

      emit_test(@emitted, %{count: 1}, %{"task_id" => 1})

      assert_receive {:telemetry_event, @emitted, _measurements, metadata}
      assert metadata == %{task_id: 1}
    end

    test "emit with empty metadata" do
      attach_telemetry(@emitted)

      emit_test(@emitted, %{count: 1}, %{})
      emit_test(@emitted, %{count: 2}, [])
      Telemetry.emit(@emitted, %{count: 3}, %{}, catalog: @test_catalog)

      assert_receive {:telemetry_event, @emitted, %{count: 1}, metadata_1}
      assert_receive {:telemetry_event, @emitted, %{count: 2}, metadata_2}
      assert_receive {:telemetry_event, @emitted, %{count: 3}, metadata_3}
      assert [metadata_1, metadata_2, metadata_3] == [%{}, %{}, %{}]
    end

    test "emit/2 defaults metadata to an empty map" do
      attach_telemetry(@dropped)

      # metadata_dropped is a real catalogued event with no required metadata.
      Telemetry.emit(@dropped, %{count: 1})

      assert_receive {:telemetry_event, @dropped, %{count: 1}, metadata}
      assert metadata == %{}
    end

    test "forbidden keys are always dropped" do
      attach_telemetry([@leaked, @dropped])

      metadata = %{
        :task_id => 1,
        :email => "a@example.com",
        :ip => "203.0.113.5",
        :title => "Secret title",
        :description => "Private body",
        :body => "Private body",
        :token => "tok-123",
        :reset_token => "tok-123",
        "Email" => "a@example.com"
      }

      log =
        capture_log(fn ->
          # Strict mode (on in test config) never raises for a forbidden key.
          emit_test(@leaked, %{count: 1}, metadata)
          emit_test(@leaked, %{count: 2}, metadata, strict: false)
        end)

      assert_receive {:telemetry_event, @leaked, %{count: 1}, strict_metadata}
      assert_receive {:telemetry_event, @leaked, %{count: 2}, relaxed_metadata}
      assert strict_metadata == %{task_id: 1}
      assert relaxed_metadata == %{task_id: 1}

      expected_keys =
        Enum.sort(~w(Email body description email ip reset_token title token))

      assert_receive {:telemetry_event, @dropped, %{count: 8},
                      %{event_name: @leaked, reason: :forbidden, keys: ^expected_keys}}

      assert log =~ "reset_token"
      for value <- @leaked_values, do: refute(log =~ value)
    end

    test "emit drops an undeclared key when strict mode is off" do
      attach_telemetry([@emitted, @dropped])

      log =
        capture_log(fn ->
          emit_test(@emitted, %{count: 1}, %{task_id: 1, mystery: "do-not-log-me"}, strict: false)
        end)

      assert_receive {:telemetry_event, @emitted, %{count: 1}, metadata}
      assert metadata == %{task_id: 1}

      assert_receive {:telemetry_event, @dropped, %{count: 1},
                      %{event_name: @emitted, reason: :undeclared, keys: ["mystery"]}}

      assert log =~ "mystery"
      refute log =~ "do-not-log-me"
    end

    test "strict mode raises on undeclared key" do
      assert Application.get_env(:kanban, Kanban.Telemetry)[:strict] == true

      error =
        assert_raise ArgumentError, fn ->
          emit_test(@emitted, %{count: 1}, %{task_id: 1, mystery: "do-not-log-me"})
        end

      assert error.message =~ "mystery"
      refute error.message =~ "do-not-log-me"
    end

    test "strict mode raises on undeclared event" do
      assert_raise ArgumentError, ~r/not declared/, fn ->
        Telemetry.emit([:kanban, :nowhere, :happened], %{count: 1}, %{})
      end
    end

    test "emit raises in strict mode for a span entry" do
      assert_raise ArgumentError, ~r/not declared/, fn ->
        emit_test(@work, %{count: 1}, %{task_id: 1})
      end
    end

    test "an undeclared event is skipped when strict mode is off" do
      attach_telemetry([:kanban, :nowhere, :happened], any_process: true)

      log =
        capture_log(fn ->
          assert :ok =
                   Telemetry.emit([:kanban, :nowhere, :happened], %{count: 1}, %{}, strict: false)
        end)

      assert log =~ "not declared"
      refute_received {:telemetry_event, _event, _measurements, _metadata}
    end

    test "emit never raises with strict mode off" do
      attach_telemetry(@emitted)

      inputs = [
        {:x, %{count: 1}, %{}},
        {"kanban.task", %{count: 1}, %{}},
        {@emitted, nil, nil},
        {@emitted, %{count: 1}, "not metadata"},
        {@emitted, [{:count, 1}, :junk], [{:task_id, 1}, :junk, {1, 2}]},
        {@emitted, %{count: 1}, %URI{host: "example.com"}}
      ]

      capture_log(fn ->
        for {event, measurements, metadata} <- inputs do
          assert :ok = emit_test(event, measurements, metadata, strict: false)
        end
      end)

      received =
        for _input <- 1..4 do
          assert_receive {:telemetry_event, @emitted, measurements, metadata}
          {measurements, metadata}
        end

      assert received == [
               {%{}, %{}},
               {%{count: 1}, %{}},
               {%{count: 1}, %{task_id: 1}},
               {%{count: 1}, %{}}
             ]
    end

    test "a raising handler is detached and the caller still gets its result" do
      handler_id = "kanban-telemetry-test-#{System.unique_integer([:positive])}"
      :ok = :telemetry.attach(handler_id, @emitted, &__MODULE__.raising_handler/4, nil)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      capture_log(fn ->
        assert :ok = emit_test(@emitted, %{count: 1}, %{task_id: 1})
      end)

      handler_ids =
        @emitted
        |> :telemetry.list_handlers()
        |> Enum.map(& &1.id)

      refute handler_id in handler_ids
    end
  end

  describe "forbidden_key?/1" do
    test "matches exact names and credential substrings" do
      for key <- [:email, :ip, :title, :description, :body, :token, "IP", "user_email"] do
        assert Telemetry.forbidden_key?(key), "expected #{inspect(key)} to be forbidden"
      end

      for key <- [:reset_token, :api_key, :otp_secret, :password_hash, :authorization] do
        assert Telemetry.forbidden_key?(key), "expected #{inspect(key)} to be forbidden"
      end

      for key <- [:token_id, :task_id, :board_id, :identifier, :status, 1, nil] do
        refute Telemetry.forbidden_key?(key), "expected #{inspect(key)} to be allowed"
      end
    end
  end

  describe "span/3" do
    test "span emits start and stop with a duration" do
      attach_telemetry([@work ++ [:start], @work ++ [:stop]])

      {result, log} = with_log(fn -> span_test(@work, %{task_id: 1}, &stop_with_email/0) end)

      assert result == :done
      assert log =~ "email"

      assert_receive {:telemetry_event, [:kanban, :telemetry_test, :work, :start],
                      %{system_time: _, monotonic_time: _}, start_metadata}

      assert %{task_id: 1, telemetry_span_context: _} = start_metadata

      assert_receive {:telemetry_event, [:kanban, :telemetry_test, :work, :stop],
                      %{duration: duration}, stop_metadata}

      assert is_integer(duration)
      assert %{result_status: :ok, telemetry_span_context: _} = stop_metadata
      refute Map.has_key?(stop_metadata, :email)
    end

    test "span passes extra stop measurements through" do
      attach_telemetry(@work ++ [:stop])

      assert :done =
               span_test(@work, %{task_id: 1}, fn ->
                 {:done, %{rows: 3}, %{result_status: :ok}}
               end)

      assert_receive {:telemetry_event, _event, %{rows: 3, duration: _}, _metadata}
    end

    test "span emits exception and re-raises" do
      attach_telemetry(@work ++ [:exception])

      capture_log(fn ->
        assert_raise RuntimeError, "boom", fn ->
          span_test(@work, %{task_id: 1, email: "a@example.com"}, fn -> raise "boom" end)
        end
      end)

      assert_receive {:telemetry_event, [:kanban, :telemetry_test, :work, :exception],
                      %{duration: _}, metadata}

      assert %{kind: :error, reason: %RuntimeError{message: "boom"}, task_id: 1} = metadata
      assert is_list(metadata.stacktrace)
      refute Map.has_key?(metadata, :email)
    end

    test "span raises on an undeclared span in strict mode without running the function" do
      assert_raise ArgumentError, ~r/not declared/, fn ->
        Telemetry.span([:kanban, :nowhere, :work], %{}, fn ->
          send(self(), :ran)
          {:ok, %{}}
        end)
      end

      refute_received :ran
    end

    test "span runs the function for an undeclared span when strict mode is off" do
      capture_log(fn ->
        assert :a = span_test([:kanban, :nowhere, :work], %{}, fn -> {:a, %{}} end, strict: false)

        assert :b =
                 span_test([:kanban, :nowhere, :work], %{}, fn -> {:b, %{rows: 1}, %{}} end,
                   strict: false
                 )
      end)
    end
  end

  describe "Catalog" do
    test "catalog entries are unique and described" do
      entries = Catalog.events()
      names = Enum.map(entries, & &1.name)

      assert length(names) == length(Enum.uniq(names))

      for entry <- entries do
        assert entry |> Map.keys() |> Enum.sort() == Enum.sort(@entry_fields)
        # A span prefix may be [:kanban, domain] when the domain is itself the
        # operation ([:kanban, :export]); an event always has an action.
        assert [:kanban, domain | _rest] = entry.name
        assert length(entry.name) >= if(entry.kind == :span, do: 2, else: 3)
        assert Enum.all?(entry.name, &is_atom/1)
        assert entry.domain == domain
        assert entry.kind in [:event, :span]
        assert is_binary(entry.description) and String.trim(entry.description) != ""
        assert is_boolean(entry.legacy)
        assert Enum.all?(entry.measurements, &is_atom/1)
        assert Enum.all?(entry.metadata, &is_atom/1)
      end
    end

    test "catalog entries never declare a forbidden key" do
      for entry <- Catalog.events(), key <- entry.metadata do
        refute Telemetry.forbidden_key?(key),
               "#{inspect(entry.name)} declares forbidden key #{inspect(key)}"
      end
    end

    test "new catalog events follow the naming rule" do
      new_events = Enum.filter(Catalog.events(), &(not &1.legacy and &1.kind == :event))

      assert new_events != []

      for %{name: name} <- new_events do
        assert [:kanban, _domain, action] = name

        assert past_tense_action?(action),
               "#{inspect(name)} must end in a past-tense verb or phrasal verb"
      end
    end

    test "every emitted event is in the catalog" do
      sites = Enum.reject(TelemetrySourceScan.scan("lib").sites, &(&1.name == :dynamic))

      # Guards against a scan that silently finds nothing.
      assert length(sites) >= 70

      for site <- sites do
        where = "#{site.file}:#{site.line}"
        assert {:ok, entry} = Catalog.fetch(site.name), "#{where} emits an uncatalogued event"
        assert entry.kind == if(site.kind == :span, do: :span, else: :event), where

        undeclared = site_keys(site) -- entry.metadata
        assert undeclared == [], "#{where} sends undeclared keys #{inspect(undeclared)}"
      end
    end

    test "fetch/1 finds an entry by name and returns :error otherwise" do
      assert {:ok, %{name: @real}} = Catalog.fetch(@real)
      assert :error = Catalog.fetch([:kanban, :nowhere, :happened])
    end
  end

  describe "attach_telemetry/2" do
    test "attach_telemetry delivers the event and detaches on exit" do
      event = [:kanban, :telemetry_test, :detach_check]
      test_pid = self()

      # on_exit callbacks run in reverse order, so this runs after the helper's
      # own detach.
      on_exit(fn ->
        owners =
          event
          |> :telemetry.list_handlers()
          |> Enum.map(& &1.config[:pid])

        refute test_pid in owners
      end)

      handler_id = attach_telemetry(event)
      assert [%{id: ^handler_id}] = :telemetry.list_handlers(event)

      :telemetry.execute(event, %{count: 1}, %{task_id: 1})
      assert_receive {:telemetry_event, ^event, %{count: 1}, %{task_id: 1}}
    end

    test "attach helper isolates concurrent tests" do
      test_pid = self()
      peer = spawn_link(fn -> peer_loop(test_pid) end)

      attach_telemetry(@emitted)
      attach_telemetry(@emitted, pid: peer)

      emit_test(@emitted, %{count: 1}, %{task_id: 1})
      send(peer, {:emit, 2})

      assert_receive {:peer_got, %{task_id: 2}}
      assert_receive {:telemetry_event, @emitted, _measurements, %{task_id: 1}}
      refute_received {:peer_got, %{task_id: 1}}
      refute_receive {:telemetry_event, @emitted, _measurements, %{task_id: 2}}, 50
    end

    test "attach_telemetry delivers events from a Task the test started" do
      attach_telemetry(@emitted)

      task = Task.async(fn -> emit_test(@emitted, [count: 1], task_id: 41) end)
      Task.await(task)

      assert_receive {:telemetry_event, @emitted, _measurements, %{task_id: 41}}
    end

    test "events from an unrelated process need any_process: true" do
      attach_telemetry(@emitted)
      emit_from_unrelated_process(42)
      refute_received {:telemetry_event, @emitted, _measurements, %{task_id: 42}}

      attach_telemetry(@emitted, any_process: true)
      emit_from_unrelated_process(43)
      assert_receive {:telemetry_event, @emitted, _measurements, %{task_id: 43}}
    end
  end

  defp site_keys(%{keys: :unknown}), do: []
  defp site_keys(%{kind: :audit, keys: keys}), do: keys -- @audit_omitted_keys
  defp site_keys(%{keys: keys}), do: keys

  defp stop_with_email do
    {:done, %{result_status: :ok, email: "a@example.com"}}
  end

  defp emit_from_unrelated_process(task_id) do
    {pid, ref} = spawn_monitor(fn -> emit_test(@emitted, %{count: 1}, %{task_id: task_id}) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  # A past-tense verb ("archived") or phrasal verb ("logged_out"): the last
  # word ends in "ed" or is an irregular past tense ("read", "sent"), or it is
  # a particle that follows a word ending in "ed".
  defp past_tense_action?(action) do
    words = action |> Atom.to_string() |> String.split("_")

    case Enum.reverse(words) do
      [last, previous | _rest] when last in @particles -> String.ends_with?(previous, "ed")
      [last | _rest] -> String.ends_with?(last, "ed") or last in @irregular_past
    end
  end
end
