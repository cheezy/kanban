defmodule KanbanWeb.MarketingComponentsTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MarketingComponents

  describe "marketing_nav/1" do
    test "renders the gradient logo, Stride wordmark, and 5 nav links" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      # Logo wordmark
      assert html =~ "Stride"

      # Gradient logo uses the brand tokens
      assert html =~ "var(--stride-orange)"
      assert html =~ "var(--stride-violet)"

      # The 5 marketing nav links (link text)
      assert html =~ "Product"
      assert html =~ "Workflows"
      assert html =~ "Pricing"
      assert html =~ "Resources"
      assert html =~ "About"
    end

    test "unauthenticated state renders Sign in and Start free" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      assert html =~ "Sign in"
      assert html =~ "Start free"
      assert html =~ ~s|href="/users/log-in"|
      assert html =~ ~s|href="/users/register"|

      # The authenticated CTA must NOT appear
      refute html =~ "Go to boards"
    end

    test "authenticated state renders Go to boards instead of Sign in / Start free" do
      assigns = %{current_scope: %{user: %{email: "alice@example.com"}}}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      assert html =~ "Go to boards"
      assert html =~ ~s|href="/boards"|

      # Anonymous CTAs must NOT appear
      refute html =~ "Sign in"
      refute html =~ "Start free"
    end

    test "renders the dark pill button using --ink (unauthenticated)" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      assert html =~ "background: var(--ink)"
    end

    test "renders the dark pill button using --ink (authenticated)" do
      assigns = %{current_scope: %{user: %{email: "bob@example.com"}}}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      assert html =~ "background: var(--ink)"
    end
  end

  describe "marketing_hero/1" do
    test "renders the violet release pill and the two-tone headline" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_hero current_scope={@current_scope} />
        """)

      # Release pill copy + colors
      assert html =~ "v2.4 · Atomic claims w/ capability matching"
      assert html =~ "var(--stride-violet-soft)"
      assert html =~ "var(--stride-violet-ink)"
      assert html =~ "Now in beta"

      # Headline split across two lines (line 2 uses --ink-4)
      assert html =~ "Tasks are conversations."
      assert html =~ "Your kanban can speak both ways."
      assert html =~ "color: var(--ink-4)"

      # Sub-copy
      assert html =~ "Stride is an AI-native kanban"

      # Microcopy trust signal
      assert html =~ "Free for solo · self-host on day one"
    end

    test "unauthenticated CTA is Start free and links to /users/register" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_hero current_scope={@current_scope} />
        """)

      assert html =~ "Start free"
      assert html =~ ~s|href="/users/register"|
      refute html =~ "Go to my boards"
    end

    test "authenticated CTA becomes Go to my boards and links to /boards" do
      assigns = %{current_scope: %{user: %{email: "alice@example.com"}}}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_hero current_scope={@current_scope} />
        """)

      assert html =~ "Go to my boards"
      assert html =~ ~s|href="/boards"|
      refute html =~ "Start free"
    end

    test "secondary CTA is Read the agent API and links to /resources" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_hero current_scope={@current_scope} />
        """)

      assert html =~ "Read the agent API"
      assert html =~ ~s|href="/resources"|
    end

    test "hero embeds the mini-board" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_hero current_scope={@current_scope} />
        """)

      # The mini-board contains task idents
      assert html =~ "W198"
      assert html =~ "Stride core"
    end
  end

  describe "marketing_mini_board/1" do
    test "renders all 4 column headers with their counts" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_mini_board />
        """)

      assert html =~ "Ready"
      assert html =~ "Doing"
      assert html =~ "Review"
      assert html =~ "Done"

      # Counts (whitespace-tolerant — HEEx pretty-prints inside span tags)
      assert html =~ ~r/>\s*8\s*</
      assert html =~ ~r/>\s*3\s*</
      assert html =~ ~r/>\s*5\s*</
      assert html =~ ~r/>\s*142\s*</
    end

    test "renders the titlebar with STR badge, Stride core, and agents online" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_mini_board />
        """)

      assert html =~ "STR"
      assert html =~ "Stride core"
      assert html =~ "4 agents online"
      assert html =~ "var(--stride-orange)"
    end

    test "renders every fixture task ident across all 4 columns" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_mini_board />
        """)

      for ident <- ~w(W198 W199 W193 W194 W189 W185) do
        assert html =~ ident, "expected mini-board to render ident #{ident}"
      end
    end

    test "renders hook output on Doing tasks and diff stats on Review tasks" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_mini_board />
        """)

      assert html =~ "before_doing · ok"
      assert html =~ "running"

      # Diff colors and tokens
      assert html =~ "+142"
      assert html =~ "−38"
      assert html =~ "47/47"
      assert html =~ "var(--st-done)"
      assert html =~ "var(--st-blocked)"
    end

    test "renders agent avatars as 4px-radius squares and human avatars as circles" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_mini_board />
        """)

      # At least one agent avatar with the square radius
      assert html =~ "border-radius: 4px"
      # At least one human avatar with the circle radius
      assert html =~ "border-radius: 50%"
      # Claude / Jamie K initials appear somewhere (whitespace-tolerant)
      assert html =~ ~r/>\s*C\s*</
      assert html =~ ~r/>\s*JK\s*</
    end
  end
end
