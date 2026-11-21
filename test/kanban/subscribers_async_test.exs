defmodule Kanban.SubscribersAsyncTest do
  @moduledoc """
  Pins the off-request signup path of `Kanban.Subscribers.subscribe/2`: with
  `:async_email_delivery` on, storing the address and sending the email run in
  a supervised task for every valid signup, so a new address and one already
  on the list cost the request the same work.

  The rest of the suite runs with the flag off (config/test.exs). This module
  is `async: false` so the global toggle cannot race concurrent tests.
  """
  use Kanban.DataCase, async: false

  alias Kanban.Subscribers

  setup do
    previous = Application.get_env(:kanban, :async_email_delivery)
    Application.put_env(:kanban, :async_email_delivery, true)
    on_exit(fn -> Application.put_env(:kanban, :async_email_delivery, previous) end)

    test_pid = self()
    handler_id = "subscribers-async-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:kanban, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata.source in ["subscribers", "subscriber_tokens"],
            do: send(test_pid, {:subscriber_query, self(), metadata.source})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp subscribe(email) do
    Subscribers.subscribe(email, ip: {10, 1, 2, 3}, locale: "en", consent_text: "consent")
  end

  test "a new address is stored and emailed from a task, not the request process" do
    email = "async-release-#{System.unique_integer([:positive])}@example.test"

    assert :ok = subscribe(email)
    assert_receive {:email, sent}, 1000
    assert sent.to == [{"", email}]

    queries = drain_queries()
    assert {_pid, "subscribers"} = List.keyfind(queries, "subscribers", 1)
    assert {_pid, "subscriber_tokens"} = List.keyfind(queries, "subscriber_tokens", 1)
    assert Enum.all?(queries, fn {pid, _source} -> pid != self() end)

    assert Subscribers.get_subscriber_by_email(email).status == :pending
  end

  test "an address already on the list is looked up from a task too, and gets no second email" do
    email = "async-again-#{System.unique_integer([:positive])}@example.test"
    assert :ok = subscribe(email)
    assert_receive {:email, _first}, 1000
    drain_queries()

    assert :ok = subscribe(String.upcase(email))
    assert_receive {:subscriber_query, pid, "subscribers"}, 1000
    refute pid == self()
    refute_receive {:email, _second}, 200
    assert Enum.all?(drain_queries(), fn {pid, _source} -> pid != self() end)
  end

  test "a malformed address is refused in the request and touches nothing" do
    assert {:error, %Ecto.Changeset{}} = subscribe("not-an-address")
    refute_receive {:subscriber_query, _pid, _source}, 200
    refute_receive {:email, _sent}, 50
  end

  # Every subscriber query reported so far, as {emitting pid, table}.
  defp drain_queries(acc \\ []) do
    receive do
      {:subscriber_query, pid, source} -> drain_queries([{pid, source} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
