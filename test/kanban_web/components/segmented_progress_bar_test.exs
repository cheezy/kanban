defmodule KanbanWeb.SegmentedProgressBarTest do
  @moduledoc """
  Contract tests for `KanbanWeb.SegmentedProgressBar.segmented_progress/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.SegmentedProgressBar

  defp flow(overrides) do
    Map.merge(
      %{done: 0, review: 0, doing: 0, ready: 0, backlog: 0, total: 0},
      overrides
    )
  end

  describe "segmented_progress/1 — base render" do
    test "renders the data-segmented-progress marker and progressbar role" do
      assigns = %{flow: flow(%{done: 1, total: 1})}

      html =
        rendered_to_string(~H"""
        <SegmentedProgressBar.segmented_progress flow={@flow} />
        """)

      assert html =~ "data-segmented-progress"
      assert html =~ ~s(role="progressbar")
    end

    test "renders one segment per non-zero status bucket" do
      assigns = %{flow: flow(%{done: 1, doing: 2, total: 3})}

      html =
        rendered_to_string(~H"""
        <SegmentedProgressBar.segmented_progress flow={@flow} />
        """)

      assert html =~ ~s(title="done: 1")
      assert html =~ ~s(title="doing: 2")
      refute html =~ ~s(title="review:)
      refute html =~ ~s(title="ready:)
      refute html =~ ~s(title="backlog:)
    end

    test "renders segments in the canonical status order (done first, backlog last)" do
      assigns = %{flow: flow(%{done: 1, review: 1, doing: 1, ready: 1, backlog: 1, total: 5})}

      html =
        rendered_to_string(~H"""
        <SegmentedProgressBar.segmented_progress flow={@flow} />
        """)

      done_idx = :binary.match(html, "done: 1") |> elem(0)
      review_idx = :binary.match(html, "review: 1") |> elem(0)
      doing_idx = :binary.match(html, "doing: 1") |> elem(0)
      ready_idx = :binary.match(html, "ready: 1") |> elem(0)
      backlog_idx = :binary.match(html, "backlog: 1") |> elem(0)

      assert done_idx < review_idx
      assert review_idx < doing_idx
      assert doing_idx < ready_idx
      assert ready_idx < backlog_idx
    end

    test "renders empty bar (no segments) when total is zero" do
      assigns = %{flow: flow(%{total: 0})}

      html =
        rendered_to_string(~H"""
        <SegmentedProgressBar.segmented_progress flow={@flow} />
        """)

      refute html =~ ~s(title=)
    end

    test "tolerates a missing status key (treats as zero)" do
      assigns = %{flow: %{done: 2}}

      html =
        rendered_to_string(~H"""
        <SegmentedProgressBar.segmented_progress flow={@flow} />
        """)

      assert html =~ ~s(title="done: 2")
      refute html =~ ~s(title="backlog:)
    end
  end

  describe "segmented_progress/1 — size" do
    test ":sm renders at 96px wide and 10px tall (default)" do
      assigns = %{flow: flow(%{done: 1, total: 1})}

      html =
        rendered_to_string(~H"""
        <SegmentedProgressBar.segmented_progress flow={@flow} />
        """)

      assert html =~ "height: 10px;"
      assert html =~ "width: 96px;"
    end

    test ":lg renders full-width at 14px tall" do
      assigns = %{flow: flow(%{done: 1, total: 1})}

      html =
        rendered_to_string(~H"""
        <SegmentedProgressBar.segmented_progress flow={@flow} size={:lg} />
        """)

      assert html =~ "height: 14px;"
      assert html =~ "width: 100%;"
    end
  end

  describe "segmented_progress/1 — status colors" do
    for {status, token} <- [
          {:done, "var(--st-done)"},
          {:review, "var(--st-review)"},
          {:doing, "var(--st-doing)"},
          {:ready, "var(--st-ready)"},
          {:backlog, "var(--st-backlog)"}
        ] do
      test "#{status} segment uses #{token}" do
        assigns = %{flow: flow(%{unquote(status) => 1, total: 1})}

        html =
          rendered_to_string(~H"""
          <SegmentedProgressBar.segmented_progress flow={@flow} />
          """)

        assert html =~ "background: #{unquote(token)};"
      end
    end

    test ":done segment uses full opacity; others use 0.85" do
      assigns = %{flow: flow(%{done: 1, doing: 1, total: 2})}

      html =
        rendered_to_string(~H"""
        <SegmentedProgressBar.segmented_progress flow={@flow} />
        """)

      assert html =~ "opacity: 1;"
      assert html =~ "opacity: 0.85;"
    end
  end

  describe "segmented_progress/1 — accessibility" do
    test "uses the default aria-label when none is provided" do
      assigns = %{flow: flow(%{done: 1, total: 1})}

      html =
        rendered_to_string(~H"""
        <SegmentedProgressBar.segmented_progress flow={@flow} />
        """)

      assert html =~ ~s(aria-label="Goal progress by status")
    end

    test "honors a caller-supplied aria-label" do
      assigns = %{flow: flow(%{done: 1, total: 1})}

      html =
        rendered_to_string(~H"""
        <SegmentedProgressBar.segmented_progress
          flow={@flow}
          aria_label="Sprint progress"
        />
        """)

      assert html =~ ~s(aria-label="Sprint progress")
    end
  end
end
