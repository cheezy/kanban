defmodule KanbanWeb.PageControllerTest do
  use KanbanWeb.ConnCase

  test "GET / puts the marketing sections in one <main> landmark", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("main") |> Enum.count() == 1
    assert document |> LazyHTML.query("main h1") |> Enum.count() == 1
  end

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    # New marketing hero headline (set in MarketingComponents.marketing_hero/1).
    # The second line is asserted loosely so the specific subject ("Stride" /
    # "Your kanban" / etc.) can change without breaking the test — the load-
    # bearing brand line is the first one.
    assert body =~ "Tasks are conversations."
    assert body =~ "speak both ways."
    # MiniBoard renders the canonical fixture idents from the new design.
    assert body =~ "W198"
    assert body =~ "W193"
  end

  test "GET /about", %{conn: conn} do
    conn = get(conn, ~p"/about")
    assert html_response(conn, 200)
  end

  test "GET /acceptable-use", %{conn: conn} do
    conn = get(conn, ~p"/acceptable-use")
    body = html_response(conn, 200)
    assert body =~ "Acceptable Use Policy"
    assert body =~ "Prohibited uses"
    assert body =~ "Agent-action attribution"
    assert body =~ "Enforcement"
    assert body =~ "privacy@letstango.ca"
  end

  test "GET /terms", %{conn: conn} do
    conn = get(conn, ~p"/terms")
    body = html_response(conn, 200)
    assert body =~ "Terms of Service"
    assert body =~ "Your content"
    assert body =~ "AI agents and the attribution clause"
    assert body =~ "Limitation of liability"
    assert body =~ "privacy@letstango.ca"
  end

  describe "GET /terms plans and termination" do
    test "Fees and plans describes the free plan limits and the Organization agreement",
         %{conn: conn} do
      body = conn |> get(~p"/terms") |> html_response(200)

      assert body =~ "a board can have up to 3 people, not counting AI agents"
      assert body =~ "some features are available only to Organizations"

      assert body =~
               "The Organization plan is sold under a separate written agreement between us and your organization."

      assert body =~
               "Fees are invoiced outside the service, and Stride has no self-serve billing."

      assert body =~
               "Free-plan features and limits may change over time, for example when a feature becomes available only to Organizations. We will give advance notice before such a change takes effect."
    end

    test "Fees and plans no longer promises advance billing or an automatic downgrade",
         %{conn: conn} do
      body = conn |> get(~p"/terms") |> html_response(200)

      refute body =~ "billed in advance"
      refute body =~ "grace period"
      refute body =~ "downgrade your account"
    end

    test "keeps the no-reduction promise for paid periods", %{conn: conn} do
      body = conn |> get(~p"/terms") |> html_response(200)

      assert body =~
               "We will not materially reduce the core functionality of a paid plan during a period you have already paid for."
    end

    test "Termination says every user can delete their own account", %{conn: conn} do
      body = conn |> get(~p"/terms") |> html_response(200)

      assert body =~
               "Every user, on the free plan or in an Organization, can delete their own account in their account settings."

      assert body =~
               "We may suspend or terminate your access if you materially breach these terms"
    end

    test "keeps every existing section heading", %{conn: conn} do
      document = conn |> get(~p"/terms") |> html_response(200) |> LazyHTML.from_document()

      headings =
        document
        |> LazyHTML.query("main h2")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert headings == [
               "The service",
               "Your account",
               "Your content",
               "AI agents and the attribution clause",
               "Acceptable use",
               "Fees and plans",
               "Termination",
               "Disclaimers",
               "Limitation of liability",
               "Changes to these terms",
               "Contact us"
             ]
    end
  end

  # The Fees and plans and Termination copy is long, so each locale must render
  # translated (not fall back to English) inside the same wrapping paragraph
  # markup as English: a leading-relaxed <p> with no truncate or nowrap class.
  # The locale is seeded into the session so KanbanWeb.Plugs.Locale runs.
  @terms_translations %{
    "de" => [
      "Ein Board kann bis zu 3 Personen haben",
      "kann sein eigenes Konto in seinen Kontoeinstellungen löschen"
    ],
    "es" => [
      "un tablero puede tener hasta 3 personas",
      "pueden eliminar su propia cuenta en la configuración de su cuenta"
    ],
    "fr" => [
      "certaines fonctionnalités sont réservées aux organisations",
      "peut supprimer son propre compte dans les paramètres de son compte"
    ],
    "ja" => ["一部の機能は組織でのみ利用できます", "アカウント設定から自分のアカウントを削除できます"],
    "pt" => [
      "um quadro pode ter até 3 pessoas",
      "podem excluir a própria conta nas configurações da conta"
    ],
    "zh" => ["部分功能仅对组织开放", "都可以在账户设置中删除自己的账户"]
  }

  for {locale, expected} <- @terms_translations do
    test "GET /terms renders the plans and termination copy translated under #{locale}",
         %{conn: conn} do
      document =
        conn
        |> Plug.Test.init_test_session(%{"locale" => unquote(locale)})
        |> get(~p"/terms")
        |> html_response(200)
        |> LazyHTML.from_document()

      paragraphs =
        document
        |> LazyHTML.query("main section p")
        |> Enum.map(&{LazyHTML.text(&1), &1 |> LazyHTML.attribute("class") |> List.first("")})

      for phrase <- unquote(expected) do
        assert [{_text, class}] = Enum.filter(paragraphs, fn {text, _} -> text =~ phrase end),
               "expected one #{unquote(locale)} paragraph containing #{inspect(phrase)} on /terms"

        assert class =~ "leading-relaxed"
        refute class =~ "truncate"
        refute class =~ "nowrap"
      end

      text = document |> LazyHTML.query("main") |> LazyHTML.text()
      refute text =~ "a board can have up to 3 people"
      refute text =~ "can delete their own account in their account settings"
    end
  end

  # The "Last updated" date is translated text, not an English constant, so a
  # German reader sees a German month on every legal page.
  for {path, localized, english} <- [
        {"/terms", "21. Oktober 2026", "October 21, 2026"},
        {"/acceptable-use", "11. Juni 2026", "June 11, 2026"},
        {"/privacy", "14. Mai 2026", "May 14, 2026"},
        {"/security", "14. Mai 2026", "May 14, 2026"}
      ] do
    test "GET #{path} shows the Last updated date with a German month under de", %{conn: conn} do
      body =
        conn
        |> Plug.Test.init_test_session(%{"locale" => "de"})
        |> get(unquote(path))
        |> html_response(200)

      assert body =~ "Zuletzt aktualisiert: #{unquote(localized)}"
      refute body =~ unquote(english)
    end
  end

  test "GET /privacy", %{conn: conn} do
    conn = get(conn, ~p"/privacy")
    body = html_response(conn, 200)
    assert body =~ "Privacy Policy"
    assert body =~ "Information we collect"
    assert body =~ "Your rights"
    assert body =~ "Contact us"
  end

  test "GET /privacy discloses that org-admins can view and export audit events", %{
    conn: conn
  } do
    body = conn |> get(~p"/privacy") |> html_response(200)

    assert body =~
             ~r/id="privacy-organization-administrators"[^>]*>\s*<strong>Organization administrators<\/strong>/

    assert body =~ "can view and export that Organization&#39;s security audit events"
  end

  test "GET /security", %{conn: conn} do
    conn = get(conn, ~p"/security")
    body = html_response(conn, 200)
    assert body =~ "Authentication and access"
    assert body =~ "Transport and storage"
    assert body =~ "Vulnerability disclosure"
    assert body =~ "security@letstango.ca"
  end

  describe "GET /pricing" do
    test "shows exactly two plans, Free and Organization", %{conn: conn} do
      document = conn |> get(~p"/pricing") |> html_response(200) |> LazyHTML.from_document()

      plan_names =
        document
        |> LazyHTML.query("[id^='plan-'] h2")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert plan_names == ["Free", "Organization"]
      assert document |> LazyHTML.query("#plan-free") |> Enum.count() == 1
      assert document |> LazyHTML.query("#plan-organization") |> Enum.count() == 1
    end

    test "the Free plan states its limits and what it includes", %{conn: conn} do
      document = conn |> get(~p"/pricing") |> html_response(200) |> LazyHTML.from_document()
      free = document |> LazyHTML.query("#plan-free") |> LazyHTML.text()

      assert free =~ "Unlimited boards, tasks and goals"
      assert free =~ "Up to 3 people per board — AI agents do not count"
      assert free =~ "The full REST API and client-side hooks"
      assert free =~ "Metrics and exports"
    end

    test "the Organization plan lists the eight paid features and a contact call to action",
         %{conn: conn} do
      document = conn |> get(~p"/pricing") |> html_response(200) |> LazyHTML.from_document()
      organization = LazyHTML.query(document, "#plan-organization")
      text = LazyHTML.text(organization)

      for feature <- [
            "Notifications",
            "Organization audit log",
            "Single sign-on (SSO)",
            "Workspaces",
            "Bulk actions",
            "Integrations (webhooks)",
            "Task telemetry fields",
            "MCP access"
          ] do
        assert text =~ feature
      end

      assert text =~ "no user or board limits"

      assert organization
             |> LazyHTML.query("a[href='mailto:enterprise@stridelikeaboss.com']")
             |> LazyHTML.text() =~ "Talk to us"
    end

    test "has no price, trial, checkout or seat-limit wording", %{conn: conn} do
      body = conn |> get(~p"/pricing") |> html_response(200)

      refute body =~ "Start free trial"
      refute body =~ "$12"
      refute body =~ "/ user / month"
      refute body =~ "Up to 25 users"
      refute body =~ "Team plan"
      refute body =~ "Most popular"
      refute body =~ "Enterprise"
      refute body =~ "Solo"
    end

    test "the FAQ explains who counts toward the free member limit", %{conn: conn} do
      body = conn |> get(~p"/pricing") |> html_response(200)

      assert body =~ "Frequently asked questions"
      assert body =~ "Who counts toward the 3-person limit on a free board?"
      assert body =~ "Only the human members of the board, including its owner."
    end

    test "has the #contact target the lock prompts and member cap link to", %{conn: conn} do
      document = conn |> get(~p"/pricing") |> html_response(200) |> LazyHTML.from_document()
      contact = LazyHTML.query(document, "#contact")

      assert Enum.count(contact) == 1
      assert LazyHTML.text(contact) =~ "Get Stride for your organization"

      assert contact
             |> LazyHTML.query("a[href='mailto:enterprise@stridelikeaboss.com']")
             |> LazyHTML.text() =~ "Talk to us"
    end

    test "renders the same two plans for a signed-in user", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      body = conn |> get(~p"/pricing") |> html_response(200)

      assert body =~ ~s(id="plan-free")
      assert body =~ ~s(id="plan-organization")
      assert body =~ ~s(id="contact")
      refute body =~ "Start free trial"
    end
  end

  test "GET /product", %{conn: conn} do
    conn = get(conn, ~p"/product")
    body = html_response(conn, 200)
    # Hero + at least the first three feature sections render
    assert body =~ "Five-column flow"
    assert body =~ "Structured schema"
    assert body =~ "Plan at the level you think at"
    # All six section screenshots have been wired in (no placeholders remain).
    assert body =~ "/images/boards.png"
    assert body =~ "/images/kanban_board.png"
    assert body =~ "/images/task_detail.png"
    assert body =~ "/images/goal_view.png"
    assert body =~ "/images/review_queue.png"
    assert body =~ "/images/agent_activity.png"
    assert body =~ "/images/workspace_metrics.png"
    refute body =~ "image-placeholder"
  end

  test "GET /workflows", %{conn: conn} do
    conn = get(conn, ~p"/workflows")
    body = html_response(conn, 200)
    # Lifecycle column names
    assert body =~ "Backlog"
    assert body =~ "Ready"
    assert body =~ "Doing"
    assert body =~ "Review"
    assert body =~ "Done"
    # All four hook names render as code
    assert body =~ "before_doing"
    assert body =~ "after_doing"
    assert body =~ "before_review"
    assert body =~ "after_review"
  end

  # D210 was filed reporting empty msgstr entries for this page in all six
  # non-English locales. The premise did not hold — the reported counts came
  # from `grep -B 4 'msgstr ""'`, which false-positives on the multi-line
  # `msgstr ""` opening Gettext writes for every long string, so a fully
  # translated paragraph looks empty to that grep. Consult this test rather
  # than that grep for whether the page renders translated at all — but note
  # it samples two phrases per locale, not all 54 entries, so it guards
  # against the page falling back to English rather than proving every string
  # is translated. For that use `msgattrib --untranslated`, which is what
  # actually settled this defect.
  #
  # /workflows is a plain controller page whose locale comes from the session
  # via KanbanWeb.Plugs.Locale, so the locale is seeded into the session
  # rather than set with Gettext.put_locale/2 — that exercises the real
  # production path instead of bypassing the plug.
  @workflows_translations %{
    "de" => ["Anforderungen", "Menschliche Prüfung und Abschluss"],
    "es" => ["Requisitos", "Revisión humana y finalización"],
    "fr" => ["Exigences", "Revue humaine et complétion"],
    "ja" => ["要件", "人によるレビューと完了"],
    "pt" => ["Requisitos", "Revisão humana e conclusão"],
    "zh" => ["需求", "人工审查与完成"]
  }

  for {locale, expected} <- @workflows_translations do
    test "GET /workflows renders translated copy under #{locale}", %{conn: conn} do
      body =
        conn
        |> Plug.Test.init_test_session(%{"locale" => unquote(locale)})
        |> get(~p"/workflows")
        |> html_response(200)

      for phrase <- unquote(expected) do
        assert body =~ phrase,
               "expected #{unquote(locale)} translation #{inspect(phrase)} on /workflows"
      end

      # The English source of the second phrase must be gone, which is what
      # separates "translated" from "the catalog merely has an entry".
      refute body =~ "Human review and completion"
    end
  end

  test "GET /tango", %{conn: conn} do
    conn = get(conn, ~p"/tango")
    assert html_response(conn, 200)
  end

  test "GET /tango: gettext'd marketing copy is never raw'd onto the page", %{conn: conn} do
    # Asserts the template no longer ships `raw/1` on translator-controlled
    # strings. If a future change re-introduces raw/1 here, this test fails
    # before a malicious translator can land an inline <script>.
    template = File.read!("lib/kanban_web/controllers/page_html/tango.html.heex")
    refute template =~ "|> raw()"
    refute template =~ "raw("

    # Sanity: the page still renders and contains key copy fragments.
    conn = get(conn, ~p"/tango")
    body = html_response(conn, 200)
    assert body =~ "About Tango"
    assert body =~ "Our Mission"
    assert body =~ "Work With Us"
  end

  test "GET /changelog", %{conn: conn} do
    conn = get(conn, ~p"/changelog")
    assert html_response(conn, 200)
  end

  describe "GET /changelog Organizations announcement" do
    test "is the newest entry, above every release section", %{conn: conn} do
      body = conn |> get(~p"/changelog") |> html_response(200)

      {announcement_at, _} = :binary.match(body, "data-changelog-announcement")
      {first_release_at, _} = :binary.match(body, ~s(<section class="mb-10">\n))

      assert announcement_at < first_release_at
    end

    test "lists what becomes Organization-only, what stays free and the 3-person limit",
         %{conn: conn} do
      text =
        conn
        |> get(~p"/changelog")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("[data-changelog-announcement]")
        |> LazyHTML.text()

      assert text =~ "Announcing Organizations and the Free plan"
      assert text =~ "Launch date: to be announced on this page."

      for paid <- [
            "Notifications",
            "Bulk actions",
            "Integrations (webhooks)",
            "Task telemetry fields",
            "MCP access"
          ] do
        assert text =~ paid
      end

      assert text =~ "paused, not deleted"
      assert text =~ "Unlimited boards, tasks and goals"
      assert text =~ "The full REST API and client-side hooks"
      assert text =~ "Metrics and exports"
      assert text =~ "Up to 3 people per board — AI agents do not count"
      assert text =~ "Existing boards keep every member they already have."
      assert text =~ "Tasks waiting for you are always listed in the Review queue and My Work."
    end

    test "links to the Review queue, My Work and the pricing contact form with in-app paths",
         %{conn: conn} do
      announcement =
        conn
        |> get(~p"/changelog")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("[data-changelog-announcement]")

      assert announcement |> LazyHTML.query("a[href='/pricing#contact']") |> Enum.count() == 1
      assert announcement |> LazyHTML.query("a[href='/review']") |> Enum.count() == 1
      assert announcement |> LazyHTML.query("a[href='/my-work']") |> Enum.count() == 1
    end

    test "renders under the app shell for a signed-in user", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      body = conn |> get(~p"/changelog") |> html_response(200)

      assert body =~ "data-changelog-announcement"
      assert body =~ "Announcing Organizations and the Free plan"
    end
  end

  test "CHANGELOG.md and the /changelog page each have at most one [Unreleased] section",
       %{conn: conn} do
    # New entries go under the existing [Unreleased] heading rather than a
    # second one, in CHANGELOG.md and in priv/changelog/body.html alike. A
    # release folds the section into its version, so there may be none.
    markdown = File.read!("CHANGELOG.md")
    body = conn |> get(~p"/changelog") |> html_response(200)

    assert length(Regex.scan(~r/^## \[Unreleased\]$/m, markdown)) <= 1
    assert length(Regex.scan(~r/\[Unreleased\]/, body)) <= 1
  end

  test "the changelog body carries the data-changelog anchor for responsive containment",
       %{conn: conn} do
    body = conn |> get(~p"/changelog") |> html_response(200)

    # W1386: the markdown-rendered changelog body (long inline <code> tokens,
    # wide tables) is kept from overflowing a 375px viewport by CSS scoped to
    # [data-changelog] in app.css (inline code breaks, tables scroll). Guard the
    # anchor so that containment can't be silently removed.
    assert body =~ "data-changelog"
  end

  test "the theme bootstrap resolves system preference and never strips data-theme", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    # Always resolves to a concrete data-theme so daisyUI AND the Stride
    # :where([data-theme=dark]) override (no prefers-color-scheme fallback)
    # engage together for system-dark users...
    assert body =~ ~s|matchMedia("(prefers-color-scheme: dark)")|
    assert body =~ ~s|setAttribute("data-theme"|
    # ...and tracks the user's choice separately for the 3-way toggle pill...
    assert body =~ "data-theme-choice"
    # ...and never removes data-theme (the old behavior that left a system-dark
    # user with a half-dark page).
    refute body =~ "removeAttribute"
  end

  test "all three layout theme bootstraps use the resolve-to-explicit mechanism and stay identical" do
    bootstraps =
      for layout <- ~w(root marketing app_chrome) do
        src = File.read!("lib/kanban_web/components/layouts/#{layout}.html.heex")

        assert src =~ ~s|matchMedia("(prefers-color-scheme: dark)")|,
               "#{layout} missing system resolution"

        assert src =~ "data-theme-choice", "#{layout} missing the choice attribute"
        refute src =~ "removeAttribute", "#{layout} still strips data-theme (the half-dark bug)"
        # Extract the bootstrap IIFE so the three can be compared exactly.
        [_, body] = String.split(src, "(() => {", parts: 2)
        [iife, _] = String.split(body, "})();", parts: 2)
        iife
      end

    # Stated pitfall: the three bootstraps must stay byte-identical (no drift).
    assert match?([_], Enum.uniq(bootstraps)),
           "the three layout theme bootstraps have drifted — keep them byte-identical"
  end

  describe "POST /locale/:locale" do
    test "sets locale and redirects to referer", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "http://localhost/boards")
        |> post(~p"/locale/en")

      assert redirected_to(conn) == "/boards"
    end

    test "redirects to root when no referer", %{conn: conn} do
      conn = post(conn, ~p"/locale/en")
      assert redirected_to(conn) == "/"
    end

    test "sets locale in session", %{conn: conn} do
      conn = post(conn, ~p"/locale/en")
      assert get_session(conn, :locale) == "en"
    end
  end
end
