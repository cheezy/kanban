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

  describe "lead_time template - line chart rendering" do
    test "renders line chart when daily_lead_times are present" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "lead-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 72.0,
            median_hours: 48.0,
            min_hours: 24.0,
            max_hours: 120.0,
            count: 5
          },
          daily_lead_times: [
            %{date: ~D[2024-01-01], average_hours: 48.0},
            %{date: ~D[2024-01-02], average_hours: 72.0},
            %{date: ~D[2024-01-03], average_hours: 96.0}
          ],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      assert html =~ "Lead Time Trend"
      assert html =~ "<svg"
      assert html =~ "<polyline"
      assert html =~ "Jan 01"
      assert html =~ "Jan 03"
      # Uses green theme for lead time
      assert html =~ "stroke=\"#10b981\""
    end

    test "renders line chart with single data point" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "lead-time",
        time_range: :last_7_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 36.0,
            median_hours: 36.0,
            min_hours: 36.0,
            max_hours: 36.0,
            count: 1
          },
          daily_lead_times: [
            %{date: ~D[2024-01-05], average_hours: 36.0}
          ],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      assert html =~ "Lead Time Trend"
      assert html =~ "<svg"
      assert html =~ "<circle"
    end

    test "hides line chart when daily_lead_times is empty" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "lead-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 72.0,
            median_hours: 48.0,
            min_hours: 24.0,
            max_hours: 120.0,
            count: 5
          },
          daily_lead_times: [],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      refute html =~ "Lead Time Trend"
      refute html =~ "<polyline"
    end

    test "hides line chart when daily_lead_times key is missing" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "lead-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 72.0,
            median_hours: 48.0,
            min_hours: 24.0,
            max_hours: 120.0,
            count: 5
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      refute html =~ "Lead Time Trend"
    end

    test "renders line chart with zero average_hours" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "lead-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 0.0,
            median_hours: 0.0,
            min_hours: 0.0,
            max_hours: 0.0,
            count: 1
          },
          daily_lead_times: [
            %{date: ~D[2024-01-01], average_hours: 0.0},
            %{date: ~D[2024-01-02], average_hours: 0.0}
          ],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      assert html =~ "Lead Time Trend"
      assert html =~ "<svg"
    end
  end

  describe "lead_time template - completed tasks section" do
    test "renders completed tasks grouped by date" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "lead-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 72.0,
            median_hours: 48.0,
            min_hours: 24.0,
            max_hours: 120.0,
            count: 3
          },
          daily_lead_times: [],
          grouped_tasks: [
            {~D[2024-01-10],
             [
               %{
                 identifier: "W42",
                 title: "Implement auth module",
                 inserted_at: ~U[2024-01-05 08:00:00Z],
                 completed_at: ~U[2024-01-10 14:00:00Z],
                 completed_by_agent: "Claude Sonnet 4.5",
                 lead_time_seconds: 453_600.0
               },
               %{
                 identifier: "W43",
                 title: "Add tests for auth",
                 inserted_at: ~U[2024-01-06 09:00:00Z],
                 completed_at: ~U[2024-01-10 16:00:00Z],
                 completed_by_agent: "GPT-4",
                 lead_time_seconds: 370_800.0
               }
             ]}
          ]
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      assert html =~ "Completed Tasks"
      assert html =~ "Jan 10, 2024"
      assert html =~ "W42"
      assert html =~ "Implement auth module"
      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "W43"
      assert html =~ "Add tests for auth"
      assert html =~ "GPT-4"
      assert html =~ "Created:"
      assert html =~ "Completed:"
    end

    test "renders lead time badge for each task" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "lead-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 48.0,
            median_hours: 48.0,
            min_hours: 48.0,
            max_hours: 48.0,
            count: 1
          },
          daily_lead_times: [],
          grouped_tasks: [
            {~D[2024-01-10],
             [
               %{
                 identifier: "W50",
                 title: "Quick task",
                 inserted_at: ~U[2024-01-08 08:00:00Z],
                 completed_at: ~U[2024-01-10 14:00:00Z],
                 completed_by_agent: nil,
                 lead_time_seconds: 194_400.0
               }
             ]}
          ]
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      assert html =~ "task-lead-time"
      assert html =~ "W50"
    end

    test "hides completed tasks when grouped_tasks is empty" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "lead-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 72.0,
            median_hours: 48.0,
            min_hours: 24.0,
            max_hours: 120.0,
            count: 5
          },
          daily_lead_times: [],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      refute html =~ "Completed Tasks"
    end

    test "hides completed tasks when grouped_tasks key is missing" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "lead-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 72.0,
            median_hours: 48.0,
            min_hours: 24.0,
            max_hours: 120.0,
            count: 5
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      refute html =~ "Completed Tasks"
    end
  end

  describe "lead_time template - stat card icons" do
    test "renders colored stat card icons" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "lead-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 72.0,
            median_hours: 48.0,
            min_hours: 24.0,
            max_hours: 120.0,
            count: 10
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      # Check stat card color classes
      assert html =~ "stat-card-blue"
      assert html =~ "stat-card-purple"
      assert html =~ "stat-card-green"
      assert html =~ "stat-card-red"

      # Check icon background classes
      assert html =~ "stat-icon-blue"
      assert html =~ "stat-icon-purple"
      assert html =~ "stat-icon-green"
      assert html =~ "stat-icon-red"

      # Check SVG icons are present with correct fill colors
      assert html =~ "<svg"
      assert html =~ "fill=\"#2563eb\""
      assert html =~ "fill=\"#9333ea\""
      assert html =~ "fill=\"#16a34a\""
      assert html =~ "fill=\"#dc2626\""

      # Check stat labels
      assert html =~ "Average"
      assert html =~ "Median"
      assert html =~ "Minimum"
      assert html =~ "Maximum"
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

  describe "throughput template - completed goals section" do
    test "renders completed goals when present" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [],
          summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0},
          completed_goals: [
            %{
              identifier: "G1",
              title: "Major Feature Release",
              inserted_at: ~U[2024-01-01 08:00:00Z],
              completed_at: ~U[2024-01-10 16:00:00Z],
              completed_by_agent: "Claude Sonnet 4.5"
            },
            %{
              identifier: "G2",
              title: "Infrastructure Overhaul",
              inserted_at: ~U[2024-01-05 10:00:00Z],
              completed_at: ~U[2024-01-12 14:00:00Z],
              completed_by_agent: nil
            }
          ],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      assert html =~ "Completed Goals"
      assert html =~ "G1"
      assert html =~ "Major Feature Release"
      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "G2"
      assert html =~ "Infrastructure Overhaul"
    end

    test "hides completed goals section when empty" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [],
          summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0},
          completed_goals: [],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      refute html =~ "Completed Goals"
    end

    test "hides completed goals section when key is missing" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [],
          summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      refute html =~ "Completed Goals"
    end
  end

  describe "throughput template - grouped tasks section" do
    test "renders grouped tasks with full details" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [],
          summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0},
          completed_goals: [],
          grouped_tasks: [
            {~D[2024-01-10],
             [
               %{
                 identifier: "W42",
                 title: "Implement auth module",
                 inserted_at: ~U[2024-01-05 09:00:00Z],
                 claimed_at: ~U[2024-01-10 10:00:00Z],
                 completed_at: ~U[2024-01-10 15:00:00Z],
                 completed_by_agent: "Claude Sonnet 4.5"
               },
               %{
                 identifier: "W43",
                 title: "Add tests for auth",
                 inserted_at: ~U[2024-01-06 09:00:00Z],
                 claimed_at: ~U[2024-01-10 11:00:00Z],
                 completed_at: ~U[2024-01-10 16:00:00Z],
                 completed_by_agent: "GPT-4"
               }
             ]}
          ]
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      assert html =~ "Completed Tasks"
      assert html =~ "Jan 10, 2024"
      assert html =~ "2 tasks"
      assert html =~ "W42"
      assert html =~ "Implement auth module"
      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "W43"
      assert html =~ "Add tests for auth"
      assert html =~ "GPT-4"
      assert html =~ "Claimed:"
    end

    test "renders task without claimed_at" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [],
          summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0},
          completed_goals: [],
          grouped_tasks: [
            {~D[2024-01-10],
             [
               %{
                 identifier: "W50",
                 title: "Quick fix",
                 inserted_at: ~U[2024-01-10 08:00:00Z],
                 claimed_at: nil,
                 completed_at: ~U[2024-01-10 09:00:00Z],
                 completed_by_agent: nil
               }
             ]}
          ]
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      assert html =~ "W50"
      assert html =~ "Quick fix"
      assert html =~ "1 task"
      refute html =~ "Claimed:"
    end

    test "renders single task with singular label" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [],
          summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0},
          completed_goals: [],
          grouped_tasks: [
            {~D[2024-01-10],
             [
               %{
                 identifier: "W60",
                 title: "Solo task",
                 inserted_at: ~U[2024-01-09 09:00:00Z],
                 claimed_at: ~U[2024-01-10 10:00:00Z],
                 completed_at: ~U[2024-01-10 12:00:00Z],
                 completed_by_agent: "Agent A"
               }
             ]}
          ]
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      assert html =~ "1 task"
      refute html =~ "1 tasks"
    end

    test "hides grouped tasks section when empty" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [],
          summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0},
          completed_goals: [],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      refute html =~ "Completed Tasks"
    end
  end

  describe "throughput template - bar chart rendering" do
    test "calculates correct bar widths" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [
            %{date: ~D[2024-01-03], count: 10},
            %{date: ~D[2024-01-02], count: 5},
            %{date: ~D[2024-01-01], count: 1}
          ],
          summary_stats: %{total: 16, avg_per_day: 5.3, peak_day: ~D[2024-01-03], peak_count: 10},
          completed_goals: [],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      assert html =~ "width: 100.0%"
      assert html =~ "width: 50.0%"
      assert html =~ "width: 10.0%"
    end

    test "handles nil peak count in bar width calculation" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [
            %{date: ~D[2024-01-01], count: 3}
          ],
          summary_stats: %{total: 3, avg_per_day: 3.0, peak_day: ~D[2024-01-01], peak_count: nil},
          completed_goals: [],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      assert html =~ "width: 0%"
    end

    test "handles zero peak count in bar width calculation" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [
            %{date: ~D[2024-01-01], count: 0}
          ],
          summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0},
          completed_goals: [],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      assert html =~ "width: 0%"
      assert html =~ "0 tasks"
    end
  end

  describe "cycle_time template - no data branch" do
    test "renders no-data message when stats are nil" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "cycle-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{summary_stats: nil},
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      assert html =~ "No cycle time data available"
      refute html =~ "Average"
    end
  end

  describe "lead_time template - no data branch" do
    test "renders no-data message when stats are nil" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "lead-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{summary_stats: nil},
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      assert html =~ "No lead time data available"
      refute html =~ "Average"
    end
  end

  describe "wait_time template - partial data branches" do
    test "renders no-data for nil review wait stats only" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "wait-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: nil,
          backlog_wait_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 2.0,
            max_hours: 72.0
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      assert html =~ "No review wait time data available"
      refute html =~ "No backlog wait time data available"
    end

    test "renders no-data for nil backlog wait stats only" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "wait-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: %{
            average_hours: 4.0,
            median_hours: 3.0,
            min_hours: 1.0,
            max_hours: 12.0
          },
          backlog_wait_stats: nil
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      refute html =~ "No review wait time data available"
      assert html =~ "No backlog wait time data available"
    end

    test "renders no-data for both nil stats" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "wait-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: nil,
          backlog_wait_stats: nil
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      assert html =~ "No review wait time data available"
      assert html =~ "No backlog wait time data available"
    end
  end

  describe "cycle_time template - line chart rendering" do
    test "renders line chart when daily_cycle_times are present" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "cycle-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 5
          },
          daily_cycle_times: [
            %{date: ~D[2024-01-01], average_hours: 12.0},
            %{date: ~D[2024-01-02], average_hours: 18.0},
            %{date: ~D[2024-01-03], average_hours: 24.0}
          ],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      assert html =~ "Cycle Time Trend"
      assert html =~ "<svg"
      assert html =~ "<polyline"
      assert html =~ "Jan 01"
      assert html =~ "Jan 03"
    end

    test "renders line chart with single data point" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "cycle-time",
        time_range: :last_7_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 10.0,
            median_hours: 10.0,
            min_hours: 10.0,
            max_hours: 10.0,
            count: 1
          },
          daily_cycle_times: [
            %{date: ~D[2024-01-05], average_hours: 10.0}
          ],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      assert html =~ "Cycle Time Trend"
      assert html =~ "<svg"
      assert html =~ "<circle"
    end

    test "hides line chart when daily_cycle_times is empty" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "cycle-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 5
          },
          daily_cycle_times: [],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      refute html =~ "Cycle Time Trend"
      refute html =~ "<polyline"
    end

    test "hides line chart when daily_cycle_times key is missing" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "cycle-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 5
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      refute html =~ "Cycle Time Trend"
    end

    test "renders line chart with zero average_hours" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "cycle-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 0.0,
            median_hours: 0.0,
            min_hours: 0.0,
            max_hours: 0.0,
            count: 1
          },
          daily_cycle_times: [
            %{date: ~D[2024-01-01], average_hours: 0.0},
            %{date: ~D[2024-01-02], average_hours: 0.0}
          ],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      assert html =~ "Cycle Time Trend"
      assert html =~ "<svg"
    end
  end

  describe "cycle_time template - completed tasks section" do
    test "renders completed tasks grouped by date" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "cycle-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 3
          },
          daily_cycle_times: [],
          grouped_tasks: [
            {~D[2024-01-10],
             [
               %{
                 identifier: "W42",
                 title: "Implement auth module",
                 claimed_at: ~U[2024-01-10 08:00:00Z],
                 completed_at: ~U[2024-01-10 14:00:00Z],
                 completed_by_agent: "Claude Sonnet 4.5",
                 cycle_time_seconds: 21_600.0
               },
               %{
                 identifier: "W43",
                 title: "Add tests for auth",
                 claimed_at: ~U[2024-01-10 09:00:00Z],
                 completed_at: ~U[2024-01-10 16:00:00Z],
                 completed_by_agent: "GPT-4",
                 cycle_time_seconds: 25_200.0
               }
             ]}
          ]
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      assert html =~ "Completed Tasks"
      assert html =~ "Jan 10, 2024"
      assert html =~ "W42"
      assert html =~ "Implement auth module"
      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "W43"
      assert html =~ "Add tests for auth"
      assert html =~ "GPT-4"
      assert html =~ "Claimed:"
      assert html =~ "Completed:"
    end

    test "renders cycle time badge for each task" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "cycle-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 6.0,
            median_hours: 6.0,
            min_hours: 6.0,
            max_hours: 6.0,
            count: 1
          },
          daily_cycle_times: [],
          grouped_tasks: [
            {~D[2024-01-10],
             [
               %{
                 identifier: "W50",
                 title: "Quick task",
                 claimed_at: ~U[2024-01-10 08:00:00Z],
                 completed_at: ~U[2024-01-10 14:00:00Z],
                 completed_by_agent: nil,
                 cycle_time_seconds: 21_600.0
               }
             ]}
          ]
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      assert html =~ "task-cycle-time"
      assert html =~ "W50"
    end

    test "hides completed tasks when grouped_tasks is empty" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "cycle-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 5
          },
          daily_cycle_times: [],
          grouped_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      refute html =~ "Completed Tasks"
    end

    test "hides completed tasks when grouped_tasks key is missing" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "cycle-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 5
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      refute html =~ "Completed Tasks"
    end
  end

  describe "cycle_time template - stat card icons" do
    test "renders colored stat card icons" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "cycle-time",
        time_range: :last_30_days,
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
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      # Check stat card color classes
      assert html =~ "stat-card-blue"
      assert html =~ "stat-card-purple"
      assert html =~ "stat-card-green"
      assert html =~ "stat-card-red"

      # Check icon background classes
      assert html =~ "stat-icon-blue"
      assert html =~ "stat-icon-purple"
      assert html =~ "stat-icon-green"
      assert html =~ "stat-icon-red"

      # Check SVG icons are present
      assert html =~ "<svg"
      assert html =~ "fill=\"#2563eb\""
      assert html =~ "fill=\"#9333ea\""
      assert html =~ "fill=\"#16a34a\""
      assert html =~ "fill=\"#dc2626\""

      # Check stat labels
      assert html =~ "Average"
      assert html =~ "Median"
      assert html =~ "Minimum"
      assert html =~ "Maximum"
    end
  end

  describe "throughput template - stat card icons" do
    test "renders colored stat card icons" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [],
          summary_stats: %{total: 10, avg_per_day: 2.5, peak_day: ~D[2024-01-01], peak_count: 5}
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      # Check stat card color classes
      assert html =~ "stat-card-blue"
      assert html =~ "stat-card-green"
      assert html =~ "stat-card-purple"
      assert html =~ "stat-card-amber"

      # Check icon background classes
      assert html =~ "stat-icon-blue"
      assert html =~ "stat-icon-green"
      assert html =~ "stat-icon-purple"
      assert html =~ "stat-icon-amber"

      # Check SVG icons are present with correct colors
      assert html =~ "<svg"
      assert html =~ "stroke=\"#2563eb\""
      assert html =~ "stroke=\"#16a34a\""
      assert html =~ "stroke=\"#9333ea\""
      assert html =~ "stroke=\"#d97706\""

      # Check stat labels
      assert html =~ "Total Tasks"
      assert html =~ "Avg Per Day"
      assert html =~ "Peak Day"
      assert html =~ "Peak Count"
    end
  end

  describe "page footer" do
    test "throughput template includes Generated by Stride in page CSS" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "throughput",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          throughput: [],
          summary_stats: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.throughput(assigns))

      assert html =~ "@bottom-center"
      assert html =~ "Generated by Stride"
    end

    test "cycle_time template includes Generated by Stride in page CSS" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "cycle-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 5
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.cycle_time(assigns))

      assert html =~ "@bottom-center"
      assert html =~ "Generated by Stride"
    end

    test "wait_time template includes Generated by Stride in page CSS" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "wait-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 5
          },
          backlog_wait_stats: %{
            average_hours: 72.0,
            median_hours: 60.0,
            min_hours: 24.0,
            max_hours: 120.0,
            count: 10
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      assert html =~ "@bottom-center"
      assert html =~ "Generated by Stride"
      refute html =~ "Generated by Kanban"
    end

    test "lead_time template includes Generated by Stride in page CSS" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "lead-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          summary_stats: %{
            average_hours: 72.0,
            median_hours: 48.0,
            min_hours: 24.0,
            max_hours: 120.0,
            count: 5
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.lead_time(assigns))

      assert html =~ "@bottom-center"
      assert html =~ "Generated by Stride"
    end
  end

  describe "wait_time template - stat card icons" do
    test "renders colored stat card icons for review wait section" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "wait-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 5
          },
          backlog_wait_stats: %{
            average_hours: 72.0,
            median_hours: 60.0,
            min_hours: 24.0,
            max_hours: 120.0,
            count: 10
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      # Check stat card color classes
      assert html =~ "stat-card-blue"
      assert html =~ "stat-card-purple"
      assert html =~ "stat-card-green"
      assert html =~ "stat-card-red"

      # Check icon background classes
      assert html =~ "stat-icon-blue"
      assert html =~ "stat-icon-purple"
      assert html =~ "stat-icon-green"
      assert html =~ "stat-icon-red"

      # Check SVG icons are present with correct fill colors
      assert html =~ "<svg"
      assert html =~ "fill=\"#2563eb\""
      assert html =~ "fill=\"#9333ea\""
      assert html =~ "fill=\"#16a34a\""
      assert html =~ "fill=\"#dc2626\""

      # Check stat labels
      assert html =~ "Average"
      assert html =~ "Median"
      assert html =~ "Minimum"
      assert html =~ "Maximum"
    end
  end

  describe "wait_time template - review tasks section" do
    test "renders review tasks grouped by date" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "wait-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 2
          },
          backlog_wait_stats: nil,
          grouped_review_tasks: [
            {~D[2024-01-10],
             [
               %{
                 identifier: "W42",
                 title: "Implement auth module",
                 completed_at: ~U[2024-01-08 14:00:00Z],
                 reviewed_at: ~U[2024-01-10 10:00:00Z],
                 completed_by_agent: "Claude Sonnet 4.5",
                 review_wait_seconds: 158_400.0
               },
               %{
                 identifier: "W43",
                 title: "Add tests for auth",
                 completed_at: ~U[2024-01-09 16:00:00Z],
                 reviewed_at: ~U[2024-01-10 12:00:00Z],
                 completed_by_agent: "GPT-4",
                 review_wait_seconds: 72_000.0
               }
             ]}
          ],
          grouped_backlog_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      assert html =~ "Reviewed Tasks"
      assert html =~ "Jan 10, 2024"
      assert html =~ "W42"
      assert html =~ "Implement auth module"
      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "W43"
      assert html =~ "Add tests for auth"
      assert html =~ "GPT-4"
      assert html =~ "Completed:"
      assert html =~ "Reviewed:"
      assert html =~ "task-wait-time"
    end

    test "hides review tasks when grouped_review_tasks is empty" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "wait-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 5
          },
          backlog_wait_stats: nil,
          grouped_review_tasks: [],
          grouped_backlog_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      refute html =~ "Reviewed Tasks"
    end

    test "hides review tasks when grouped_review_tasks key is missing" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "wait-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: %{
            average_hours: 24.0,
            median_hours: 18.0,
            min_hours: 6.0,
            max_hours: 48.0,
            count: 5
          },
          backlog_wait_stats: nil
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      refute html =~ "Reviewed Tasks"
    end
  end

  describe "wait_time template - backlog tasks section" do
    test "renders backlog tasks grouped by date" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "wait-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: nil,
          backlog_wait_stats: %{
            average_hours: 48.0,
            median_hours: 36.0,
            min_hours: 12.0,
            max_hours: 96.0,
            count: 2
          },
          grouped_review_tasks: [],
          grouped_backlog_tasks: [
            {~D[2024-01-10],
             [
               %{
                 identifier: "W55",
                 title: "Build dashboard",
                 inserted_at: ~U[2024-01-05 08:00:00Z],
                 claimed_at: ~U[2024-01-10 14:00:00Z],
                 completed_by_agent: "Claude Sonnet 4.5",
                 backlog_wait_seconds: 453_600.0
               },
               %{
                 identifier: "W56",
                 title: "Fix login bug",
                 inserted_at: ~U[2024-01-08 09:00:00Z],
                 claimed_at: ~U[2024-01-10 11:00:00Z],
                 completed_by_agent: nil,
                 backlog_wait_seconds: 180_000.0
               }
             ]}
          ]
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      assert html =~ "Claimed Tasks"
      assert html =~ "Jan 10, 2024"
      assert html =~ "W55"
      assert html =~ "Build dashboard"
      assert html =~ "Claude Sonnet 4.5"
      assert html =~ "W56"
      assert html =~ "Fix login bug"
      assert html =~ "Created:"
      assert html =~ "Claimed:"
      assert html =~ "task-wait-time-indigo"
    end

    test "hides backlog tasks when grouped_backlog_tasks is empty" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "wait-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: nil,
          backlog_wait_stats: %{
            average_hours: 48.0,
            median_hours: 36.0,
            min_hours: 12.0,
            max_hours: 96.0,
            count: 5
          },
          grouped_review_tasks: [],
          grouped_backlog_tasks: []
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      refute html =~ "Claimed Tasks"
    end

    test "hides backlog tasks when grouped_backlog_tasks key is missing" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "wait-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: nil,
          backlog_wait_stats: %{
            average_hours: 48.0,
            median_hours: 36.0,
            min_hours: 12.0,
            max_hours: 96.0,
            count: 5
          }
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      refute html =~ "Claimed Tasks"
    end

    test "renders both review and backlog tasks together" do
      assigns = %{
        board: %{name: "Test Board", id: 1},
        metric: "wait-time",
        time_range: :last_30_days,
        agent_name: nil,
        exclude_weekends: false,
        agents: [],
        data: %{
          review_wait_stats: %{
            average_hours: 12.0,
            median_hours: 8.0,
            min_hours: 2.0,
            max_hours: 24.0,
            count: 1
          },
          backlog_wait_stats: %{
            average_hours: 48.0,
            median_hours: 36.0,
            min_hours: 12.0,
            max_hours: 96.0,
            count: 1
          },
          grouped_review_tasks: [
            {~D[2024-01-10],
             [
               %{
                 identifier: "W70",
                 title: "Review task",
                 completed_at: ~U[2024-01-09 10:00:00Z],
                 reviewed_at: ~U[2024-01-10 10:00:00Z],
                 completed_by_agent: "Agent A",
                 review_wait_seconds: 86_400.0
               }
             ]}
          ],
          grouped_backlog_tasks: [
            {~D[2024-01-10],
             [
               %{
                 identifier: "W71",
                 title: "Backlog task",
                 inserted_at: ~U[2024-01-07 08:00:00Z],
                 claimed_at: ~U[2024-01-10 14:00:00Z],
                 completed_by_agent: "Agent B",
                 backlog_wait_seconds: 280_800.0
               }
             ]}
          ]
        },
        generated_at: ~U[2024-01-15 10:00:00Z]
      }

      html = render_to_string(MetricsPdfHTML.wait_time(assigns))

      assert html =~ "Reviewed Tasks"
      assert html =~ "W70"
      assert html =~ "Review task"
      assert html =~ "Claimed Tasks"
      assert html =~ "W71"
      assert html =~ "Backlog task"
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
