defmodule KanbanWeb.MarketingComponentsTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MarketingComponents

  describe "marketing_nav/1" do
    test "renders the gradient logo, Stride wordmark, and nav links" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      # Logo wordmark
      assert html =~ "Stride"

      # Uses the canonical Stride logo SVG (shared with the app nav)
      assert html =~ "/images/logos/abstract-s-motion.svg"

      # The public marketing nav links (Workflows + Pricing are admin-only
      # in the desktop nav and verified separately).
      assert html =~ "Product"
      assert html =~ "Resources"
      assert html =~ "About"

      # Product points at its dedicated page (not an in-page anchor)
      assert html =~ ~s|href="/product"|

      # Workflows and Pricing are admin-only — they appear in neither the
      # desktop nav nor the mobile menu for unauthenticated visitors.
      assert href_count(html, "/workflows") == 0
      refute html =~ "Pricing"
      refute html =~ ~s|href="/pricing"|
    end

    test "Workflows link is hidden from both desktop and mobile nav for non-admin users" do
      assigns = %{current_scope: %{user: %{email: "member@example.com", type: :member}}}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      assert href_count(html, "/workflows") == 0
    end

    test "Workflows link is visible in both desktop nav and mobile menu for admin users" do
      assigns = %{current_scope: %{user: %{email: "admin@example.com", type: :admin}}}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      # Desktop nav + mobile menu = 2 occurrences for admins.
      assert href_count(html, "/workflows") == 2
    end

    test "Pricing link is hidden for non-admin users" do
      assigns = %{current_scope: %{user: %{email: "member@example.com", type: :member}}}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      refute html =~ "Pricing"
      refute html =~ ~s|href="/pricing"|
    end

    test "Pricing link is visible to admin users" do
      assigns = %{current_scope: %{user: %{email: "admin@example.com", type: :admin}}}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      assert html =~ "Pricing"
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

    test "renders the mobile menu disclosure with an accessible toggle and panel" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      # The hamburger is now a <details>/<summary> disclosure rather than an inert button
      assert html =~ "<details "
      assert html =~ "js-mobile-menu"
      assert html =~ ~s|aria-controls="marketing-mobile-menu"|
      assert html =~ ~s|aria-label="Toggle menu"|
      assert html =~ ~s|aria-expanded="false"|
      assert html =~ ~s|id="marketing-mobile-menu"|

      # Summary is keyboard-focusable and meets the 44x44 tap target (w-11 h-11)
      assert html =~ "w-11 h-11"

      # The mobile panel mirrors the desktop nav links so they're reachable below md
      assert html =~ ~s|href="/users/log-in"|
    end

    test "mobile menu shows admin links when authenticated as admin" do
      assigns = %{current_scope: %{user: %{email: "admin@example.com", type: :admin}}}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_nav current_scope={@current_scope} />
        """)

      # Mobile panel is present and renders admin-only links
      assert html =~ ~s|id="marketing-mobile-menu"|
      assert html =~ ~s|href="/admin/dashboard"|
      assert html =~ ~s|href="/admin/errors"|
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

      # Headline split across two lines. The first line uses --ink-3 (changed
      # from --ink-4 in W900: --ink-4 at 68% L produced 2.78:1 contrast on the
      # near-white page, failing WCAG AA. --ink-3 reads at 4.5:1+ in both
      # themes and preserves the de-emphasized hierarchy vs. the un-styled
      # second line.)
      assert html =~ "Tasks are conversations."
      assert html =~ "speak both ways."
      assert html =~ "color: var(--ink-3)"

      # Sub-copy
      assert html =~ "Stride is an AI-native work management system"

      # Microcopy trust signal
      assert html =~ "Free for you and your teams · self-hosting options available"
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

    test "secondary CTA points at the create-a-board guide when the user has no boards" do
      assigns = %{current_scope: nil, has_boards: false}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_hero current_scope={@current_scope} has_boards={@has_boards} />
        """)

      assert html =~ "Learn about creating a board"
      assert html =~ ~s|href="/resources/creating-your-first-board"|
      # No longer points at the external agent-API README
      refute html =~ "Read the agent API"
    end

    test "secondary CTA points at the inviting-team-members guide when the user has boards" do
      assigns = %{current_scope: %{user: %{}}, has_boards: true}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_hero current_scope={@current_scope} has_boards={@has_boards} />
        """)

      assert html =~ "Learn about adding team members"
      assert html =~ ~s|href="/resources/inviting-team-members"|
      refute html =~ "Learn about creating a board"
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

    test "renders the titlebar with STR badge and Stride core (no agents-online chip)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <KanbanWeb.MarketingMiniBoard.marketing_mini_board />
        """)

      assert html =~ "STR"
      assert html =~ "Stride core"
      assert html =~ "var(--stride-orange)"
      refute html =~ "agents online"
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

    test "renders real card metrics on per-column footers (no hook strings, no diff stats)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <KanbanWeb.MarketingMiniBoard.marketing_mini_board />
        """)

      # Real TaskCard footers — Review shows criteria/issues/files, Done
      # shows cycle/files/actual, backlog/ready/doing show key_files/deps/
      # acceptance via hero-document, hero-link, hero-check icons.
      assert html =~ "5 criteria"
      assert html =~ "0 issues"
      assert html =~ "cycle 1h 24m"
      assert html =~ "actual: medium"
      assert html =~ "hero-clock"
      assert html =~ "hero-check-badge"

      # Red open-dependency chip + green 0-issues chip still rely on the
      # status tokens, so the color-token coverage from the previous test
      # is preserved.
      assert html =~ "var(--st-done)"
      assert html =~ "var(--st-blocked)"

      # Hook-execution state and raw diff stats must NEVER appear — the
      # real TaskCard does not surface them and the mini-board mocks must
      # not regress to fabricating them.
      refute html =~ "before_doing"
      refute html =~ "+142"
      refute html =~ "47/47"
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

      # Orange emphasis span on the second line. W900 switched the foreground
      # from --stride-orange (oklch 68% L = 2.96:1 against white, failing WCAG
      # AA at 30pt) to --stride-orange-ink (oklch 45% L = ~6:1, passing).
      assert html =~ "color: var(--stride-orange-ink);"

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
      # Two-tone headline split across two gettext strings + a span for the
      # orange-emphasised second clause. Uses --stride-orange-ink so the text
      # passes WCAG AA on the light page bg (W900).
      assert html =~ "One loop."
      assert html =~ "Two roles."
      assert html =~ "color: var(--stride-orange-ink);"
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
      assert html =~ "You write or review the task"
      assert html =~ "An agent claims it"
      assert html =~ "Hooks run on their machine"
      assert html =~ "You approve or send back"

      # Body excerpts
      assert html =~ "The schema is the conversation."
      assert html =~ "Atomic. SKIP LOCKED."
      assert html =~ "running tests, creating PRs"
      assert html =~ "Diff, tests, acceptance"
    end

    test "renders the responsive grid with separator borders across breakpoints" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MarketingComponents.marketing_how_it_works />
        """)

      # Responsive: 1 col mobile, 2 cols at md, 4 cols at lg
      assert html =~ "grid-cols-1"
      assert html =~ "md:grid-cols-2"
      assert html =~ "lg:grid-cols-4"

      # At lg, the first 3 cards each carry a right-side separator. The separator
      # may be expressed as either `md:border-r` (persists into lg via min-width
      # cascade) or `lg:border-r`. Expect exactly 3 such class occurrences total.
      right_border_count =
        Regex.scan(~r/(?:md|lg):border-r\b/, html) |> length()

      assert right_border_count == 3,
             "expected exactly 3 right-border separators across md/lg variants, got #{right_border_count}"
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

  describe "marketing_cta_section/1" do
    test "renders headline with orange emphasis on 'approving them.'" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <KanbanWeb.MarketingClosing.marketing_cta_section current_scope={@current_scope} />
        """)

      assert html =~ "Stop writing every line."
      assert html =~ "approving them."
      # Orange emphasis on the second-line phrase. W900 switched the foreground
      # from --stride-orange to --stride-orange-ink for WCAG AA at 33pt.
      assert html =~ "color: var(--stride-orange-ink);"

      # Sub-copy
      assert html =~ "Free for you and your teams"
      assert html =~ "Bring any agent"
    end

    test "unauthenticated state shows Start free linking to /users/register" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <KanbanWeb.MarketingClosing.marketing_cta_section current_scope={@current_scope} />
        """)

      assert html =~ "Start free"
      assert html =~ ~s|href="/users/register"|
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

  # Count the occurrences of `href="<path>"` in the rendered HTML. Useful for
  # checks like "the desktop nav has Workflows but the mobile menu does too"
  # — by comparing counts, the desktop-only gating can be asserted without a
  # brittle CSS-class scrape.
  defp href_count(html, path) do
    needle = ~s|href="#{path}"|
    html |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
