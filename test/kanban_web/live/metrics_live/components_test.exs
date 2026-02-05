defmodule KanbanWeb.MetricsLive.ComponentsTest do
  use KanbanWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MetricsLive.Components

  describe "stat_card/1" do
    test "renders with required attributes" do
      assigns = %{
        title: "Test Metric",
        value: "42",
        subtitle: nil,
        icon: nil,
        link: nil,
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.stat_card
          title={@title}
          value={@value}
          subtitle={@subtitle}
          icon={@icon}
          link={@link}
          class={@class}
        />
        """)

      assert html =~ "Test Metric"
      assert html =~ "42"
    end

    test "renders with subtitle" do
      assigns = %{
        title: "Cycle Time",
        value: "24.0h",
        subtitle: "median: 20.5h",
        icon: nil,
        link: nil,
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.stat_card
          title={@title}
          value={@value}
          subtitle={@subtitle}
          icon={@icon}
          link={@link}
          class={@class}
        />
        """)

      assert html =~ "Cycle Time"
      assert html =~ "24.0h"
      assert html =~ "median: 20.5h"
    end

    test "renders with icon" do
      assigns = %{
        title: "Throughput",
        value: "15",
        subtitle: nil,
        icon: "hero-chart-bar",
        link: nil,
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.stat_card
          title={@title}
          value={@value}
          subtitle={@subtitle}
          icon={@icon}
          link={@link}
          class={@class}
        />
        """)

      assert html =~ "hero-chart-bar"
      assert html =~ "Throughput"
    end

    test "renders with link" do
      assigns = %{
        title: "Lead Time",
        value: "48.0h",
        subtitle: nil,
        icon: nil,
        link: "/boards/1/metrics/lead-time",
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.stat_card
          title={@title}
          value={@value}
          subtitle={@subtitle}
          icon={@icon}
          link={@link}
          class={@class}
        />
        """)

      assert html =~ "View details"
      assert html =~ "/boards/1/metrics/lead-time"
    end

    test "includes dark mode classes" do
      assigns = %{
        title: "Test",
        value: "1",
        subtitle: nil,
        icon: nil,
        link: nil,
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.stat_card
          title={@title}
          value={@value}
          subtitle={@subtitle}
          icon={@icon}
          link={@link}
          class={@class}
        />
        """)

      assert html =~ "dark:bg-zinc-800"
      assert html =~ "dark:text-gray-100"
    end
  end

  describe "bar_chart/1" do
    test "renders with data" do
      assigns = %{
        title: "Throughput by Week",
        data: [
          %{label: "Week 1", value: 5, max: 10},
          %{label: "Week 2", value: 8, max: 10}
        ],
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.bar_chart title={@title} data={@data} class={@class} />
        """)

      assert html =~ "Throughput by Week"
      assert html =~ "Week 1"
      assert html =~ "Week 2"
      assert html =~ "5"
      assert html =~ "8"
    end

    test "handles empty data array" do
      assigns = %{
        title: "Empty Chart",
        data: [],
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.bar_chart title={@title} data={@data} class={@class} />
        """)

      assert html =~ "Empty Chart"
      assert html =~ "No data available"
    end

    test "handles zero values" do
      assigns = %{
        title: "Zero Values",
        data: [
          %{label: "Week 1", value: 0, max: 10}
        ],
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.bar_chart title={@title} data={@data} class={@class} />
        """)

      assert html =~ "Zero Values"
      assert html =~ "Week 1"
      assert html =~ "0"
    end

    test "calculates percentages correctly" do
      assigns = %{
        title: "Test Chart",
        data: [
          %{label: "Half", value: 5, max: 10}
        ],
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.bar_chart title={@title} data={@data} class={@class} />
        """)

      assert html =~ "width: 50.0%"
    end

    test "includes ARIA labels for accessibility" do
      assigns = %{
        title: "Accessible Chart",
        data: [
          %{label: "Week 1", value: 5, max: 10}
        ],
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.bar_chart title={@title} data={@data} class={@class} />
        """)

      assert html =~ "role=\"progressbar\""
      assert html =~ "aria-valuenow=\"5\""
      assert html =~ "aria-valuemin=\"0\""
      assert html =~ "aria-valuemax=\"10\""
      assert html =~ "aria-label=\"Week 1: 5\""
    end

    test "uses CSS-only rendering (no JavaScript)" do
      assigns = %{
        title: "Pure CSS",
        data: [
          %{label: "Test", value: 7, max: 10}
        ],
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.bar_chart title={@title} data={@data} class={@class} />
        """)

      refute html =~ "phx-"
      refute html =~ "onclick"
      assert html =~ "style=\"width:"
    end
  end

  describe "time_range_filter/1" do
    test "renders with current selection" do
      assigns = %{
        current_range: :last_30_days,
        on_change: "filter_time_range",
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.time_range_filter
          current_range={@current_range}
          on_change={@on_change}
          class={@class}
        />
        """)

      assert html =~ "Time Range"
      assert html =~ "Last 7 Days"
      assert html =~ "Last 30 Days"
      assert html =~ "Last 90 Days"
      assert html =~ "All Time"
      assert html =~ "phx-change=\"filter_time_range\""
    end

    test "marks correct option as selected" do
      assigns = %{
        current_range: :last_7_days,
        on_change: "filter_time_range",
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.time_range_filter
          current_range={@current_range}
          on_change={@on_change}
          class={@class}
        />
        """)

      assert html =~ "selected"
      assert html =~ "last_7_days"
    end

    test "includes ARIA label" do
      assigns = %{
        current_range: :last_30_days,
        on_change: "filter_time_range",
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.time_range_filter
          current_range={@current_range}
          on_change={@on_change}
          class={@class}
        />
        """)

      assert html =~ "aria-label=\"Select time range\""
    end
  end

  describe "agent_filter/1" do
    test "renders with empty agents list" do
      assigns = %{
        agents: [],
        current_agent: nil,
        on_change: "filter_agent",
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.agent_filter
          agents={@agents}
          current_agent={@current_agent}
          on_change={@on_change}
          class={@class}
        />
        """)

      assert html =~ "Agent Filter"
      assert html =~ "All Agents"
      assert html =~ "phx-change=\"filter_agent\""
    end

    test "renders with agents list" do
      assigns = %{
        agents: ["Claude Sonnet 4.5", "GPT-4"],
        current_agent: nil,
        on_change: "filter_agent",
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.agent_filter
          agents={@agents}
          current_agent={@current_agent}
          on_change={@on_change}
          class={@class}
        />
        """)

      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "GPT-4"
    end

    test "marks selected agent" do
      assigns = %{
        agents: ["Claude Sonnet 4.5", "GPT-4"],
        current_agent: "Claude Sonnet 4.5",
        on_change: "filter_agent",
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.agent_filter
          agents={@agents}
          current_agent={@current_agent}
          on_change={@on_change}
          class={@class}
        />
        """)

      assert html =~ "selected"
      assert html =~ "Claude Sonnet 4.5"
    end
  end

  describe "weekend_toggle/1" do
    test "renders unchecked by default" do
      assigns = %{
        exclude_weekends: false,
        on_change: "toggle_weekends",
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.weekend_toggle
          exclude_weekends={@exclude_weekends}
          on_change={@on_change}
          class={@class}
        />
        """)

      assert html =~ "Exclude Weekends"
      assert html =~ "phx-change=\"toggle_weekends\""
      refute html =~ "checked"
    end

    test "renders checked when true" do
      assigns = %{
        exclude_weekends: true,
        on_change: "toggle_weekends",
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.weekend_toggle
          exclude_weekends={@exclude_weekends}
          on_change={@on_change}
          class={@class}
        />
        """)

      assert html =~ "checked"
    end

    test "includes ARIA label" do
      assigns = %{
        exclude_weekends: false,
        on_change: "toggle_weekends",
        class: ""
      }

      html =
        rendered_to_string(~H"""
        <Components.weekend_toggle
          exclude_weekends={@exclude_weekends}
          on_change={@on_change}
          class={@class}
        />
        """)

      assert html =~ "aria-label=\"Exclude weekends from calculations\""
    end
  end
end
