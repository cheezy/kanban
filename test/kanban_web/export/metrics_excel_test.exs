defmodule KanbanWeb.MetricsExcelExportTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.MetricsExcelExport

  @ai_board %{name: "AI Board", ai_optimized_board: true}
  @regular_board %{name: "Regular Board", ai_optimized_board: false}
  @default_opts [time_range: :last_30_days, exclude_weekends: false]

  defp make_task(overrides \\ %{}) do
    Map.merge(
      %{
        id: 1,
        identifier: "W1",
        title: "Test Task",
        inserted_at: ~U[2026-01-15 10:00:00Z],
        claimed_at: ~U[2026-01-16 10:00:00Z],
        completed_at: ~U[2026-01-17 10:00:00Z],
        completed_by_agent: "Agent Alpha"
      },
      overrides
    )
  end

  defp make_cycle_time_task(overrides \\ %{}) do
    make_task(Map.merge(%{cycle_time_seconds: 86_400.0}, overrides))
  end

  defp make_lead_time_task(overrides \\ %{}) do
    make_task(Map.merge(%{lead_time_seconds: 172_800.0}, overrides))
  end

  defp make_review_wait_task(overrides \\ %{}) do
    Map.merge(
      %{
        id: 1,
        identifier: "W1",
        title: "Review Task",
        completed_at: ~U[2026-01-17 10:00:00Z],
        reviewed_at: ~U[2026-01-18 10:00:00Z],
        completed_by_agent: "Agent Alpha",
        review_wait_seconds: 86_400.0
      },
      overrides
    )
  end

  defp make_backlog_wait_task(overrides \\ %{}) do
    Map.merge(
      %{
        id: 1,
        identifier: "W1",
        title: "Backlog Task",
        inserted_at: ~U[2026-01-15 10:00:00Z],
        claimed_at: ~U[2026-01-16 10:00:00Z],
        completed_by_agent: "Agent Alpha",
        backlog_wait_seconds: 86_400.0
      },
      overrides
    )
  end

  defp assert_valid_xlsx({:ok, binary}) do
    assert is_binary(binary)
    assert byte_size(binary) > 0
    assert <<0x50, 0x4B, _rest::binary>> = binary
    binary
  end

  # ── AI-Optimized Board: Throughput ──

  describe "generate/4 - throughput (AI-optimized)" do
    test "returns valid xlsx binary" do
      data = %{
        tasks: [make_task()],
        completed_goals: []
      }

      result = MetricsExcelExport.generate(@ai_board, "throughput", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "includes task data in output" do
      data = %{
        tasks: [
          make_task(%{identifier: "W10", title: "Important Feature"}),
          make_task(%{identifier: "W11", title: "Another Task", id: 2})
        ],
        completed_goals: [
          %{
            id: 3,
            identifier: "G1",
            title: "Big Goal",
            inserted_at: ~U[2026-01-01 10:00:00Z],
            completed_at: ~U[2026-01-20 10:00:00Z],
            completed_by_agent: "Agent Beta"
          }
        ]
      }

      result = MetricsExcelExport.generate(@ai_board, "throughput", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "handles empty tasks and goals" do
      data = %{tasks: [], completed_goals: []}
      result = MetricsExcelExport.generate(@ai_board, "throughput", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "handles nil agent names gracefully" do
      data = %{
        tasks: [make_task(%{completed_by_agent: nil})],
        completed_goals: []
      }

      result = MetricsExcelExport.generate(@ai_board, "throughput", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "includes agent filter in header when specified" do
      opts = Keyword.put(@default_opts, :agent_name, "Agent Alpha")
      data = %{tasks: [], completed_goals: []}
      result = MetricsExcelExport.generate(@ai_board, "throughput", opts, data)
      assert_valid_xlsx(result)
    end
  end

  # ── Regular Board: Throughput ──

  describe "generate/4 - throughput (regular board)" do
    test "returns valid xlsx binary" do
      data = %{
        tasks: [make_task(%{claimed_at: nil, completed_by_agent: nil})],
        completed_goals: []
      }

      result = MetricsExcelExport.generate(@regular_board, "throughput", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "works without claimed_at or agent data" do
      data = %{
        tasks: [
          make_task(%{claimed_at: nil, completed_by_agent: nil}),
          make_task(%{id: 2, identifier: "W2", claimed_at: nil, completed_by_agent: nil})
        ],
        completed_goals: []
      }

      result = MetricsExcelExport.generate(@regular_board, "throughput", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "handles empty data" do
      data = %{tasks: [], completed_goals: []}
      result = MetricsExcelExport.generate(@regular_board, "throughput", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "does not include agent filter in header" do
      opts = Keyword.put(@default_opts, :agent_name, "Agent Alpha")
      data = %{tasks: [], completed_goals: []}
      result = MetricsExcelExport.generate(@regular_board, "throughput", opts, data)
      assert_valid_xlsx(result)
    end
  end

  # ── AI-Optimized Board: Cycle Time ──

  describe "generate/4 - cycle time (AI-optimized)" do
    test "returns valid xlsx binary" do
      data = %{
        summary_stats: %{average: 86_400, median: 86_400, p90: 172_800},
        tasks: [make_cycle_time_task()],
        grouped_tasks: [],
        daily_cycle_times: []
      }

      result = MetricsExcelExport.generate(@ai_board, "cycle-time", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "formats cycle time duration correctly" do
      data = %{
        summary_stats: %{},
        tasks: [
          make_cycle_time_task(%{cycle_time_seconds: 3600.0}),
          make_cycle_time_task(%{id: 2, identifier: "W2", cycle_time_seconds: 259_200.0})
        ],
        grouped_tasks: [],
        daily_cycle_times: []
      }

      result = MetricsExcelExport.generate(@ai_board, "cycle-time", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "handles empty tasks" do
      data = %{summary_stats: %{}, tasks: [], grouped_tasks: [], daily_cycle_times: []}
      result = MetricsExcelExport.generate(@ai_board, "cycle-time", @default_opts, data)
      assert_valid_xlsx(result)
    end
  end

  # ── Regular Board: Cycle Time ──

  describe "generate/4 - cycle time (regular board)" do
    test "returns valid xlsx binary" do
      data = %{
        summary_stats: %{},
        tasks: [make_cycle_time_task(%{completed_by_agent: nil})],
        grouped_tasks: [],
        daily_cycle_times: []
      }

      result = MetricsExcelExport.generate(@regular_board, "cycle-time", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "handles empty tasks" do
      data = %{summary_stats: %{}, tasks: [], grouped_tasks: [], daily_cycle_times: []}
      result = MetricsExcelExport.generate(@regular_board, "cycle-time", @default_opts, data)
      assert_valid_xlsx(result)
    end
  end

  # ── AI-Optimized Board: Lead Time ──

  describe "generate/4 - lead time (AI-optimized)" do
    test "returns valid xlsx binary" do
      data = %{
        summary_stats: %{},
        tasks: [make_lead_time_task()],
        grouped_tasks: [],
        daily_lead_times: []
      }

      result = MetricsExcelExport.generate(@ai_board, "lead-time", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "handles empty tasks" do
      data = %{summary_stats: %{}, tasks: [], grouped_tasks: [], daily_lead_times: []}
      result = MetricsExcelExport.generate(@ai_board, "lead-time", @default_opts, data)
      assert_valid_xlsx(result)
    end
  end

  # ── Regular Board: Lead Time ──

  describe "generate/4 - lead time (regular board)" do
    test "returns valid xlsx binary" do
      data = %{
        summary_stats: %{},
        tasks: [make_lead_time_task(%{completed_by_agent: nil})],
        grouped_tasks: [],
        daily_lead_times: []
      }

      result = MetricsExcelExport.generate(@regular_board, "lead-time", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "handles empty tasks" do
      data = %{summary_stats: %{}, tasks: [], grouped_tasks: [], daily_lead_times: []}
      result = MetricsExcelExport.generate(@regular_board, "lead-time", @default_opts, data)
      assert_valid_xlsx(result)
    end
  end

  # ── AI-Optimized Board: Wait Time ──

  describe "generate/4 - wait time (AI-optimized)" do
    test "returns valid xlsx binary with review and backlog sections" do
      data = %{
        review_wait_stats: %{},
        backlog_wait_stats: %{},
        grouped_review_tasks: [
          {~D[2026-01-18], [make_review_wait_task()]}
        ],
        grouped_backlog_tasks: [
          {~D[2026-01-16], [make_backlog_wait_task()]}
        ]
      }

      result = MetricsExcelExport.generate(@ai_board, "wait-time", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "handles empty review and backlog tasks" do
      data = %{
        review_wait_stats: %{},
        backlog_wait_stats: %{},
        grouped_review_tasks: [],
        grouped_backlog_tasks: []
      }

      result = MetricsExcelExport.generate(@ai_board, "wait-time", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "handles nil agent in wait time tasks" do
      data = %{
        review_wait_stats: %{},
        backlog_wait_stats: %{},
        grouped_review_tasks: [
          {~D[2026-01-18], [make_review_wait_task(%{completed_by_agent: nil})]}
        ],
        grouped_backlog_tasks: [
          {~D[2026-01-16], [make_backlog_wait_task(%{completed_by_agent: nil})]}
        ]
      }

      result = MetricsExcelExport.generate(@ai_board, "wait-time", @default_opts, data)
      assert_valid_xlsx(result)
    end
  end

  # ── Regular Board: Wait Time ──

  describe "generate/4 - wait time (regular board)" do
    test "returns valid xlsx without review section" do
      data = %{
        review_wait_stats: %{},
        backlog_wait_stats: %{},
        grouped_review_tasks: [],
        grouped_backlog_tasks: [
          {~D[2026-01-16], [make_backlog_wait_task(%{completed_by_agent: nil})]}
        ]
      }

      result = MetricsExcelExport.generate(@regular_board, "wait-time", @default_opts, data)
      assert_valid_xlsx(result)
    end

    test "handles empty backlog tasks" do
      data = %{
        review_wait_stats: %{},
        backlog_wait_stats: %{},
        grouped_review_tasks: [],
        grouped_backlog_tasks: []
      }

      result = MetricsExcelExport.generate(@regular_board, "wait-time", @default_opts, data)
      assert_valid_xlsx(result)
    end
  end

  # ── Time range and options ──

  describe "generate/4 - time range options" do
    test "handles all time range values" do
      data = %{tasks: [], completed_goals: []}

      for time_range <- [:today, :last_7_days, :last_30_days, :last_90_days, :all_time] do
        opts = Keyword.put(@default_opts, :time_range, time_range)
        result = MetricsExcelExport.generate(@ai_board, "throughput", opts, data)
        assert_valid_xlsx(result)
      end
    end

    test "handles exclude_weekends option" do
      data = %{tasks: [], completed_goals: []}
      opts = Keyword.put(@default_opts, :exclude_weekends, true)
      result = MetricsExcelExport.generate(@ai_board, "throughput", opts, data)
      assert_valid_xlsx(result)
    end

    test "handles nil time_range gracefully" do
      data = %{tasks: [], completed_goals: []}
      opts = Keyword.put(@default_opts, :time_range, nil)
      result = MetricsExcelExport.generate(@ai_board, "throughput", opts, data)
      assert_valid_xlsx(result)
    end
  end

  # ── Unknown metric ──

  describe "generate/4 - unknown metric" do
    test "returns valid xlsx for unknown metric" do
      result = MetricsExcelExport.generate(@ai_board, "unknown", @default_opts, %{})
      assert_valid_xlsx(result)
    end
  end

  # ── Formula-injection sanitization (W391) ──
  #
  # Verifies that user-controlled string cells (task title, identifier,
  # completed_by_agent, board.name, agent_name filter) are sanitized so Excel /
  # LibreOffice will render formula-prefixed values as literal text. We assert
  # by extracting xl/sharedStrings.xml from the xlsx zip and inspecting the
  # decoded string table.

  defp extract_shared_strings({:ok, bytes}) do
    {:ok, handle} = :zip.zip_open(bytes, [:memory])
    {:ok, {_path, xml}} = :zip.zip_get(~c"xl/sharedStrings.xml", handle)
    :zip.zip_close(handle)
    to_string(xml)
  end

  describe "generate/4 - formula injection sanitization" do
    setup do
      malicious_task =
        make_task(%{
          identifier: "=cmd|'/C calc'!A1",
          title: "+HYPERLINK(\"http://evil/\")",
          completed_by_agent: "-malicious"
        })

      malicious_board = %{name: "@phish.example.com", ai_optimized_board: true}

      data = %{tasks: [malicious_task], completed_goals: []}

      %{data: data, board: malicious_board}
    end

    test "wraps formula-prefixed task identifier with apostrophe", %{data: data, board: board} do
      xml =
        extract_shared_strings(
          MetricsExcelExport.generate(board, "throughput", @default_opts, data)
        )

      assert xml =~ "&apos;=cmd|&apos;/C calc&apos;!A1" or xml =~ "'=cmd|"
      refute xml =~ ~r/<t[^>]*>=cmd/
    end

    test "wraps formula-prefixed task title with apostrophe", %{data: data, board: board} do
      xml =
        extract_shared_strings(
          MetricsExcelExport.generate(board, "throughput", @default_opts, data)
        )

      refute xml =~ ~r/<t[^>]*>\+HYPERLINK/
      assert xml =~ "'+HYPERLINK" or xml =~ "&apos;+HYPERLINK"
    end

    test "wraps formula-prefixed completed_by_agent with apostrophe",
         %{data: data, board: board} do
      xml =
        extract_shared_strings(
          MetricsExcelExport.generate(board, "throughput", @default_opts, data)
        )

      refute xml =~ ~r/<t[^>]*>-malicious/
      assert xml =~ "'-malicious" or xml =~ "&apos;-malicious"
    end

    test "wraps formula-prefixed agent_name filter option", %{data: data, board: board} do
      opts = Keyword.put(@default_opts, :agent_name, "=HACK()")
      xml = extract_shared_strings(MetricsExcelExport.generate(board, "throughput", opts, data))
      refute xml =~ ~r/<t[^>]*>Agent: =HACK/
      assert xml =~ "Agent: '=HACK" or xml =~ "Agent: &apos;=HACK"
    end

    test "wraps tab-prefixed title with apostrophe", %{board: board} do
      data = %{
        tasks: [make_task(%{identifier: "W1", title: "\tSUM(A1:A10)"})],
        completed_goals: []
      }

      xml =
        extract_shared_strings(
          MetricsExcelExport.generate(board, "throughput", @default_opts, data)
        )

      refute xml =~ ~r/<t[^>]*>\tSUM/

      assert xml =~ "'\tSUM" or xml =~ "&apos;\tSUM" or xml =~ "&apos;&#9;SUM" or
               xml =~ "&apos;&#x9;SUM"
    end

    test "wraps CR-prefixed title with apostrophe", %{board: board} do
      data = %{
        tasks: [make_task(%{identifier: "W1", title: "\r=BAD()"})],
        completed_goals: []
      }

      xml =
        extract_shared_strings(
          MetricsExcelExport.generate(board, "throughput", @default_opts, data)
        )

      refute xml =~ ~r/<t[^>]*>\r=BAD/

      assert xml =~ "'\r=BAD" or xml =~ "&apos;\r=BAD" or xml =~ "&apos;&#13;=BAD" or
               xml =~ "&apos;&#xD;=BAD"
    end

    test "leaves non-prefixed strings unchanged", %{board: board} do
      benign = make_task(%{identifier: "W42", title: "Normal Task", completed_by_agent: "Alice"})
      data = %{tasks: [benign], completed_goals: []}

      xml =
        extract_shared_strings(
          MetricsExcelExport.generate(board, "throughput", @default_opts, data)
        )

      assert xml =~ "W42"
      refute xml =~ "'W42"
      assert xml =~ "Normal Task"
      refute xml =~ "'Normal Task"
    end
  end
end
