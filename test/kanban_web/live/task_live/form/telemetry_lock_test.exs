defmodule KanbanWeb.TaskLive.Form.TelemetryLockTest do
  # async: false - these tests switch the global :plans_enforced application
  # env on through Kanban.PlansHelpers.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.PlansHelpers
  import Kanban.TelemetryHelpers

  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.Form.TelemetryLock
  alias Phoenix.LiveView.Socket

  @refused [:kanban, :plan, :feature_refused]

  setup :enforce_plans

  setup do
    board = board_fixture(user_fixture())

    socket = %Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        board: board,
        task: %Task{telemetry_event: "[:stored]"},
        telemetry_locked?: false
      }
    }

    %{socket: socket}
  end

  describe "warn_lost/2" do
    test "returns the socket unchanged when nothing was lost", %{socket: socket} do
      attach_telemetry(@refused)

      assert TelemetryLock.warn_lost(socket, []) == socket
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "flashes, locks the form and emits one refusal when a change was lost",
         %{socket: socket} do
      attach_telemetry(@refused)

      socket = TelemetryLock.warn_lost(socket, ["telemetry_event", "metrics_to_track"])

      assert socket.assigns.flash["error"] == TelemetryLock.message()
      assert socket.assigns.telemetry_locked?

      assert_received {:telemetry_event, @refused, %{count: 1},
                       %{feature: :telemetry, surface: :live_view}}

      refute_received {:telemetry_event, @refused, _, _}
    end
  end

  describe "normalize_params/2" do
    test "strips the paid fields and warns only about a real change", %{socket: socket} do
      assert {%{"title" => "T"}, warned} =
               TelemetryLock.normalize_params(socket, %{
                 "title" => "T",
                 "telemetry_event" => "[:changed]"
               })

      assert warned.assigns.flash["error"] == TelemetryLock.message()

      assert {%{}, unchanged} =
               TelemetryLock.normalize_params(socket, %{"telemetry_event" => "[:stored]"})

      assert unchanged == socket
    end
  end

  test "message/0 names both fields and says the changes were not saved" do
    assert TelemetryLock.message() =~ "Telemetry Event and Metrics to Track"
    assert TelemetryLock.message() =~ "were not saved"
  end
end
