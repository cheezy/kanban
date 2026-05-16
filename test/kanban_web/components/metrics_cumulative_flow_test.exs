defmodule KanbanWeb.MetricsCumulativeFlowTest do
  @moduledoc """
  Tests for `KanbanWeb.MetricsCumulativeFlow.cumulative_flow/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MetricsCumulativeFlow

  defp snapshots(opts \\ []) do
    base = ~D[2026-05-01]

    backlog = Keyword.get(opts, :backlog, 20)
    ready = Keyword.get(opts, :ready, 5)
    doing = Keyword.get(opts, :doing, 6)
    review = Keyword.get(opts, :review, 3)
    done = Keyword.get(opts, :done, 40)

    for i <- 0..13 do
      %{
        date: Date.add(base, i),
        backlog: backlog,
        ready: ready,
        doing: doing,
        review: review,
        done: done + i
      }
    end
  end

  defp render_chart(snapshots) do
    assigns = %{snapshots: snapshots}

    rendered_to_string(~H"""
    <MetricsCumulativeFlow.cumulative_flow snapshots={@snapshots} />
    """)
  end

  describe "cumulative_flow/1 — markers and structure" do
    test "renders the root marker" do
      assert render_chart(snapshots()) =~ "data-metrics-cumulative-flow"
    end

    test "renders the responsive 800x200 SVG" do
      html = render_chart(snapshots())
      assert html =~ "viewBox=\"0 0 800 200\""
      assert html =~ "preserveAspectRatio=\"none\""
      assert html =~ "height: 200px"
    end

    test "renders one <path> per layer with the data attribute" do
      html = render_chart(snapshots())

      for name <- ~w(done review doing ready backlog) do
        assert html =~ ~s(data-metrics-cumulative-flow-layer="#{name}")
      end

      assert length(Regex.scan(~r/data-metrics-cumulative-flow-layer/, html)) == 5
    end
  end

  describe "cumulative_flow/1 — colors and legend" do
    test "each layer is tinted with its status token" do
      html = render_chart(snapshots())

      assert html =~ "var(--st-done)"
      assert html =~ "var(--st-review)"
      assert html =~ "var(--st-doing)"
      assert html =~ "var(--st-ready)"
      assert html =~ "var(--st-backlog)"
    end

    test "layers use 0.8 fill-opacity" do
      assert render_chart(snapshots()) =~ ~s(fill-opacity="0.8")
    end

    test "renders the five legend swatches with translated labels" do
      html = render_chart(snapshots())

      for label <- ~w(Backlog Ready Doing Review Done) do
        assert html =~ label
      end
    end

    test "no hardcoded Tailwind greys or daisyUI base colors" do
      html = render_chart(snapshots())
      refute html =~ "text-gray-"
      refute html =~ "bg-gray-"
      refute html =~ "bg-white"
      refute html =~ "bg-base-100"
    end
  end

  describe "build_layers/1 — stacking math" do
    test "returns an empty list for an empty input" do
      assert MetricsCumulativeFlow.build_layers([]) == []
    end

    test "returns 5 layers in bottom-to-top order matching the design source" do
      layers = MetricsCumulativeFlow.build_layers(snapshots())
      assert Enum.map(layers, & &1.name) == [:done, :review, :doing, :ready, :backlog]
    end

    test "each layer's :bottom equals the previous layer's :top (stacking)" do
      layers = MetricsCumulativeFlow.build_layers(snapshots())

      layers
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [lower, upper] ->
        assert upper.bottom == lower.top
      end)
    end

    test "the bottom-most layer (:done) starts from a zero bottom row" do
      layers = MetricsCumulativeFlow.build_layers(snapshots())
      [%{name: :done, bottom: bottom} | _] = layers
      assert bottom == List.duplicate(0, 14)
    end

    test "the topmost layer's :top equals the per-day sum of all five buckets" do
      snaps = snapshots(backlog: 1, ready: 2, doing: 3, review: 4, done: 5)
      layers = MetricsCumulativeFlow.build_layers(snaps)
      top = List.last(layers).top

      expected =
        snaps
        |> Enum.map(fn s -> s.backlog + s.ready + s.doing + s.review + s.done end)

      assert top == expected
    end

    test "handles missing keys by treating them as zero" do
      partial = [%{date: ~D[2026-05-01], doing: 10}]
      [done, _, doing, _, _] = MetricsCumulativeFlow.build_layers(partial)
      assert done.top == [0]
      assert doing.top == [10]
    end
  end
end
