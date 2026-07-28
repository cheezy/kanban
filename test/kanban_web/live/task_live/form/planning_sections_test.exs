defmodule KanbanWeb.TaskLive.Form.PlanningSectionsTest do
  @moduledoc """
  Unit tests for the task form's two JSONB-map sections (`testing_strategy` and
  `integration_points`), plus the two sections that ride along in the same
  component but are gated differently: Dependencies (never gated) and Agent
  Tracking (gated on data, not on the visibility map).

  The load-bearing behaviour here is `ensure_list/1`: these map columns hold
  free-form JSON, so a key can legitimately arrive holding a bare string (a
  legacy shape) or a value that is neither string nor list. The component must
  render those without crashing rather than passing them to `Enum.with_index/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.Form.PlanningSections

  @testing_lists ~w(unit_tests integration_tests manual_tests)
  @integration_lists ~w(telemetry_events pubsub_broadcasts phoenix_channels external_apis)

  defp render_sections(task_attrs, visibility, myself \\ nil) do
    form =
      %Task{}
      |> Task.changeset(task_attrs)
      |> to_form(as: :task)

    assigns = %{f: form, field_visibility: visibility, myself: myself}

    rendered_to_string(~H"""
    <PlanningSections.planning_sections
      f={@f}
      field_visibility={@field_visibility}
      myself={@myself}
    />
    """)
  end

  describe "visibility gating" do
    test "hides both map sections when the visibility map is empty" do
      html = render_sections(%{}, %{})

      refute html =~ "Testing Strategy"
      refute html =~ "Integration Points"
    end

    test "testing_strategy and integration_points gate independently" do
      testing_only = render_sections(%{}, %{"testing_strategy" => true})
      assert testing_only =~ "add-unit-test"
      refute testing_only =~ "add-telemetry-event"

      integration_only = render_sections(%{}, %{"integration_points" => true})
      assert integration_only =~ "add-telemetry-event"
      refute integration_only =~ "add-unit-test"
    end

    test "the testing_strategy gate covers all three of its sub-lists at once" do
      html = render_sections(%{}, %{"testing_strategy" => true})

      for list <- @testing_lists do
        assert html =~ ~s(name="task[testing_strategy][#{list}][]")
      end
    end

    test "the integration_points gate covers all four of its sub-lists at once" do
      html = render_sections(%{}, %{"integration_points" => true})

      for list <- @integration_lists do
        assert html =~ ~s(name="task[integration_points][#{list}][]")
      end
    end
  end

  describe "Dependencies section — deliberately NOT gated" do
    test "renders even when the visibility map is completely empty" do
      html = render_sections(%{}, %{})

      assert html =~ "Dependencies"
      assert html =~ ~s(phx-click="add-dependency")
      assert html =~ ~s(<input type="hidden" name="task[dependencies][]" value="")
    end

    test "renders one input per dependency with an indexed remove button" do
      html = render_sections(%{dependencies: ["W01A", "W02B"]}, %{})

      assert html =~ "W01A"
      assert html =~ "W02B"
      assert html =~ ~s(phx-click="remove-dependency")
      assert html =~ ~s(phx-value-index="0")
      assert html =~ ~s(phx-value-index="1")
    end
  end

  describe "Agent Tracking section — gated on data, not on visibility" do
    test "is absent when neither agent field is set" do
      refute render_sections(%{}, %{}) =~ "Agent Tracking"
    end

    test "appears when only created_by_agent is set" do
      html = render_sections(%{created_by_agent: "Claude Opus 5"}, %{})

      assert html =~ "Agent Tracking"
      assert html =~ "Claude Opus 5"
    end

    test "appears when only completed_by_agent is set" do
      html = render_sections(%{completed_by_agent: "Claude Opus 5"}, %{})

      assert html =~ "Agent Tracking"
    end

    test "renders all three tracking inputs, including the completion summary" do
      html = render_sections(%{created_by_agent: "agent"}, %{})

      assert html =~ "task[created_by_agent]"
      assert html =~ "task[completed_by_agent]"
      assert html =~ "task[completion_summary]"
    end

    test "a blank or whitespace-only agent leaves the section hidden" do
      # Ecto's cast treats "" and " " as empty values and stores nil, so blanking
      # the agent field in the form collapses the section rather than leaving an
      # empty one behind.
      refute render_sections(%{created_by_agent: ""}, %{}) =~ "Agent Tracking"
      refute render_sections(%{created_by_agent: " "}, %{}) =~ "Agent Tracking"
    end

    test "the component's own guard is truthiness, so a persisted \"\" would show it" do
      # Distinguishes the changeset's normalization (above) from this component's
      # gate: given a value that survived cast, "" is truthy and the section
      # renders. Built from the struct so the value is read, not cast.
      form =
        %Kanban.Tasks.Task{created_by_agent: ""}
        |> Task.changeset(%{})
        |> to_form(as: :task)

      assigns = %{f: form, field_visibility: %{}, myself: nil}

      html =
        rendered_to_string(~H"""
        <PlanningSections.planning_sections
          f={@f}
          field_visibility={@field_visibility}
          myself={@myself}
        />
        """)

      assert html =~ "Agent Tracking"
    end
  end

  describe "ensure_list/1 tolerance for legacy map shapes" do
    test "renders one input per entry for the normal list shape" do
      html =
        render_sections(
          %{testing_strategy: %{"unit_tests" => ["covers nil", "covers empty"]}},
          %{"testing_strategy" => true}
        )

      assert html =~ "covers nil"
      assert html =~ "covers empty"
      # Two entries plus the hidden clearing input.
      assert length(Regex.scan(~r/name="task\[testing_strategy\]\[unit_tests\]\[\]"/, html)) == 3
    end

    test "a bare string is promoted to a single-entry list rather than crashing" do
      html =
        render_sections(
          %{testing_strategy: %{"unit_tests" => "a single legacy string"}},
          %{"testing_strategy" => true}
        )

      assert html =~ "a single legacy string"
      assert length(Regex.scan(~r/name="task\[testing_strategy\]\[unit_tests\]\[\]"/, html)) == 2
    end

    test "a missing key renders no entries" do
      html =
        render_sections(
          %{testing_strategy: %{"integration_tests" => ["only this one"]}},
          %{"testing_strategy" => true}
        )

      assert html =~ "only this one"
      # unit_tests absent -> hidden input only.
      assert length(Regex.scan(~r/name="task\[testing_strategy\]\[unit_tests\]\[\]"/, html)) == 1
    end

    test "an explicit nil renders no entries" do
      html =
        render_sections(
          %{testing_strategy: %{"unit_tests" => nil}},
          %{"testing_strategy" => true}
        )

      assert length(Regex.scan(~r/name="task\[testing_strategy\]\[unit_tests\]\[\]"/, html)) == 1
    end

    test "a value that is neither list nor string is dropped rather than rendered" do
      for junk <- [42, %{"nested" => "map"}, true] do
        html =
          render_sections(
            %{testing_strategy: %{"unit_tests" => junk}},
            %{"testing_strategy" => true}
          )

        assert length(Regex.scan(~r/name="task\[testing_strategy\]\[unit_tests\]\[\]"/, html)) ==
                 1,
               "#{inspect(junk)} should render no entry rows"
      end
    end

    test "the same tolerance applies to integration_points sub-lists" do
      html =
        render_sections(
          %{integration_points: %{"telemetry_events" => "[:kanban, :task, :done]"}},
          %{"integration_points" => true}
        )

      assert html =~ "[:kanban, :task, :done]"

      assert length(
               Regex.scan(~r/name="task\[integration_points\]\[telemetry_events\]\[\]"/, html)
             ) == 2
    end

    test "an entirely absent map falls back to empty, rendering only add buttons" do
      html = render_sections(%{}, %{"testing_strategy" => true, "integration_points" => true})

      assert html =~ "add-unit-test"
      refute html =~ "remove-unit-test"
      assert html =~ "add-telemetry-event"
      refute html =~ "remove-telemetry-event"
    end
  end

  describe "entry rendering and event targeting" do
    test "each sub-list emits its own add/remove events with per-entry indices" do
      html =
        render_sections(
          %{testing_strategy: %{"manual_tests" => ["m0", "m1"]}},
          %{"testing_strategy" => true}
        )

      assert html =~ ~s(phx-click="add-manual-test")
      assert html =~ ~s(phx-click="remove-manual-test")
      assert html =~ ~s(phx-value-index="0")
      assert html =~ ~s(phx-value-index="1")
    end

    test "buttons target the passed-in component" do
      html = render_sections(%{}, %{"testing_strategy" => true}, "#task-form")

      assert html =~ ~s(phx-target="#task-form")
    end

    test "map entry values are HTML-escaped rather than injected as markup" do
      html =
        render_sections(
          %{testing_strategy: %{"unit_tests" => [~s[<img src=x onerror="boom">]]}},
          %{"testing_strategy" => true}
        )

      refute html =~ ~s(<img src=x)
      assert html =~ "&lt;img"
    end
  end
end
