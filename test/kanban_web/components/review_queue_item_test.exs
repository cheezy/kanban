defmodule KanbanWeb.ReviewQueueItemTest do
  @moduledoc """
  Tests for `KanbanWeb.ReviewQueueItem.review_queue_item/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.ReviewQueueItem

  defp item(overrides) do
    base = %{
      id: 42,
      identifier: "W101",
      title: "Wire up the new dropdown",
      priority: :high,
      completed_at: DateTime.add(DateTime.utc_now(), -120, :second),
      completed_by_agent: "Claude",
      created_by_agent: "Claude",
      actual_files_changed: "lib/a.ex, lib/b.ex, lib/c.ex",
      flag: nil,
      column: %{
        id: 1,
        name: "Review",
        board: %{id: 7, name: "Stride core"}
      }
    }

    deep_merge(base, overrides)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, l, r -> deep_merge(l, r) end)
  end

  defp deep_merge(_l, r), do: r

  defp render_item(overrides \\ %{}, opts \\ []) do
    assigns = %{
      item: item(overrides),
      selected: Keyword.get(opts, :selected, false),
      on_click: Keyword.get(opts, :on_click, "select_item")
    }

    rendered_to_string(~H"""
    <ReviewQueueItem.review_queue_item
      item={@item}
      selected={@selected}
      on_click={@on_click}
    />
    """)
  end

  describe "review_queue_item/1 — base rendering" do
    test "has the data-review-queue-item marker on the root" do
      assert render_item() =~ "data-review-queue-item"
    end

    test "renders the board chip with a 3-char uppercase label" do
      html = render_item()
      assert html =~ "data-review-queue-item-board-chip"
      assert html =~ ~r/>\s*STR\s*</
    end

    test "renders the task identifier" do
      assert render_item() =~ "W101"
    end

    test "renders the title" do
      assert render_item() =~ "Wire up the new dropdown"
    end

    test "wires phx-click and phx-value-id to the configured event" do
      html = render_item(%{}, on_click: "select_item")
      assert html =~ ~s(phx-click="select_item")
      assert html =~ ~s(phx-value-id="42")
    end
  end

  describe "review_queue_item/1 — priority dot" do
    test "uses var(--pri-high) for high priority" do
      html = render_item(%{priority: :high})
      assert html =~ "data-review-queue-item-priority-dot"
      assert html =~ "background: var(--pri-high)"
    end

    test "uses var(--pri-critical) for critical priority" do
      assert render_item(%{priority: :critical}) =~ "background: var(--pri-critical)"
    end
  end

  describe "review_queue_item/1 — flag pill" do
    test "renders the 'needs attention' pill when item.flag is set" do
      html = render_item(%{flag: :needs_attention})
      assert html =~ "data-review-queue-item-flag"
      assert html =~ "needs attention"
    end

    test "hides the pill when item.flag is nil" do
      refute render_item() =~ "data-review-queue-item-flag"
    end
  end

  describe "review_queue_item/1 — selected styling" do
    test "applies stride-orange left border when selected: true" do
      html = render_item(%{}, selected: true)
      assert html =~ "border-left: 2px solid var(--stride-orange)"
      assert html =~ "background: var(--surface-sunken)"
      assert html =~ ~s(aria-pressed="true")
    end

    test "applies transparent left border when selected: false" do
      html = render_item(%{}, selected: false)
      assert html =~ "border-left: 2px solid transparent"
      assert html =~ ~s(aria-pressed="false")
    end
  end

  describe "review_queue_item/1 — agent line" do
    test "renders the agent avatar and name" do
      html = render_item()
      assert html =~ "Claude"
    end

    test "omits the avatar+name when no agent is set", %{} do
      html = render_item(%{completed_by_agent: nil, created_by_agent: nil})
      refute html =~ "Claude"
    end

    test "renders the file count when actual_files_changed is set" do
      assert render_item() =~ "3 files"
    end

    test "omits the file count when actual_files_changed is nil" do
      html = render_item(%{actual_files_changed: nil})
      refute html =~ "files"
    end
  end

  describe "review_queue_item/1 — timestamp" do
    test "renders a relative timestamp when completed_at is set" do
      html = render_item()
      assert html =~ "data-review-queue-item-timestamp"
      assert html =~ "ago"
    end

    test "omits the timestamp when completed_at is nil" do
      html = render_item(%{completed_at: nil})
      refute html =~ "data-review-queue-item-timestamp"
    end

    test "renders 'just now' when completed less than 5 seconds ago" do
      now = DateTime.utc_now()
      html = render_item(%{completed_at: DateTime.add(now, -1, :second)})
      assert html =~ "just now"
    end

    test "renders Ns ago when completed in the last minute" do
      now = DateTime.utc_now()
      html = render_item(%{completed_at: DateTime.add(now, -30, :second)})
      assert html =~ ~r/3\ds ago/
    end

    test "renders Nh ago when completed hours ago" do
      now = DateTime.utc_now()
      html = render_item(%{completed_at: DateTime.add(now, -3 * 3600, :second)})
      assert html =~ "3h ago"
    end

    test "renders Nd ago when completed days ago" do
      now = DateTime.utc_now()
      html = render_item(%{completed_at: DateTime.add(now, -5 * 86_400, :second)})
      assert html =~ "5d ago"
    end
  end

  describe "review_queue_item/1 — agent fallback" do
    test "falls back to created_by_agent when completed_by_agent is nil" do
      html = render_item(%{completed_by_agent: nil, created_by_agent: "Codex"})
      assert html =~ "Codex"
    end

    test "treats an empty-string completed_by_agent as missing and falls back" do
      html = render_item(%{completed_by_agent: "", created_by_agent: "Aider"})
      assert html =~ "Aider"
    end
  end

  describe "review_queue_item/1 — board chip label fallback" do
    test "renders the · placeholder when the board name has no alphanumerics" do
      html =
        render_item(%{
          column: %{id: 1, name: "Review", board: %{id: 7, name: "!!!"}}
        })

      assert html =~ "data-review-queue-item-board-chip"
      # The chip falls back to a bullet when the upcased/stripped name is empty
      assert html =~ ~r/>\s*·\s*</
    end

    test "renders the · placeholder when no board is preloaded" do
      html =
        render_item(%{
          column: %{id: 1, name: "Review", board: nil}
        })

      assert html =~ ~r/>\s*·\s*</
    end
  end
end
