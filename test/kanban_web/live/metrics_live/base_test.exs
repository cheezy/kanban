defmodule KanbanWeb.MetricsLive.BaseTest do
  @moduledoc """
  Unit tests for `KanbanWeb.MetricsLive.Base`.

  Covers the macro-generated `mount/3` and `handle_event("filter_change", ...)`
  using a fake metric LiveView fixture, plus the public `handle_filter_change/3`
  helper directly. The `handle_params/3` happy path and board-not-found
  branch require database access (Boards.get_board, Metrics.get_agents,
  Boards.get_user_access) and are covered by the per-metric LiveView
  integration tests in `cycle_time_test.exs` etc.
  """

  use ExUnit.Case, async: true

  alias KanbanWeb.MetricsLive.Base
  alias Phoenix.LiveView.Socket

  defmodule FakeMetric do
    use KanbanWeb, :live_view
    use KanbanWeb.MetricsLive.Base, page_title: "Fake Metrics"

    @impl KanbanWeb.MetricsLive.Base
    def load_data(socket) do
      Phoenix.Component.assign(socket, :loaded, true)
    end
  end

  defp empty_socket do
    %Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false
      }
    }
  end

  defp loader_socket(agent_name \\ nil) do
    socket = empty_socket()

    put_in(socket.assigns[:board], %{id: 1})
    |> then(&put_in(&1.assigns[:agent_name], agent_name))
  end

  defp stats_stub(test_pid) do
    fn board_id, opts ->
      send(test_pid, {:stats_called, board_id, opts})
      {:ok, %{average: 1}}
    end
  end

  defp tasks_stub(tasks) do
    fn _board_id, _opts -> tasks end
  end

  describe "load_metric_data/5" do
    test "builds opts without an agent_name key when none is selected" do
      test_pid = self()

      Base.load_metric_data(
        loader_socket(),
        stats_stub(test_pid),
        tasks_stub([]),
        :cycle_time_seconds,
        :daily_cycle_times
      )

      assert_received {:stats_called, 1, opts}
      refute Keyword.has_key?(opts, :agent_name)
      assert opts[:time_range] == :last_30_days
      assert opts[:exclude_weekends] == false
    end

    test "includes agent_name in opts when one is selected" do
      test_pid = self()
      socket = loader_socket("Claude")

      Base.load_metric_data(
        socket,
        stats_stub(test_pid),
        tasks_stub([]),
        :lead_time_seconds,
        :daily_lead_times
      )

      assert_received {:stats_called, 1, opts}
      assert opts[:agent_name] == "Claude"
    end

    test "assigns stats, tasks, grouped tasks, and the daily series under the given key" do
      tasks = [
        %{completed_at: ~U[2026-06-01 12:00:00Z], cycle_time_seconds: 7200},
        %{completed_at: ~U[2026-06-01 15:00:00Z], cycle_time_seconds: 3600}
      ]

      socket =
        Base.load_metric_data(
          loader_socket(),
          stats_stub(self()),
          tasks_stub(tasks),
          :cycle_time_seconds,
          :daily_cycle_times
        )

      assert socket.assigns.summary_stats == %{average: 1}
      assert socket.assigns.tasks == tasks
      assert [{~D[2026-06-01], _}] = socket.assigns.grouped_tasks
      assert [%{date: ~D[2026-06-01], average_hours: avg}] = socket.assigns.daily_cycle_times
      assert avg == 1.5
    end
  end

  describe "mount/3 (generated)" do
    test "assigns time_range, agent_name, and exclude_weekends defaults" do
      {:ok, socket} = FakeMetric.mount(%{}, %{}, empty_socket())

      assert socket.assigns.time_range == :last_30_days
      assert socket.assigns.agent_name == nil
      assert socket.assigns.exclude_weekends == false
    end

    test "does not invoke load_data" do
      {:ok, socket} = FakeMetric.mount(%{}, %{}, empty_socket())
      refute Map.has_key?(socket.assigns, :loaded)
    end
  end

  describe "handle_event filter_change (generated)" do
    test "parses a valid time_range string into the matching atom" do
      {:noreply, socket} =
        FakeMetric.handle_event(
          "filter_change",
          %{
            "time_range" => "last_7_days",
            "agent_name" => "alice",
            "exclude_weekends" => "true"
          },
          empty_socket()
        )

      assert socket.assigns.time_range == :last_7_days
      assert socket.assigns.agent_name == "alice"
      assert socket.assigns.exclude_weekends == true
    end

    test "invokes the load_data callback after assigning filters" do
      {:noreply, socket} =
        FakeMetric.handle_event(
          "filter_change",
          %{"time_range" => "last_30_days", "agent_name" => "", "exclude_weekends" => "false"},
          empty_socket()
        )

      assert socket.assigns.loaded == true
    end

    test "falls back to :last_30_days for an unknown time_range string" do
      {:noreply, socket} =
        FakeMetric.handle_event(
          "filter_change",
          %{
            "time_range" => "definitely_not_a_real_atom_xyz",
            "agent_name" => "",
            "exclude_weekends" => "false"
          },
          empty_socket()
        )

      assert socket.assigns.time_range == :last_30_days
    end

    test "coerces an empty agent_name string to nil" do
      {:noreply, socket} =
        FakeMetric.handle_event(
          "filter_change",
          %{"time_range" => "last_30_days", "agent_name" => "", "exclude_weekends" => "false"},
          empty_socket()
        )

      assert socket.assigns.agent_name == nil
    end

    test "coerces a nil time_range to :last_30_days" do
      {:noreply, socket} =
        FakeMetric.handle_event(
          "filter_change",
          %{"time_range" => nil, "agent_name" => nil, "exclude_weekends" => nil},
          empty_socket()
        )

      assert socket.assigns.time_range == :last_30_days
      assert socket.assigns.agent_name == nil
      assert socket.assigns.exclude_weekends == false
    end

    test "defaults exclude_weekends to false when the key is absent" do
      {:noreply, socket} =
        FakeMetric.handle_event(
          "filter_change",
          %{"time_range" => "last_30_days", "agent_name" => "alice"},
          empty_socket()
        )

      assert socket.assigns.exclude_weekends == false
    end

    test ~s(parses exclude_weekends "true" as true and "false" as false) do
      {:noreply, socket_true} =
        FakeMetric.handle_event(
          "filter_change",
          %{"time_range" => "last_30_days", "agent_name" => nil, "exclude_weekends" => "true"},
          empty_socket()
        )

      {:noreply, socket_false} =
        FakeMetric.handle_event(
          "filter_change",
          %{"time_range" => "last_30_days", "agent_name" => nil, "exclude_weekends" => "false"},
          empty_socket()
        )

      assert socket_true.assigns.exclude_weekends == true
      assert socket_false.assigns.exclude_weekends == false
    end
  end

  describe "Base.handle_filter_change/3 (direct)" do
    test "applies the parsed filters and invokes load_data_fn" do
      load_data_fn = fn s -> Phoenix.Component.assign(s, :tagged, :ok) end

      socket =
        Base.handle_filter_change(
          empty_socket(),
          %{
            "time_range" => "last_90_days",
            "agent_name" => "bob",
            "exclude_weekends" => "true"
          },
          load_data_fn
        )

      assert socket.assigns.time_range == :last_90_days
      assert socket.assigns.agent_name == "bob"
      assert socket.assigns.exclude_weekends == true
      assert socket.assigns.tagged == :ok
    end

    test "load_data_fn receives the socket with filters already assigned" do
      load_data_fn = fn s ->
        send(
          self(),
          {:got, s.assigns.time_range, s.assigns.agent_name, s.assigns.exclude_weekends}
        )

        s
      end

      _ =
        Base.handle_filter_change(
          empty_socket(),
          %{"time_range" => "last_7_days", "agent_name" => "carol", "exclude_weekends" => "true"},
          load_data_fn
        )

      assert_received {:got, :last_7_days, "carol", true}
    end
  end

  describe "behaviour declaration" do
    test "Base declares the load_data/1 callback" do
      assert {:load_data, 1} in Base.behaviour_info(:callbacks)
    end

    test "the using module receives the @behaviour and implements load_data/1" do
      assert function_exported?(FakeMetric, :load_data, 1)
    end

    test "the using module exposes the macro-generated lifecycle callbacks" do
      assert function_exported?(FakeMetric, :mount, 3)
      assert function_exported?(FakeMetric, :handle_params, 3)
      assert function_exported?(FakeMetric, :handle_event, 3)
    end
  end
end
