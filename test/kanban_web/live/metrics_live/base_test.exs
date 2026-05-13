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
