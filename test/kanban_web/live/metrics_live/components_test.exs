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

  describe "metric_filters/1" do
    test "renders with all filter options" do
      assigns = %{
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: ["Claude Sonnet 4.5", "GPT-4"],
        view_name: "cycle time"
      }

      html =
        rendered_to_string(~H"""
        <Components.metric_filters
          time_range={@time_range}
          agent_name={@agent_name}
          exclude_weekends={@exclude_weekends}
          agents={@agents}
          view_name={@view_name}
        />
        """)

      assert html =~ "Filters"
      assert html =~ "Customize your cycle time view"
      assert html =~ "phx-change=\"filter_change\""
    end

    test "renders time range filter with all options" do
      assigns = %{
        time_range: :last_7_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        view_name: "lead time"
      }

      html =
        rendered_to_string(~H"""
        <Components.metric_filters
          time_range={@time_range}
          agent_name={@agent_name}
          exclude_weekends={@exclude_weekends}
          agents={@agents}
          view_name={@view_name}
        />
        """)

      assert html =~ "Today"
      assert html =~ "Last 7 Days"
      assert html =~ "Last 30 Days"
      assert html =~ "Last 90 Days"
      assert html =~ "All Time"
      assert html =~ "selected"
    end

    test "renders agent filter with agent list" do
      assigns = %{
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: ["Claude Sonnet 4.5", "GPT-4"],
        view_name: "wait time"
      }

      html =
        rendered_to_string(~H"""
        <Components.metric_filters
          time_range={@time_range}
          agent_name={@agent_name}
          exclude_weekends={@exclude_weekends}
          agents={@agents}
          view_name={@view_name}
        />
        """)

      assert html =~ "All Agents"
      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "GPT-4"
    end

    test "marks selected agent in filter" do
      assigns = %{
        time_range: :last_30_days,
        agent_name: "Claude Sonnet 4.5",
        exclude_weekends: false,
        agents: ["Claude Sonnet 4.5", "GPT-4"],
        view_name: "cycle time"
      }

      html =
        rendered_to_string(~H"""
        <Components.metric_filters
          time_range={@time_range}
          agent_name={@agent_name}
          exclude_weekends={@exclude_weekends}
          agents={@agents}
          view_name={@view_name}
        />
        """)

      assert html =~ "selected"
      assert html =~ "Claude Sonnet 4.5"
    end

    test "renders weekend toggle checked when true" do
      assigns = %{
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: true,
        agents: [],
        view_name: "lead time"
      }

      html =
        rendered_to_string(~H"""
        <Components.metric_filters
          time_range={@time_range}
          agent_name={@agent_name}
          exclude_weekends={@exclude_weekends}
          agents={@agents}
          view_name={@view_name}
        />
        """)

      assert html =~ "Exclude Weekends"
      assert html =~ "checked"
    end

    test "includes gradient styling and icons" do
      assigns = %{
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        view_name: "cycle time"
      }

      html =
        rendered_to_string(~H"""
        <Components.metric_filters
          time_range={@time_range}
          agent_name={@agent_name}
          exclude_weekends={@exclude_weekends}
          agents={@agents}
          view_name={@view_name}
        />
        """)

      assert html =~ "bg-gradient-to-br"
      assert html =~ "hero-funnel-solid"
      assert html =~ "hero-calendar"
      assert html =~ "hero-user-circle"
      assert html =~ "hero-calendar-days"
    end

    test "includes dark mode classes" do
      assigns = %{
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        view_name: "cycle time"
      }

      html =
        rendered_to_string(~H"""
        <Components.metric_filters
          time_range={@time_range}
          agent_name={@agent_name}
          exclude_weekends={@exclude_weekends}
          agents={@agents}
          view_name={@view_name}
        />
        """)

      assert html =~ "dark:from-zinc-800"
      assert html =~ "dark:to-zinc-900"
      assert html =~ "dark:border-zinc-700"
    end
  end

  describe "summary_stats/1" do
    test "renders all four stat cards" do
      assigns = %{
        stats: %{
          average_hours: 2.5,
          median_hours: 2.0,
          min_hours: 0.5,
          max_hours: 8.0
        },
        format_fn: fn seconds -> "#{Float.round(seconds / 3600, 1)}h" end
      }

      html =
        rendered_to_string(~H"""
        <Components.summary_stats stats={@stats} format_fn={@format_fn} />
        """)

      assert html =~ "Average"
      assert html =~ "Median"
      assert html =~ "Min"
      assert html =~ "Max"
    end

    test "formats values using provided format function" do
      assigns = %{
        stats: %{
          average_hours: 1.0,
          median_hours: 0.5,
          min_hours: 0.3,
          max_hours: 2.0
        },
        format_fn: fn seconds -> "#{Float.round(seconds / 3600, 1)}h" end
      }

      html =
        rendered_to_string(~H"""
        <Components.summary_stats stats={@stats} format_fn={@format_fn} />
        """)

      assert html =~ "1.0h"
      assert html =~ "0.5h"
      assert html =~ "0.3h"
      assert html =~ "2.0h"
    end

    test "includes colored icons for each stat" do
      assigns = %{
        stats: %{
          average_hours: 1.0,
          median_hours: 1.0,
          min_hours: 1.0,
          max_hours: 1.0
        },
        format_fn: fn _seconds -> "1h" end
      }

      html =
        rendered_to_string(~H"""
        <Components.summary_stats stats={@stats} format_fn={@format_fn} />
        """)

      assert html =~ "hero-clock-solid"
      assert html =~ "hero-chart-bar-solid"
      assert html =~ "hero-arrow-down-solid"
      assert html =~ "hero-arrow-up-solid"
    end

    test "uses gradient backgrounds with different colors" do
      assigns = %{
        stats: %{
          average_hours: 1.0,
          median_hours: 1.0,
          min_hours: 1.0,
          max_hours: 1.0
        },
        format_fn: fn _seconds -> "1h" end
      }

      html =
        rendered_to_string(~H"""
        <Components.summary_stats stats={@stats} format_fn={@format_fn} />
        """)

      assert html =~ "from-white to-blue-50"
      assert html =~ "border-blue-500"
      assert html =~ "from-white to-purple-50"
      assert html =~ "border-purple-500"
      assert html =~ "from-white to-green-50"
      assert html =~ "border-green-500"
      assert html =~ "from-white to-red-50"
      assert html =~ "border-red-500"
    end

    test "includes dark mode classes" do
      assigns = %{
        stats: %{
          average_hours: 1.0,
          median_hours: 1.0,
          min_hours: 1.0,
          max_hours: 1.0
        },
        format_fn: fn _seconds -> "1h" end
      }

      html =
        rendered_to_string(~H"""
        <Components.summary_stats stats={@stats} format_fn={@format_fn} />
        """)

      assert html =~ "dark:from-zinc-800"
      assert html =~ "dark:to-zinc-900"
      assert html =~ "dark:text-gray-100"
    end

    test "handles zero values" do
      assigns = %{
        stats: %{
          average_hours: 0.0,
          median_hours: 0.0,
          min_hours: 0.0,
          max_hours: 0.0
        },
        format_fn: fn _seconds -> "0.0h" end
      }

      html =
        rendered_to_string(~H"""
        <Components.summary_stats stats={@stats} format_fn={@format_fn} />
        """)

      assert html =~ "0.0h"
    end
  end

  describe "trend_chart/1" do
    test "renders chart with data" do
      assigns = %{
        title: "Daily Cycle Time",
        subtitle: "Average cycle time by day",
        daily_times: [
          %{date: ~D[2024-01-01], average_hours: 2.0},
          %{date: ~D[2024-01-02], average_hours: 3.0},
          %{date: ~D[2024-01-03], average_hours: 2.5}
        ],
        format_fn: fn hours -> "#{Float.round(hours, 1)}h" end,
        empty_message: "No data available"
      }

      html =
        rendered_to_string(~H"""
        <Components.trend_chart
          title={@title}
          subtitle={@subtitle}
          daily_times={@daily_times}
          format_fn={@format_fn}
          empty_message={@empty_message}
        />
        """)

      assert html =~ "Daily Cycle Time"
      assert html =~ "Average cycle time by day"
      assert html =~ "<svg"
      assert html =~ "viewBox=\"0 0 800 400\""
    end

    test "renders empty state when no data" do
      assigns = %{
        title: "Daily Cycle Time",
        subtitle: "Average cycle time by day",
        daily_times: [],
        format_fn: fn hours -> "#{Float.round(hours, 1)}h" end,
        empty_message: "No cycle time data"
      }

      html =
        rendered_to_string(~H"""
        <Components.trend_chart
          title={@title}
          subtitle={@subtitle}
          daily_times={@daily_times}
          format_fn={@format_fn}
          empty_message={@empty_message}
        />
        """)

      assert html =~ "No cycle time data"
      assert html =~ "hero-chart-bar"
      refute html =~ "<svg"
    end

    test "includes gradient and icons" do
      assigns = %{
        title: "Test Chart",
        subtitle: "Test subtitle",
        daily_times: [
          %{date: ~D[2024-01-01], average_hours: 1.0}
        ],
        format_fn: fn hours -> "#{hours}h" end,
        empty_message: "No data"
      }

      html =
        rendered_to_string(~H"""
        <Components.trend_chart
          title={@title}
          subtitle={@subtitle}
          daily_times={@daily_times}
          format_fn={@format_fn}
          empty_message={@empty_message}
        />
        """)

      assert html =~ "bg-gradient-to-br from-indigo-500 to-blue-600"
      assert html =~ "hero-chart-bar-solid"
    end

    test "renders SVG elements when data present" do
      assigns = %{
        title: "Test Chart",
        subtitle: "Test subtitle",
        daily_times: [
          %{date: ~D[2024-01-01], average_hours: 1.0},
          %{date: ~D[2024-01-02], average_hours: 2.0}
        ],
        format_fn: fn hours -> "#{hours}h" end,
        empty_message: "No data"
      }

      html =
        rendered_to_string(~H"""
        <Components.trend_chart
          title={@title}
          subtitle={@subtitle}
          daily_times={@daily_times}
          format_fn={@format_fn}
          empty_message={@empty_message}
        />
        """)

      assert html =~ "<linearGradient"
      assert html =~ "<polyline"
      assert html =~ "<circle"
      assert html =~ "<text"
    end

    test "formats dates in chart labels" do
      assigns = %{
        title: "Test Chart",
        subtitle: "Test subtitle",
        daily_times: [
          %{date: ~D[2024-01-15], average_hours: 1.0}
        ],
        format_fn: fn hours -> "#{hours}h" end,
        empty_message: "No data"
      }

      html =
        rendered_to_string(~H"""
        <Components.trend_chart
          title={@title}
          subtitle={@subtitle}
          daily_times={@daily_times}
          format_fn={@format_fn}
          empty_message={@empty_message}
        />
        """)

      assert html =~ "01/15"
    end

    test "includes dark mode classes" do
      assigns = %{
        title: "Test Chart",
        subtitle: "Test subtitle",
        daily_times: [],
        format_fn: fn hours -> "#{hours}h" end,
        empty_message: "No data"
      }

      html =
        rendered_to_string(~H"""
        <Components.trend_chart
          title={@title}
          subtitle={@subtitle}
          daily_times={@daily_times}
          format_fn={@format_fn}
          empty_message={@empty_message}
        />
        """)

      assert html =~ "dark:bg-zinc-800"
      assert html =~ "dark:border-zinc-700"
      assert html =~ "dark:text-gray-100"
    end

    test "uses default empty message when not provided" do
      assigns = %{
        title: "Test Chart",
        subtitle: "Test subtitle",
        daily_times: [],
        format_fn: fn hours -> "#{hours}h" end
      }

      html =
        rendered_to_string(~H"""
        <Components.trend_chart
          title={@title}
          subtitle={@subtitle}
          daily_times={@daily_times}
          format_fn={@format_fn}
        />
        """)

      assert html =~ "No data available"
    end
  end

  describe "empty_state/1" do
    test "renders with required attributes" do
      assigns = %{
        icon_name: "hero-inbox",
        message: "No tasks found",
        size: "large"
      }

      html =
        rendered_to_string(~H"""
        <Components.empty_state icon_name={@icon_name} message={@message} size={@size} />
        """)

      assert html =~ "hero-inbox"
      assert html =~ "No tasks found"
    end

    test "renders large size by default" do
      assigns = %{
        icon_name: "hero-chart-bar",
        message: "No metrics data",
        size: "large"
      }

      html =
        rendered_to_string(~H"""
        <Components.empty_state icon_name={@icon_name} message={@message} size={@size} />
        """)

      assert html =~ "h-16 w-16"
      assert html =~ "text-lg font-medium"
    end

    test "renders small size when specified" do
      assigns = %{
        icon_name: "hero-document",
        message: "No documents",
        size: "small"
      }

      html =
        rendered_to_string(~H"""
        <Components.empty_state icon_name={@icon_name} message={@message} size={@size} />
        """)

      assert html =~ "h-12 w-12"
      assert html =~ "text-base"
    end

    test "includes dark mode classes" do
      assigns = %{
        icon_name: "hero-inbox",
        message: "Empty",
        size: "large"
      }

      html =
        rendered_to_string(~H"""
        <Components.empty_state icon_name={@icon_name} message={@message} size={@size} />
        """)

      assert html =~ "dark:text-gray-600"
      assert html =~ "dark:text-gray-400"
    end

    test "centers content with padding" do
      assigns = %{
        icon_name: "hero-inbox",
        message: "No content",
        size: "large"
      }

      html =
        rendered_to_string(~H"""
        <Components.empty_state icon_name={@icon_name} message={@message} size={@size} />
        """)

      assert html =~ "text-center py-12"
    end
  end
end
