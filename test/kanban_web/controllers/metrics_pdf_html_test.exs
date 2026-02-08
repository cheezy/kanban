defmodule KanbanWeb.MetricsPdfHTMLTest do
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.MetricsPdfHTML

  defp render_to_string(rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  describe "throughput/1 template" do
    test "renders throughput template with complete data" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: ["Agent 1", "Agent 2"],
        data: %{
          throughput: [
            %{date: ~D[2024-01-01], count: 5},
            %{date: ~D[2024-01-02], count: 3}
          ],
          summary_stats: %{
            total: 8,
            avg_per_day: 4.0,
            peak_day: ~D[2024-01-01],
            peak_count: 5
          }
        },
        generated_at: ~U[2024-01-15 10:30:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      assert html =~ "Test Board"
      assert html =~ "Throughput Metrics"
      assert html =~ "Last 30 Days"
      assert html =~ "All Agents"
      assert html =~ "Weekends Included"
      assert html =~ "Jan 15, 2024"
    end

    test "renders throughput template with agent filter" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_7_days,
        agent_name: "Claude Sonnet 4.5",
        exclude_weekends: true,
        agents: [],
        data: %{
          throughput: [],
          summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}
        },
        generated_at: ~U[2024-01-15 10:30:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "Weekends Excluded"
      assert html =~ "Last 7 Days"
    end

    test "renders throughput template with nil values" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :today,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [],
          summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}
        },
        generated_at: nil
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      assert html =~ "Test Board"
      assert html =~ "Today"
    end
  end

  describe "cycle_time/1 template" do
    test "renders cycle_time template with complete data" do
      assigns = %{
        board: %{name: "My Board", id: 2},
        metric: "cycle-time",
        time_range: :last_90_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 48.5,
            median_hours: 36.0,
            min_hours: 12.0,
            max_hours: 96.0,
            count: 10
          }
        },
        generated_at: ~U[2024-01-15 14:45:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      assert html =~ "My Board"
      assert html =~ "Cycle Time Metrics"
      assert html =~ "Last 90 Days"
      assert html =~ "Jan 15, 2024"
    end

    test "renders cycle_time template with agent filter" do
      assigns = %{
        board: %{name: "My Board", id: 2},
        metric: "cycle-time",
        time_range: :all_time,
        agent_name: "GPT-4",
        exclude_weekends: true,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 0,
            median_hours: 0,
            min_hours: 0,
            max_hours: 0,
            count: 0
          }
        },
        generated_at: ~U[2024-01-15 14:45:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      assert html =~ "GPT-4"
      assert html =~ "All Time"
      assert html =~ "Weekends Excluded"
    end
  end

  describe "lead_time/1 template" do
    test "renders lead_time template with complete data" do
      assigns = %{
        board: %{name: "Project Board", id: 3},
        metric: "lead-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 120.0,
            median_hours: 96.0,
            min_hours: 24.0,
            max_hours: 240.0,
            count: 15
          }
        },
        generated_at: ~U[2024-01-15 09:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      assert html =~ "Project Board"
      assert html =~ "Lead Time Metrics"
      assert html =~ "Last 30 Days"
      assert html =~ "Jan 15, 2024"
    end

    test "renders lead_time template with custom time range" do
      assigns = %{
        board: %{name: "Project Board", id: 3},
        metric: "lead-time",
        time_range: :custom_range,
        agent_name: "Agent X",
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 0,
            median_hours: 0,
            min_hours: 0,
            max_hours: 0,
            count: 0
          }
        },
        generated_at: ~U[2024-01-15 09:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      assert html =~ "Custom Range"
      assert html =~ "Agent X"
    end
  end

  describe "wait_time/1 template" do
    test "renders wait_time template with complete data" do
      assigns = %{
        board: %{name: "Wait Board", id: 4},
        metric: "wait-time",
        time_range: :last_7_days,
        agent_name: nil,
        exclude_weekends: true,
        agents: [],
        data: %{
          review_wait_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 8
          },
          backlog_wait_stats: %{
            average_hours: 72.0,
            median_hours: 60.0,
            min_hours: 24.0,
            max_hours: 120.0,
            count: 12
          }
        },
        generated_at: ~U[2024-01-15 16:20:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      assert html =~ "Wait Board"
      assert html =~ "Wait Time Metrics"
      assert html =~ "Last 7 Days"
      assert html =~ "Weekends Excluded"
      assert html =~ "Jan 15, 2024"
    end

    test "renders wait_time template with nil generated_at" do
      assigns = %{
        board: %{name: "Wait Board", id: 4},
        metric: "wait-time",
        time_range: :today,
        agent_name: "Test Agent",
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: %{average_hours: 0, median_hours: 0, min_hours: 0, max_hours: 0, count: 0},
          backlog_wait_stats: %{average_hours: 0, median_hours: 0, min_hours: 0, max_hours: 0, count: 0}
        },
        generated_at: nil
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      assert html =~ "Wait Board"
      assert html =~ "Test Agent"
    end
  end

  describe "helper function behavior through templates" do
    test "format_time_range handles all time range atoms" do
      time_ranges = [
        {:today, "Today"},
        {:last_7_days, "Last 7 Days"},
        {:last_30_days, "Last 30 Days"},
        {:last_90_days, "Last 90 Days"},
        {:all_time, "All Time"},
        {:custom, "Custom Range"}
      ]

      for {time_range, expected_text} <- time_ranges do
        assigns = %{
          board: %{name: "Test", id: 1},
          metric: "throughput",
          time_range: time_range,
          agent_name: nil,
          exclude_weekends: false,
          agents: [],
          data: %{throughput: [], summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}},
          generated_at: ~U[2024-01-15 10:00:00Z]
        }

        html = render_to_string(MetricsPdfHTML.throughput(assigns))
        assert html =~ expected_text, "Expected '#{expected_text}' for time_range :#{time_range}"
      end
    end

    test "format_date handles dates correctly" do
      assigns = %{
        board: %{name: "Test", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [
            %{date: ~D[2024-12-25], count: 1}
          ],
          summary_stats: %{
            total: 1,
            avg_per_day: 1.0,
            peak_day: ~D[2024-12-25],
            peak_count: 1
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))
      assert html =~ "Dec 25, 2024"
    end

    test "format_datetime handles datetimes correctly" do
      assigns = %{
        board: %{name: "Test", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{throughput: [], summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}},
        generated_at: ~U[2024-03-15 14:30:45Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))
      assert html =~ "Mar 15, 2024"
    end

    test "agent_filter_label shows agent name when present" do
      assigns = %{
        board: %{name: "Test", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: "Custom Agent Name",
        exclude_weekends: false,
        agents: [],
        data: %{throughput: [], summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}},
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))
      assert html =~ "Custom Agent Name"
    end

    test "agent_filter_label shows 'All Agents' when nil" do
      assigns = %{
        board: %{name: "Test", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{throughput: [], summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}},
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))
      assert html =~ "All Agents"
    end

    test "weekend_filter_label shows correct text for true" do
      assigns = %{
        board: %{name: "Test", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: true,
        agents: [],
        data: %{throughput: [], summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}},
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))
      assert html =~ "Weekends Excluded"
    end

    test "weekend_filter_label shows correct text for false" do
      assigns = %{
        board: %{name: "Test", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{throughput: [], summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}},
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))
      assert html =~ "Weekends Included"
    end
  end

  describe "edge cases" do
    test "handles nil peak_day in throughput stats" do
      assigns = %{
        board: %{name: "Test", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [],
          summary_stats: %{
            total: 0,
            avg_per_day: 0.0,
            peak_day: nil,
            peak_count: 0
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))
      assert is_binary(html)
    end

    test "handles empty board name" do
      assigns = %{
        board: %{name: "", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{throughput: [], summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}},
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))
      assert is_binary(html)
    end

    test "handles special characters in board name" do
      assigns = %{
        board: %{name: "Board & Co. <Test>", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{throughput: [], summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}},
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))
      assert is_binary(html)
    end
  end
end
