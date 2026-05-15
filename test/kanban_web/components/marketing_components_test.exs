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

      # Uses the canonical Stride logo SVG (shared with the app nav)
      assert html =~ "/images/logos/abstract-s-motion.svg"

      # The 5 marketing nav links (link text)
      assert html =~ "Product"
      assert html =~ "Workflows"
      assert html =~ "Pricing"
      assert html =~ "Resources"
      assert html =~ "About"

      # Product, Workflows, and Pricing point at their dedicated pages
      # (not in-page anchors)
      assert html =~ ~s|href="/product"|
      assert html =~ ~s|href="/workflows"|
      assert html =~ ~s|href="/pricing"|
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

    test "authenticated state renders Sign out + Go to boards instead of Sign in / Start free" do
      assigns = %{current_scope: %{user: %{email: "alice@example.com", type: :member}}}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      assert html =~ "Go to boards"
      assert html =~ ~s|href="/boards"|

      # Sign out appears next to Go to boards and DELETEs the session
      assert html =~ "Sign out"
      assert html =~ ~s|href="/users/log-out"|

      # Anonymous CTAs must NOT appear
      refute html =~ "Sign in"
      refute html =~ "Start free"

      # Non-admin must NOT see admin-only links
      refute html =~ "Dashboard"
      refute html =~ "Error Tracker"
    end

    test "renders the language switcher with the current locale active" do
      assigns = %{current_scope: nil, current_locale: "fr"}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav
          current_scope={@current_scope}
          current_locale={@current_locale}
        />
        """)

      # Switcher trigger shows the active locale code uppercase
      assert html =~ ~r/>\s*FR\s*</
      # Dropdown lists every supported locale by display name
      assert html =~ "English"
      assert html =~ "Français"
      assert html =~ "Español"
      assert html =~ "Português"
      assert html =~ "Deutsch"
      assert html =~ "日本語"
      assert html =~ "中文"
      # Each locale option POSTs to /locale/:code
      assert html =~ ~s|action="/locale/en"|
      assert html =~ ~s|action="/locale/fr"|
      # Phoenix dropdown hook is wired
      assert html =~ ~s|phx-hook="Dropdown"|
    end

    test "admin user sees Dashboard and Error Tracker links" do
      assigns = %{current_scope: %{user: %{email: "admin@example.com", type: :admin}}}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      assert html =~ "Dashboard"
      assert html =~ ~s|href="/admin/dashboard"|
      assert html =~ "Error Tracker"
      assert html =~ ~s|href="/admin/errors"|

      # Sign out and Go to boards still appear for admins
      assert html =~ "Sign out"
      assert html =~ "Go to boards"
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
      assigns = %{current_scope: %{user: %{email: "bob@example.com", type: :member}}}

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

      # Release pill — assert the violet-pill styling and that a version
      # prefix is present, but do NOT pin the exact version or release-copy
      # since both change with every release.
      assert html =~ "var(--stride-violet-soft)"
      assert html =~ "var(--stride-violet-ink)"

      assert html =~ ~r/v\d+\.\d/,
             "expected a 'v<major>.<minor>' release version somewhere in the pill"

      # Headline split across two lines (line 2 uses --ink-4)
      assert html =~ "Tasks are conversations."
      assert html =~ "speak both ways."
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

    test "secondary CTA is Read the agent API and links to the GitHub README" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_hero current_scope={@current_scope} />
        """)

      assert html =~ "Read the agent API"
      # External link to the agent API README on GitHub
      assert html =~ ~s|href="https://github.com/cheezy/kanban/blob/main/docs/api/README.md"|
      assert html =~ ~s|target="_blank"|
      assert html =~ ~s|rel="noopener noreferrer"|
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
        <KanbanWeb.MarketingMiniBoard.marketing_mini_board />
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
        <KanbanWeb.MarketingMiniBoard.marketing_mini_board />
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
        <KanbanWeb.MarketingMiniBoard.marketing_mini_board />
        """)

      for ident <- ~w(W198 W199 W193 W194 W189 W185) do
        assert html =~ ident, "expected mini-board to render ident #{ident}"
      end
    end

    test "renders hook output on Doing tasks and diff stats on Review tasks" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <KanbanWeb.MarketingMiniBoard.marketing_mini_board />
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
        <KanbanWeb.MarketingMiniBoard.marketing_mini_board />
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

  describe "marketing_belief_band/1" do
    test "renders the ucase label, two-line headline, and two body paragraphs" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_belief_band />
        """)

      # ucase label
      assert html =~ "A new contract"
      assert html =~ ~s|class="ucase"|

      # Two-line headline
      assert html =~ "AI agents are first-class teammates,"
      assert html =~ "not bots you babysit."

      # Orange emphasis span on the second line
      assert html =~ "color: var(--stride-orange);"

      # Two body paragraphs in the right column
      assert html =~ "Most tools bolt AI on as a sidebar"
      assert html =~ "Humans get a fast, calm board"
    end

    test "uses the 1.2fr / 1fr two-column grid layout on md+" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_belief_band />
        """)

      # Responsive Tailwind arbitrary-value variant; mobile is single-column.
      assert html =~ "md:[grid-template-columns:1.2fr_1fr]"
      assert html =~ "grid-cols-1"
    end
  end

  describe "marketing_how_it_works/1" do
    test "renders the section heading and microcopy" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_how_it_works />
        """)

      assert html =~ "How it works"
      assert html =~ "One loop. Two roles."
    end

    test "renders all four step cells with mono step numbers, titles, and body copy" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_how_it_works />
        """)

      # Mono step numbers
      for n <- ["01", "02", "03", "04"] do
        assert html =~ ~r/>\s*#{n}\s*</, "expected step number #{n}"
      end

      # Step titles
      assert html =~ "You write the task"
      assert html =~ "An agent claims it"
      assert html =~ "Hooks run on their machine"
      assert html =~ "You approve or send back"

      # Body excerpts
      assert html =~ "The schema is the conversation."
      assert html =~ "Atomic. SKIP LOCKED."
      assert html =~ "mix test, gh pr create"
      assert html =~ "approves and runs after_review"
    end

    test "renders the 4-column grid with separator borders on the first 3 cells (lg+)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_how_it_works />
        """)

      # Responsive: stacked on mobile, 4 cols on lg
      assert html =~ "grid-cols-1"
      assert html =~ "lg:grid-cols-4"
      # First 3 cells get border-b (mobile separator) + lg:border-r (desktop separator)
      separator_count =
        html
        |> String.split("lg:border-r")
        |> length()
        |> Kernel.-(1)

      assert separator_count == 3,
             "expected exactly 3 lg:border-r separators on the first 3 cells, got #{separator_count}"
    end

    test "step icons use the colored token per step" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_how_it_works />
        """)

      # Each step has its color
      assert html =~ "color: var(--ink);"
      assert html =~ "color: var(--st-doing);"
      assert html =~ "color: var(--stride-orange);"
      assert html =~ "color: var(--st-done);"
    end
  end

  describe "marketing_feature_grid/1" do
    test "renders 6 feature cards in a 3-column grid on lg+" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_feature_grid />
        """)

      # Responsive: 1 col mobile / 2 cols md / 3 cols lg
      assert html =~ "grid-cols-1"
      assert html =~ "md:grid-cols-2"
      assert html =~ "lg:grid-cols-3"

      # All 6 titles present
      assert html =~ "Capability matching"
      assert html =~ "Client-side hooks"
      assert html =~ "Conflict prevention"
      assert html =~ "Review at the speed of approval"
      assert html =~ "Goals → tasks → outcomes"
      assert html =~ "Real metrics that include AI"
    end

    test "audience tags use the correct ink color per audience" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_feature_grid />
        """)

      # Agents: orange-ink
      assert html =~ "color: var(--stride-orange-ink);"
      # Humans: violet-ink
      assert html =~ "color: var(--stride-violet-ink);"
      # Teams: neutral ink-3
      assert html =~ "color: var(--ink-3);"

      # All 3 audience labels appear
      assert html =~ "For agents"
      assert html =~ "For humans"
      assert html =~ "For teams"
    end

    test "cards use --surface background, --line border, and 154px min-height" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_feature_grid />
        """)

      assert html =~ "background: var(--surface);"
      assert html =~ "border: 1px solid var(--line);"
      assert html =~ "min-height: 154px;"
    end
  end

  describe "marketing_numbers_band/1" do
    test "renders 4 tabular-numeral metrics with labels" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <KanbanWeb.MarketingClosing.marketing_numbers_band />
        """)

      # Values
      assert html =~ "0.4s"
      assert html =~ "94.6%"
      assert html =~ "17m"
      assert html =~ "23.6 / day"

      # Labels
      assert html =~ "Agent-to-task latency · p95"
      assert html =~ "Test coverage in core"
      assert html =~ "Median time to human review"
      assert html =~ "Tasks shipped per active board"

      # Tabular-numerals feature for line-up — quotes are HTML-escaped in
      # the rendered output (`&quot;tnum&quot;`), so check for the
      # `font-feature-settings: ` prefix with the escaped `tnum` token.
      assert html =~ "font-feature-settings: &quot;tnum&quot;"
      # Responsive: 2 cols on mobile, 4 cols on md+
      assert html =~ "grid-cols-2"
      assert html =~ "md:grid-cols-4"
    end
  end

  describe "marketing_cta_section/1" do
    test "renders headline with orange emphasis on 'approving them.'" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <KanbanWeb.MarketingClosing.marketing_cta_section current_scope={@current_scope} />
        """)

      assert html =~ "Stop writing every line."
      assert html =~ "approving them."
      # Orange emphasis on the second-line phrase
      assert html =~ "color: var(--stride-orange);"

      # Sub-copy
      assert html =~ "Free for solo developers and small teams"
    end

    test "unauthenticated state shows Start free linking to /users/register" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <KanbanWeb.MarketingClosing.marketing_cta_section current_scope={@current_scope} />
        """)

      assert html =~ "Start free"
      assert html =~ ~s|href="/users/register"|
      assert html =~ "Talk to a human"
    end

    test "authenticated state swaps CTA to Go to my boards linking to /boards" do
      assigns = %{current_scope: %{user: %{email: "alice@example.com"}}}

      html =
        rendered_to_string(~H"""
        <KanbanWeb.MarketingClosing.marketing_cta_section current_scope={@current_scope} />
        """)

      assert html =~ "Go to my boards"
      assert html =~ ~s|href="/boards"|
      refute html =~ "Start free"
    end
  end

  describe "marketing_footer/1" do
    test "renders the Stride logo, wordmark, domain, copyright, and 4 legal links" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <KanbanWeb.MarketingClosing.marketing_footer />
        """)

      # Uses the canonical Stride logo SVG (shared with the app nav)
      assert html =~ "/images/logos/abstract-s-motion.svg"

      # Wordmark + domain + copyright
      assert html =~ "Stride"
      assert html =~ "StrideLikeABoss.com"
      assert html =~ "© 2026"

      # Legal links
      assert html =~ "Privacy"
      assert html =~ "Security"
      assert html =~ "GitHub"
      # GitHub link is external
      assert html =~ "https://github.com/cheezy/kanban"

      # Status link is removed for now (no status page wired up yet)
      refute html =~ ~s|>\nStatus\n<|
      refute html =~ ~s|> Status <|
    end
  end
end
