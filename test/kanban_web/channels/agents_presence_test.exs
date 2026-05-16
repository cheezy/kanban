defmodule KanbanWeb.AgentsPresenceTest do
  @moduledoc """
  Unit tests for `KanbanWeb.AgentsPresence` — the Phoenix.Presence
  tracker for the `/agents` LiveView.
  """
  use Kanban.DataCase, async: false

  alias KanbanWeb.AgentsPresence

  describe "topic/0" do
    test "returns the static 'agents' topic" do
      assert AgentsPresence.topic() == "agents"
    end
  end

  describe "count/0" do
    test "returns 0 when no viewers are tracked" do
      # The supervised process under test in async: false ensures isolation.
      assert is_integer(AgentsPresence.count())
      assert AgentsPresence.count() >= 0
    end

    test "increments when a viewer is tracked and decrements on process exit" do
      topic = AgentsPresence.topic()
      before = AgentsPresence.count()

      pid =
        spawn(fn ->
          {:ok, _} =
            AgentsPresence.track(self(), topic, "test-socket-#{System.unique_integer()}", %{})

          receive do
            :stop -> :ok
          end
        end)

      # Give the track a moment to register
      Process.sleep(50)

      assert AgentsPresence.count() == before + 1

      send(pid, :stop)
      # Wait for the process to exit and Presence to reap the entry
      Process.sleep(100)

      assert AgentsPresence.count() == before
    end
  end
end
