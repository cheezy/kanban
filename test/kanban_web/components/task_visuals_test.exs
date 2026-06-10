defmodule KanbanWeb.TaskVisualsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.AvatarPalette
  alias KanbanWeb.TaskVisuals

  describe "priority_dot/1" do
    for {level, token} <- [
          critical: "var(--pri-critical)",
          high: "var(--pri-high)",
          medium: "var(--pri-medium)",
          low: "var(--pri-low)"
        ] do
      test "renders the #{level} color token" do
        html = render_component(&TaskVisuals.priority_dot/1, priority: unquote(level))
        assert html =~ "background: #{unquote(token)};"
      end
    end

    test "unknown priority falls back to the ink token" do
      html = render_component(&TaskVisuals.priority_dot/1, priority: :unknown)
      assert html =~ "background: var(--ink-4);"
    end

    test "renders the 6px dot shape with flex-shrink" do
      html = render_component(&TaskVisuals.priority_dot/1, priority: :high)
      assert html =~ "width: 6px; height: 6px; border-radius: 50%;"
      assert html =~ "flex-shrink: 0;"
      assert html =~ ~s(aria-hidden="true")
    end
  end

  describe "type_icon/1" do
    test "defect renders the bug icon in blocked color" do
      html = render_component(&TaskVisuals.type_icon/1, type: :defect)
      assert html =~ "hero-bug-ant"
      assert html =~ "var(--st-blocked)"
    end

    test "goal renders the flag icon in violet" do
      html = render_component(&TaskVisuals.type_icon/1, type: :goal)
      assert html =~ "hero-flag"
      assert html =~ "var(--stride-violet)"
    end

    test "work renders the document icon in ready color" do
      html = render_component(&TaskVisuals.type_icon/1, type: :work)
      assert html =~ "hero-document-text"
      assert html =~ "var(--st-ready)"
    end

    test "defaults to the w-4 h-4 size" do
      html = render_component(&TaskVisuals.type_icon/1, type: :work)
      assert html =~ "w-4 h-4"
    end

    test "accepts the compact card size" do
      html = render_component(&TaskVisuals.type_icon/1, type: :defect, icon_class: "w-3 h-3")
      assert html =~ "w-3 h-3"
      refute html =~ "w-4 h-4"
    end
  end

  describe "status_pill/1" do
    test "renders the status label with its soft background and ink" do
      html = render_component(&TaskVisuals.status_pill/1, status: :ready, variant: :base)
      assert html =~ "background: var(--st-ready-soft);"
      assert html =~ "color: var(--st-ready);"
    end

    test "compact variant keeps the goal child row styling" do
      html = render_component(&TaskVisuals.status_pill/1, status: :ready, variant: :compact)
      assert html =~ "padding: 1px 7px;"
      refute html =~ "gap: 3px;"
      refute html =~ "border: 1px solid transparent;"
      refute html =~ "letter-spacing"
    end

    test "detail variant keeps the metadata grid styling" do
      html = render_component(&TaskVisuals.status_pill/1, status: :ready, variant: :detail)
      assert html =~ "padding: 2px 7px;"
      assert html =~ "gap: 3px;"
      assert html =~ "border: 1px solid transparent;"
      assert html =~ "letter-spacing: -0.005em;"
    end

    test "base variant keeps the task view band styling" do
      html = render_component(&TaskVisuals.status_pill/1, status: :ready, variant: :base)
      assert html =~ "padding: 2px 7px;"
      refute html =~ "gap: 3px;"
      refute html =~ "border: 1px solid transparent;"
      refute html =~ "letter-spacing"
    end

    test "background and color sit between the variant style fragments" do
      # Preserves the original property order in the style attribute.
      html = render_component(&TaskVisuals.status_pill/1, status: :ready, variant: :detail)
      [style] = Regex.run(~r/style="([^"]*)"/, html, capture: :all_but_first)
      assert style =~ ~r/border-radius: 999px;.*background:.*border: 1px solid transparent;/s
    end
  end

  describe "owner_palette/1" do
    test "an explicit binary palette wins" do
      assert TaskVisuals.owner_palette(%{palette: "oklch(1 2 3)"}) == "oklch(1 2 3)"
    end

    test "agents fall back to the agent palette by name" do
      owner = %{kind: :agent, name: "Claude"}
      assert TaskVisuals.owner_palette(owner) == AvatarPalette.for_agent("Claude")
    end

    test "humans and unknown kinds fall back to the human palette by id" do
      assert TaskVisuals.owner_palette(%{kind: :human, id: 7}) == AvatarPalette.for_human(7)
      assert TaskVisuals.owner_palette(%{id: 7}) == AvatarPalette.for_human(7)
    end

    test "a non-binary palette value is ignored" do
      owner = %{palette: :nope, id: 7}
      assert TaskVisuals.owner_palette(owner) == AvatarPalette.for_human(7)
    end
  end

  describe "ai_generated?/1" do
    test "true when either flag is set" do
      assert TaskVisuals.ai_generated?(%{ai_generated?: true})
      assert TaskVisuals.ai_generated?(%{ai_generated: true})
    end

    test "false when both flags are absent or false" do
      refute TaskVisuals.ai_generated?(%{})
      refute TaskVisuals.ai_generated?(%{ai_generated?: false, ai_generated: false})
    end
  end
end
