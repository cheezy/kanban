defmodule Kanban.AuditStream.OutcomeTest do
  use ExUnit.Case, async: true

  alias Kanban.AuditStream.Adapters.Https
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Outcome

  @now ~U[2026-11-12 12:00:00.000000Z]

  defp response(status, retry_after \\ nil),
    do: {:response, %{status: status, body: "body", retry_after: retry_after}}

  defp event(txid, id), do: %{txid: txid, id: id, inserted_at: @now}

  describe "classify/3" do
    test "maps responses, transport errors and refused URLs to classes" do
      assert 200 |> response() |> Outcome.classify(Https, 3) == :delivered
      assert 503 |> response("30") |> Outcome.classify(Https, 3) == {:retry, 30}
      assert 429 |> response() |> Outcome.classify(Https, 3) == {:retry, nil}
      assert 413 |> response() |> Outcome.classify(Https, 3) == :split
      assert 413 |> response() |> Outcome.classify(Https, 1) == :permanent
      assert 400 |> response() |> Outcome.classify(Https, 3) == :permanent
      assert 403 |> response() |> Outcome.classify(Https, 3) == :unauthorized
      assert Outcome.classify({:transport_error, %{reason: :timeout}}, Https, 3) == {:retry, nil}
      assert Outcome.classify({:guard_error, :unresolvable}, Https, 3) == {:retry, nil}

      assert Outcome.classify({:guard_error, :blocked_address}, Https, 3) ==
               {:blocked, :blocked_address}

      assert Outcome.classify({:guard_error, :invalid_url}, Https, 3) == {:blocked, :invalid_url}
    end
  end

  describe "error_text/3" do
    test "names the status or failure and never the body" do
      assert Outcome.error_text(:delivered, response(200), Https) == nil

      assert Outcome.error_text({:retry, nil}, response(503), Https) ==
               "HTTP 503 from the destination"

      assert Outcome.error_text({:retry, nil}, {:transport_error, %{reason: {:a, :b}}}, Https) ==
               "The connection to the destination failed"

      assert Outcome.error_text(
               {:retry, nil},
               {:transport_error, %{reason: :econnrefused}},
               Https
             ) ==
               "Could not connect (econnrefused)"
    end

    test "a timeout or a closed connection is not worded as a failure to connect" do
      assert Outcome.error_text({:retry, nil}, {:transport_error, %{reason: :timeout}}, Https) ==
               "The destination did not answer in time"

      assert Outcome.error_text({:retry, nil}, {:transport_error, %{reason: :closed}}, Https) ==
               "The destination closed the connection before answering"

      assert Outcome.error_text({:config_error, :bad_index}, response(400), Https) ==
               "The destination reported a configuration error (bad_index, HTTP 400)"
    end

    test "uses an adapter's describe_error/2 and cuts to 200 codepoints" do
      defmodule Describing do
        def classify(_status, _body), do: :permanent
        def describe_error(_status, _body), do: String.duplicate("é", 300)
      end

      text = Outcome.error_text(:permanent, response(400), Describing)
      assert String.length(text) == 200
    end
  end

  describe "plan/5" do
    test "a split keeps the first half as a new pending batch, due now" do
      batch = %{
        events: [event(1, 10), event(2, 11), event(3, 12)],
        last: {3, 12},
        pending_attempts: 1
      }

      plan = Outcome.plan(:split, "x", %Destination{}, batch, @now)

      assert %{pending_last_txid: 2, pending_last_id: 11, pending_attempts: 0} = plan.cursor
      assert is_binary(plan.cursor.pending_batch_id)
      assert plan.destination == %{}
      assert plan.follow_up_at == @now
    end

    test "a 2xx from Failing records recovered, from Retrying nothing" do
      batch = %{events: [event(1, 10)], last: {1, 10}}

      assert Outcome.plan(:delivered, nil, %Destination{state: :failing}, batch, @now).audit ==
               :recovered

      assert Outcome.plan(:delivered, nil, %Destination{state: :retrying}, batch, @now).audit ==
               nil
    end

    test "a halt while Failing already records no second failing event" do
      failing = %Destination{state: :failing, failing_since: ~U[2026-11-12 11:00:00Z]}
      plan = Outcome.halt(failing, :txid_reset, Outcome.txid_reset_reason(), @now)

      assert plan.audit == nil
      assert plan.destination.halted_reason == :txid_reset
      assert plan.destination.failing_since == ~U[2026-11-12 11:00:00Z]
      assert plan.follow_up_at == nil

      assert Outcome.halt(%Destination{}, :txid_reset, "x", @now).audit == {:failing, :txid_reset}
    end
  end
end
