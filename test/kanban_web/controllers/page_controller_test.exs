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
        {"/privacy", "21. Oktober 2026", "October 21, 2026"},
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

  # The Organization disclosures must render translated under every locale,
  # not fall back to English. The locale is seeded into the session so
  # KanbanWeb.Plugs.Locale runs.
  @privacy_organization_translations %{
    "de" => [
      "speichern wir den Namen und die Adresse der Organisation",
      "die Mitglieder der Organisation einschließlich ihrer Namen, E-Mail-Adressen und Rollen",
      "wenn Ihre Organisation Single Sign-On (SSO) aktiviert",
      "zum Beispiel Unterlagen zu Vereinbarungen mit Organisationen"
    ],
    "es" => [
      "almacenamos el nombre y la dirección de la organización",
      "pueden ver los miembros de la organización",
      "si tu organización activa el inicio de sesión único (SSO)",
      "registros relacionados con los acuerdos de las organizaciones"
    ],
    "fr" => [
      "nous enregistrons le nom et l'adresse de l'organisation",
      "ses administrateurs peuvent voir les membres de l'organisation",
      "si votre organisation active l'authentification unique (SSO)",
      "les documents liés aux accords conclus avec des organisations"
    ],
    "ja" => [
      "担当者の氏名・電話番号・メールアドレスを保存します",
      "組織のメンバー（氏名、メールアドレス、ロールを含む）",
      "組織がシングルサインオン（SSO）を有効にしている場合",
      "（例：組織との契約に関する記録）"
    ],
    "pt" => [
      "armazenamos o nome e o endereço da organização",
      "podem ver os membros da organização",
      "se a sua organização ativar o login único (SSO)",
      "registros relacionados a acordos com organizações"
    ],
    "zh" => [
      "我们会存储该组织的名称和地址",
      "该组织的成员（包括其姓名、电子邮件地址和角色）",
      "如果你的组织启用了单点登录（SSO）",
      "（例如与组织协议相关的记录）"
    ]
  }

  # Each new list item keeps the "<strong>label</strong> — body" structure under
  # every locale, with both the label and the body translated.
  @privacy_organization_labels %{
    "de" => {"Organisationsinformationen", "Single Sign-On"},
    "es" => {"Información de la organización", "Inicio de sesión único"},
    "fr" => {"Informations sur l'organisation", "Authentification unique"},
    "ja" => {"組織の情報", "シングルサインオン"},
    "pt" => {"Informações da organização", "Login único"},
    "zh" => {"组织信息", "单点登录"}
  }

  for {locale, expected} <- @privacy_organization_translations do
    test "GET /privacy renders the Organization disclosures translated under #{locale}",
         %{conn: conn} do
      document =
        conn
        |> Plug.Test.init_test_session(%{"locale" => unquote(locale)})
        |> get(~p"/privacy")
        |> html_response(200)
        |> LazyHTML.from_document()

      text = document |> LazyHTML.query("main") |> LazyHTML.text()

      for phrase <- unquote(expected) do
        assert text =~ phrase,
               "expected #{inspect(phrase)} on /privacy under #{unquote(locale)}"
      end

      refute text =~ "if your company has an Organization on Stride"
      refute text =~ "if your Organization enables single sign-on"

      {org_label, sso_label} = Map.fetch!(@privacy_organization_labels, unquote(locale))

      for {id, label, english} <- [
            {"privacy-organization-information", org_label, "Organization information"},
            {"privacy-single-sign-on", sso_label, "Single sign-on"}
          ] do
        item = LazyHTML.query(document, "main section li##{id}")

        assert item |> LazyHTML.query("strong") |> LazyHTML.text() |> String.trim() == label
        refute item |> LazyHTML.text() =~ english

        assert item |> LazyHTML.text() |> String.replace(~r/\s+/u, " ") |> String.trim() =~
                 ~r/^#{Regex.escape(label)} — \S/u
      end
    end
  end

  describe "GET /privacy Organizations" do
    test "lists the Organization data collected and who can see it", %{conn: conn} do
      body = conn |> get(~p"/privacy") |> html_response(200)

      assert body =~
               ~r/id="privacy-organization-information"[^>]*>\s*<strong>Organization information<\/strong>/

      assert body =~
               "we store the Organization&#39;s name and address and a contact person&#39;s name, phone number and email address."

      assert body =~
               "We use them to set up and administer the Organization and its agreement with us."

      assert body =~ "The Organization&#39;s org-admins and the Stride team can see them."
    end

    test "discloses what org-admins can see, including actor emails and IP addresses in the audit log",
         %{conn: conn} do
      body = conn |> get(~p"/privacy") |> html_response(200)

      assert body =~
               "its org-admins can see the Organization&#39;s members, including their names, email addresses and roles, and its workspaces and boards."

      assert body =~
               "including your email address and IP address when you are the person who acted in that Organization."
    end

    test "mentions SSO processing for Organizations that enable it", %{conn: conn} do
      body = conn |> get(~p"/privacy") |> html_response(200)

      assert body =~ ~r/id="privacy-single-sign-on"[^>]*>\s*<strong>Single sign-on<\/strong>/

      assert body =~
               "if your Organization enables single sign-on (SSO), we process the identity details"
    end

    test "retention refers to Organization agreements, not billing, and keeps self-service deletion",
         %{conn: conn} do
      body = conn |> get(~p"/privacy") |> html_response(200)

      assert body =~ "(for example, records related to Organization agreements)"
      refute body =~ "billing"
      assert body =~ "You can delete your account yourself in your account settings."
      assert body =~ "Delete your account and your personal data."
    end

    test "keeps every existing section heading", %{conn: conn} do
      document = conn |> get(~p"/privacy") |> html_response(200) |> LazyHTML.from_document()

      headings =
        document
        |> LazyHTML.query("main h2")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert headings == [
               "Information we collect",
               "How we use your information",
               "Data sharing",
               "Data retention",
               "Your rights",
               "Cookies and local storage",
               "Security",
               "Changes to this policy",
               "Contact us"
             ]
    end
  end

  test "GET /security", %{conn: conn} do
    conn = get(conn, ~p"/security")
    body = html_response(conn, 200)
    assert body =~ "Authentication and access"
    assert body =~ "Transport and storage"
    assert body =~ "Vulnerability disclosure"
    assert body =~ "security@letstango.ca"
  end

  test "the legal page headings shrink and hyphenate on phones, so a long German word fits",
       %{conn: conn} do
    for path <- [~p"/terms", ~p"/privacy", ~p"/acceptable-use", ~p"/security"] do
      [class] =
        conn
        |> init_test_session(%{locale: "de"})
        |> get(path)
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("main h1")
        |> LazyHTML.attribute("class")

      for token <- ~w(text-3xl sm:text-4xl break-words hyphens-auto) do
        assert token in String.split(class), "#{path} h1 lacks #{token}"
      end
    end
  end

  test "/privacy states the 90-day audit retention and that an Organization's own setting governs its events",
       %{conn: conn} do
    text =
      conn
      |> get(~p"/privacy")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#privacy-retention")
      |> LazyHTML.text()

    assert text =~ "retained for up to 90 days"
    assert text =~ "kept for as long as that Organization's retention setting says"

    de =
      conn
      |> init_test_session(%{locale: "de"})
      |> get(~p"/privacy")
      |> html_response(200)

    assert de =~ "Aufbewahrungseinstellung dieser Organisation"
  end

  test "/privacy discloses that audit events about a deleted account are kept", %{conn: conn} do
    text =
      conn
      |> get(~p"/privacy")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#privacy-deletion")
      |> LazyHTML.text()

    assert text =~ "we delete your account record"
    assert text =~ "including your email address and IP address, are not removed"
    assert text =~ "can still see the events that belong to it"

    for {locale, fragment} <- [
          {"de", "werden beim Löschen Ihres Kontos nicht entfernt"},
          {"ja", "アカウントを削除しても消去されません。"}
        ] do
      body =
        conn
        |> init_test_session(%{locale: locale})
        |> get(~p"/privacy")
        |> html_response(200)

      assert body =~ fragment
    end
  end

  test "/privacy and /terms say an identity provider can disable an account and how to have it deleted",
       %{conn: conn} do
    privacy = conn |> get(~p"/privacy") |> html_response(200) |> LazyHTML.from_document()
    terms = conn |> get(~p"/terms") |> html_response(200) |> LazyHTML.from_document()

    assert privacy |> LazyHTML.query("#privacy-single-sign-on") |> LazyHTML.text() =~
             "that provider can create, update and disable your account"

    for {document, id} <- [{privacy, "#privacy-deletion"}, {terms, "#terms-account-deletion"}] do
      assert document |> LazyHTML.query(id) |> LazyHTML.text() =~
               "has disabled your account, you cannot sign in to delete it yourself; email us at the address below"
    end

    de =
      conn
      |> init_test_session(%{locale: "de"})
      |> get(~p"/terms")
      |> html_response(200)

    assert de =~ "schreiben Sie uns an die unten genannte Adresse"
  end

  describe "GET /pricing" do
    test "the hero says hosted Stride is free for individuals and small teams", %{conn: conn} do
      body = conn |> get(~p"/pricing") |> html_response(200)

      assert body =~ "free to use hosted for individuals and small teams"
      refute body =~ "managed for you"
    end

    test "the switching FAQ says who can export and that free users email us to move",
         %{conn: conn} do
      faq =
        conn
        |> get(~p"/pricing")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#faq-switch-hosting")

      text = LazyHTML.text(faq)

      assert text =~ "An Organization's org-admins export a workspace"
      assert text =~ "we import it on the other side"

      assert text =~
               "On the free plan, email hello@stridelikeaboss.com and we will help you move."

      refute text =~ "Export your workspace from one and import it into the other"

      assert faq |> LazyHTML.query("a[href='mailto:hello@stridelikeaboss.com']") |> Enum.count() ==
               1
    end

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

  # One screenshot per showcase slot, captured from demo data
  # (priv/static/images/marketing/README.md). marketing_images_test.exs checks
  # each file exists and declares its real size.
  @product_images ~w(
    product-hero.png
    product-boards.png
    product-board.png
    product-goal.png
    product-task-detail.png
    product-task-schema.png
    product-review-queue.png
    product-review-diff.png
    product-agent-activity.png
    product-my-work.png
    product-target.png
    product-notifications.png
    product-integrations.png
    product-board-metrics.png
    product-metrics.png
    product-compliance.png
    product-workspaces.png
    product-free-boards.png
    product-org-console.png
    product-audit-log.png
    product-security-policy.png
    product-sso.png
    product-scim.png
  )

  test "GET /product", %{conn: conn} do
    # Served by PageController :product to a visitor who is not signed in.
    body = conn |> get(~p"/product") |> html_response(200)

    # The hero, then the Plan, Build and Review themes in that order.
    assert body =~ "The board your people and your agents share."

    positions =
      for id <- ~w(plan build review) do
        assert body =~ ~s(id="#{id}"), "expected the #{id} theme"
        body |> :binary.match(~s(id="#{id}")) |> elem(0)
      end

    assert positions == Enum.sort(positions)
    assert body =~ "Plan at the level you think at"
    assert body =~ "Structured schema, not free-text"
    assert body =~ "Approve with the evidence in front of you"

    for image <- @product_images do
      assert body =~ "/images/marketing/#{image}", "expected #{image} on /product"
    end

    # No placeholder or old mockup is left on the page.
    refute body =~ "image-placeholder"

    refute body =~
             ~r{/images/(boards|kanban_board|task_detail|goal_view|review_queue|agent_activity|workspace_metrics)\.png}

    # Claims the code does not back are gone (W2457).
    refute body =~ "J/K navigates"
    refute body =~ "The columns are fixed"
    refute body =~ "split by agent vs human"
    refute body =~ "which test covers each acceptance criterion"
    refute body =~ "not-started, unclaimed tasks"

    # Secondary text uses ink tokens, never an opacity class (D214).
    main = body |> LazyHTML.from_document() |> LazyHTML.query("main") |> LazyHTML.to_html()
    refute main =~ ~r/text-base-content[^"]*opacity-\d/
  end

  # The Operate theme (W2458): each subsection's heading, its screenshot (or,
  # for MCP, the code snippet) and the Resources guide it links to, in page
  # order.
  @operate_sections [
    {"See what every agent is doing", "product-agent-activity.png", "watching-your-agents"},
    {"Everything assigned to you, on one page", "product-my-work.png", "your-work-across-boards"},
    {"Plan toward a date across boards", "product-target.png", "planning-with-targets"},
    {"Told when work needs you", "product-notifications.png",
     "staying-informed-with-notifications"},
    {"Send board events to Slack, Discord or your own service", "product-integrations.png",
     "connecting-webhooks-slack-and-discord"},
    {"Let agents work through MCP", nil, "connecting-an-mcp-client"}
  ]

  test "GET /product shows the operate sections and links to their guides", %{conn: conn} do
    body = conn |> get(~p"/product") |> html_response(200)

    # Operate follows Review.
    [review_at, operate_at] =
      for id <- ~w(review operate), do: body |> :binary.match(~s(id="#{id}")) |> elem(0)

    assert review_at < operate_at
    assert body =~ "Keep work moving once it starts"

    operate = body |> LazyHTML.from_document() |> LazyHTML.query("main section#operate")

    headings = operate |> LazyHTML.query("h3") |> Enum.map(&LazyHTML.text/1)
    assert Enum.map(headings, &String.trim/1) == Enum.map(@operate_sections, &elem(&1, 0))

    srcs = operate |> LazyHTML.query("img") |> LazyHTML.attribute("src")
    expected_images = for {_, image, _} <- @operate_sections, image, do: image
    assert length(srcs) == length(expected_images)

    for {src, image} <- Enum.zip(srcs, expected_images) do
      assert src =~ "/images/marketing/#{image}", "expected #{image}, got #{src}"
    end

    # The MCP subsection shows a code block instead of a screenshot. It
    # scrolls sideways at 375px instead of widening the page, can be
    # scrolled with the keyboard, and carries only placeholders.
    [pre] = operate |> LazyHTML.query("pre") |> Enum.to_list()

    assert pre
           |> LazyHTML.attribute("class")
           |> hd()
           |> String.split()
           |> Enum.member?("overflow-x-auto")

    assert LazyHTML.attribute(pre, "tabindex") == ["0"]

    snippet = pre |> LazyHTML.query("code") |> LazyHTML.text()
    assert snippet == KanbanWeb.PageHTML.mcp_snippet()
    assert snippet =~ "claude mcp add --transport http stride"
    assert snippet =~ "/api/mcp"
    assert snippet =~ "Bearer ${STRIDE_API_TOKEN}"
    refute snippet =~ "stridelikeaboss"
    refute snippet =~ ~r/stride_(dev|test|prod|live)_/

    # One link per subsection, each to a Resources guide that exists.
    for {_heading, _image, guide_id} <- @operate_sections do
      href = "/resources/#{guide_id}"
      links = LazyHTML.query(operate, ~s(a[href="#{href}"]))
      assert Enum.count(links) == 1, "expected one link to #{href}"
      assert {:ok, _guide} = KanbanWeb.ResourcesLive.HowToData.get_how_to(guide_id)
      assert build_conn() |> get(href) |> html_response(200)
    end
  end

  test "PageHTML.mcp_snippet/0 adds the MCP server with a placeholder host and token" do
    lines = String.split(KanbanWeb.PageHTML.mcp_snippet(), "\n")

    assert lines == [
             ~s(export STRIDE_URL="https://your-stride-host"),
             ~s(export STRIDE_API_TOKEN="paste-your-token-here"),
             ~S(claude mcp add --transport http stride "${STRIDE_URL}/api/mcp" ) <> "\\",
             ~S(  --header "Authorization: Bearer ${STRIDE_API_TOKEN}")
           ]
  end

  # The Measure and Govern themes (W2459): per section, each subsection's
  # heading, its screenshot and the Resources guide it links to, in page order.
  # Two Measure subsections share a guide, so links are counted per subsection.
  @measure_govern_sections [
    {"measure",
     [
       {"Flow metrics for every board", "product-board-metrics.png", "metrics-dashboard"},
       {"Trends across all your boards", "product-metrics.png",
        "workspace-and-compliance-metrics"},
       {"See how agents follow your workflow", "product-compliance.png",
        "workspace-and-compliance-metrics"}
     ]},
    {"govern",
     [
       {"A workspace for each team", "product-workspaces.png", "working-in-a-workspace"},
       {"Free boards and paid boards", "product-free-boards.png", "free-and-paid-boards"},
       {"One console for org-admins", "product-org-console.png",
        "administering-your-organization"},
       {"An audit log of security events", "product-audit-log.png",
        "reading-the-organization-audit-log"},
       {"Require two-factor for every member", "product-security-policy.png",
        "organization-security-policy"},
       {"Single sign-on with your identity provider", "product-sso.png",
        "setting-up-single-sign-on"},
       {"Provision people with SCIM", "product-scim.png", "provisioning-users-with-scim"}
     ]}
  ]

  test "GET /product shows the measure and govern sections and links to their guides", %{
    conn: conn
  } do
    body = conn |> get(~p"/product") |> html_response(200)

    # Operate, then Measure, then Govern, then the closing call to action.
    positions =
      for marker <- [~s(id="operate"), ~s(id="measure"), ~s(id="govern"), "Ready to see it run?"] do
        body |> :binary.match(marker) |> elem(0)
      end

    assert positions == Enum.sort(positions)
    assert body =~ "Know where work waits"
    assert body =~ "Run Stride for your whole organization"

    document = LazyHTML.from_document(body)

    for {section_id, subsections} <- @measure_govern_sections do
      section = LazyHTML.query(document, "main section##{section_id}")
      items = section |> LazyHTML.query("[data-showcase-item]") |> Enum.to_list()
      assert length(items) == length(subsections), "#{section_id} has #{length(items)} items"

      for {item, {heading, image, guide_id}} <- Enum.zip(items, subsections) do
        assert item |> LazyHTML.query("h3") |> LazyHTML.text() |> String.trim() == heading

        assert [src] = item |> LazyHTML.query("img") |> LazyHTML.attribute("src")
        assert src =~ "/images/marketing/#{image}", "#{heading}: expected #{image}, got #{src}"

        # Exactly one link, to a /resources/<id> guide.
        assert [href] = item |> LazyHTML.query("a") |> LazyHTML.attribute("href")
        assert href == "/resources/#{guide_id}", "#{heading} links to #{href}"
      end
    end

    # Every guide the sections link to exists and opens.
    guide_ids =
      for {_section, subsections} <- @measure_govern_sections,
          {_heading, _image, guide_id} <- subsections,
          uniq: true,
          do: guide_id

    for guide_id <- guide_ids do
      assert {:ok, _guide} = KanbanWeb.ResourcesLive.HowToData.get_how_to(guide_id)
      assert build_conn() |> get("/resources/#{guide_id}") |> html_response(200)
    end

    # Claims the code does not back stay off the page: no agent-versus-human
    # chart, and single sign-on never replaces passwords.
    refute body =~ "split by agent vs human"
    refute body =~ ~r/SSO[- ]only/i
    assert body =~ "Members who have a password can still use it."

    # The plan limits are stated as applying only when plans are switched on,
    # which is off by default.
    assert body =~ "When a Stride has its plans switched on, a free board holds up to 3 people"
    assert body =~ "With plans switched off"
  end

  # Four phrases per locale: the hero headline, a Build heading, the Operate
  # heading and the Govern heading. Like the
  # /workflows test below, the locale is seeded into the session so the real
  # KanbanWeb.Plugs.Locale path sets it.
  @product_translations %{
    "de" => [
      "Das Board, das Ihre Leute und Ihre Agenten teilen.",
      "Alles, was ein Agent braucht, in einer Aufgabe",
      "Arbeit in Bewegung halten, sobald sie beginnt",
      "Stride für Ihre gesamte Organisation"
    ],
    "es" => [
      "El tablero que comparten tu equipo y tus agentes.",
      "Todo lo que un agente necesita, en una sola tarea",
      "Mantén el trabajo en marcha una vez que empieza",
      "Usa Stride en toda tu organización"
    ],
    "fr" => [
      "Le tableau que partagent vos équipes et vos agents.",
      "Tout ce dont un agent a besoin, dans une seule tâche",
      "Faites avancer le travail une fois lancé",
      "Stride pour toute votre organisation"
    ],
    "ja" => [
      "人とエージェントが共有するボード。",
      "エージェントに必要なすべてを、1つのタスクに",
      "始まった仕事を止めない",
      "組織全体で Stride を運用する"
    ],
    "pt" => [
      "O quadro que sua equipe e seus agentes compartilham.",
      "Tudo o que um agente precisa, em uma só tarefa",
      "Mantenha o trabalho andando depois que ele começa",
      "Use o Stride em toda a sua organização"
    ],
    "zh" => [
      "你的团队与代理共享的看板。",
      "代理所需的一切，尽在一个任务中",
      "工作一旦开始，就让它持续推进",
      "在整个组织中运行 Stride"
    ]
  }

  for {locale, expected} <- @product_translations do
    test "GET /product renders translated copy under #{locale}", %{conn: conn} do
      body =
        conn
        |> Plug.Test.init_test_session(%{"locale" => unquote(locale)})
        |> get(~p"/product")
        |> html_response(200)

      for phrase <- unquote(expected) do
        assert body =~ phrase,
               "expected #{unquote(locale)} translation #{inspect(phrase)} on /product"
      end

      refute body =~ "The board your people and your agents share."
      refute body =~ "Everything an agent needs, in one task"
      refute body =~ "Keep work moving once it starts"
      refute body =~ "Run Stride for your whole organization"
    end
  end

  # The 375px and long-heading edge cases: every screenshot scales down to the
  # viewport, and the hero and theme headings may break and hyphenate a long
  # German or French word instead of overflowing.
  for locale <- ~w(en de fr) do
    test "GET /product keeps screenshots and headings inside a narrow screen under #{locale}",
         %{conn: conn} do
      main =
        conn
        |> Plug.Test.init_test_session(%{"locale" => unquote(locale)})
        |> get(~p"/product")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("main")

      images = LazyHTML.query(main, "img")
      assert Enum.count(images) == length(@product_images)

      for img <- images do
        [class] = LazyHTML.attribute(img, "class")
        classes = String.split(class)
        assert "max-w-full" in classes and "h-auto" in classes, "#{class} can overflow"
      end

      headings = LazyHTML.query(main, "h1, h2[id$=\"-heading\"]")
      assert Enum.count(headings) == 7

      for heading <- headings do
        [style] = LazyHTML.attribute(heading, "style")
        assert style =~ "overflow-wrap: break-word", "#{LazyHTML.text(heading)} cannot wrap"
        assert style =~ "hyphens: auto", "#{LazyHTML.text(heading)} cannot hyphenate"
      end
    end
  end

  # One screenshot per stage of the lifecycle (W2460), in page order. The Review
  # step shows two: the reviewer's report and the behaviour test matrix.
  @workflows_images ~w(
    workflows-requirements.png
    workflows-ready.png
    workflows-needs-review.png
    workflows-claim.png
    workflows-explore.png
    workflows-implement.png
    workflows-review-report.png
    workflows-review-matrix.png
    workflows-validate.png
    workflows-flagged-for-review.png
    workflows-cleared-to-ship.png
  )

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

    main = body |> LazyHTML.from_document() |> LazyHTML.query("main")
    images = LazyHTML.query(main, "img")

    # Every stage shows its screenshot, in page order, and nothing else.
    assert Enum.flat_map(images, &LazyHTML.attribute(&1, "src")) ==
             Enum.map(@workflows_images, &"/images/marketing/#{&1}")

    # Each one has alt text, loads lazily and scales down to a 375px screen.
    for img <- images do
      [alt] = LazyHTML.attribute(img, "alt")
      assert String.trim(alt) != ""
      assert LazyHTML.attribute(img, "loading") == ["lazy"]
      [class] = LazyHTML.attribute(img, "class")
      classes = String.split(class)
      assert "max-w-full" in classes and "h-auto" in classes, "#{class} can overflow"
    end

    # The five lifecycle steps are still disclosures, and their pictures sit
    # inside them (two for Review).
    assert main |> LazyHTML.query("details") |> Enum.count() == 5
    assert main |> LazyHTML.query("details > summary") |> Enum.count() == 5
    assert main |> LazyHTML.query("details img") |> Enum.count() == 6

    # Copy that the code contradicted (W2460): new tasks land in the Backlog,
    # the claim itself moves the card to Doing, and the review queue offers
    # only Approve and Request changes.
    assert body =~ "The goal and its tasks land in the Backlog."
    refute body =~ "land in Ready"
    refute body =~ "prior to the task moving to the Doing column"
    refute body =~ "sends it back"
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

      # Every screenshot's alt text is translated too: none is left in English.
      english_alts = build_conn() |> get(~p"/workflows") |> html_response(200) |> image_alts()
      translated_alts = image_alts(body)

      assert length(translated_alts) == length(@workflows_images)
      english_set = MapSet.new(english_alts)
      assert translated_alts |> MapSet.new() |> MapSet.disjoint?(english_set)
    end
  end

  defp image_alts(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("main img")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "alt"))
  end

  # The setup sections (W2461): the runtimes with a published Stride plugin,
  # the .stride.md hook example and the quality gates. The runtime list is the
  # onboarding registry's, each checked against a public plugin repository.
  @workflows_runtimes [
    "Claude Code",
    "GitHub Copilot CLI",
    "Gemini CLI",
    "Codex CLI",
    "OpenCode",
    "Pi"
  ]
  @workflows_hooks ~w(before_doing after_doing before_review after_review after_goal)

  defp workflows_main(conn) do
    conn
    |> get(~p"/workflows")
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query("main")
  end

  defp texts(node, selector) do
    node |> LazyHTML.query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  test "GET /workflows shows supported runtimes and the quality gates", %{conn: conn} do
    main = workflows_main(conn)

    # Exactly the six runtimes with a Stride plugin, each linking to its
    # public repository in a new tab, and no rule-file-only tool.
    assert texts(main, "#runtimes [data-runtime] h3 a") == @workflows_runtimes

    links = LazyHTML.query(main, "#runtimes [data-runtime] h3 a")

    assert Enum.flat_map(links, &LazyHTML.attribute(&1, "href")) ==
             Enum.map(KanbanWeb.OnboardingPlugins.agents(), & &1.workflow_url)

    for link <- links do
      [href] = LazyHTML.attribute(link, "href")
      assert String.starts_with?(href, "https://github.com/cheezy/")
      assert LazyHTML.attribute(link, "target") == ["_blank"]
      [rel] = LazyHTML.attribute(link, "rel")
      assert rel =~ "noopener"
    end

    runtimes_text = main |> LazyHTML.query("#runtimes") |> LazyHTML.text()

    for tool <- ["Cursor", "Windsurf", "Continue"] do
      refute runtimes_text =~ tool
    end

    # MCP is the route for any other client, with its guide.
    mcp = LazyHTML.query(main, ~s(#runtimes [data-runtime="mcp"]))
    assert LazyHTML.text(mcp) =~ "Any MCP client"
    assert LazyHTML.text(mcp) =~ "paid plans"

    assert mcp
           |> LazyHTML.query(~s(a[href="/resources/connecting-an-mcp-client"]))
           |> Enum.count() == 1

    # The gates are described in lifecycle order, then how work unblocks.
    gates = LazyHTML.query(main, "#quality-gates li[data-gate]")

    assert Enum.flat_map(gates, &LazyHTML.attribute(&1, "data-gate")) ==
             ~w(explore review security-review exploratory-testing dependencies)

    assert texts(main, "#quality-gates li[data-gate] h3 code") ==
             ~w(task-explorer planner task-reviewer stride-security-review stride-exploratory-testing after_goal)

    gates_text = main |> LazyHTML.query("#quality-gates [data-gate]") |> LazyHTML.text()

    positions =
      for term <-
            ~w(task-explorer task-reviewer stride-security-review stride-exploratory-testing after_goal) do
        {index, _length} = :binary.match(gates_text, term)
        index
      end

    assert positions == Enum.sort(positions)
    assert gates_text =~ "every task it depends on is Done"

    # The diagram draws the same order, from claim to Done.
    chain = texts(main, "#quality-gates > ol > li")
    assert List.first(chain) == "before_doing"
    assert List.last(chain) == "Done"

    assert Enum.filter(chain, &(&1 in ~w(task-explorer task-reviewer after_doing))) ==
             ~w(task-explorer task-reviewer after_doing)

    # The new sections add no disclosure and no screenshot.
    assert main |> LazyHTML.query("#runtimes img, #hooks img, #quality-gates img") |> Enum.count() ==
             0
  end

  test "GET /workflows lists all five hooks in the .stride.md example", %{conn: conn} do
    main = workflows_main(conn)

    [pre] = main |> LazyHTML.query("#hooks pre") |> Enum.to_list()

    # Long lines scroll inside the box on a 375px screen, and the box can take
    # keyboard focus to scroll.
    [class] = LazyHTML.attribute(pre, "class")
    assert "overflow-x-auto" in String.split(class)
    assert LazyHTML.attribute(pre, "tabindex") == ["0"]

    code = pre |> LazyHTML.query("code") |> LazyHTML.text()
    assert code == KanbanWeb.PageHTML.stride_md_snippet()

    # Every hook appears as its own section, once, in firing order — so a
    # dropped or renamed hook fails here.
    assert Regex.scan(~r/^## (\w+)$/m, code, capture: :all_but_first) |> List.flatten() ==
             @workflows_hooks

    # Each hook name renders as code beside what it is for.
    assert texts(main, "#hooks dt code") == @workflows_hooks
    assert main |> LazyHTML.query("#hooks dd") |> Enum.count() == 5

    for dd <- texts(main, "#hooks dd"), do: assert(dd != "")
  end

  test "GET /workflows renders translated copy under each locale" do
    setup_translations = %{
      "de" => ["Funktioniert mit deinem Agenten", "Die Qualitätsprüfungen rund um den Code"],
      "es" => ["Funciona con tu agente", "Los controles de calidad en torno al código"],
      "fr" => ["Fonctionne avec votre agent", "Les contrôles qualité autour du code"],
      "ja" => ["あなたのエージェントで動く", "コードを囲む品質ゲート"],
      "pt" => ["Funciona com o seu agente", "Os controles de qualidade em torno do código"],
      "zh" => ["适用于你的代理", "围绕代码的质量关卡"]
    }

    for {locale, expected} <- setup_translations do
      body =
        build_conn()
        |> Plug.Test.init_test_session(%{"locale" => locale})
        |> get(~p"/workflows")
        |> html_response(200)

      for phrase <- expected do
        assert body =~ phrase, "expected #{locale} translation #{inspect(phrase)} on /workflows"
      end

      refute body =~ "Works with your agent"
      refute body =~ "The quality gates around the code"

      main = body |> LazyHTML.from_document() |> LazyHTML.query("main")

      # Product names and the .stride.md example are not translated.
      assert texts(main, "#runtimes [data-runtime] h3 a") == @workflows_runtimes
      assert texts(main, "#hooks dt code") == @workflows_hooks

      assert main |> LazyHTML.query("#hooks pre code") |> LazyHTML.text() ==
               KanbanWeb.PageHTML.stride_md_snippet()
    end
  end

  test "PageHTML.stride_md_snippet/0 is a generic example with no host or token" do
    snippet = KanbanWeb.PageHTML.stride_md_snippet()

    assert String.starts_with?(snippet, "# Stride Configuration\n")

    assert Regex.scan(~r/^## (\w+)$/m, snippet, capture: :all_but_first) |> List.flatten() ==
             @workflows_hooks

    # One bash block per hook.
    assert length(Regex.scan(~r/^```bash$/m, snippet)) == 5
    refute snippet =~ "://"
    refute snippet =~ ~r/stride_(dev|test|prod|live)_/
    refute snippet =~ "Bearer"
    refute snippet =~ "release"
  end

  test "PageHTML.workflow_runtimes/0 follows the onboarding registry" do
    runtimes = KanbanWeb.PageHTML.workflow_runtimes()

    assert Enum.map(runtimes, & &1.name) == @workflows_runtimes

    assert Enum.map(runtimes, &{&1.key, &1.url}) ==
             Enum.map(KanbanWeb.OnboardingPlugins.agents(), &{&1.key, &1.workflow_url})

    for runtime <- runtimes, do: assert(runtime.install =~ ~r/\S/)
  end

  test "PageHTML.workflow_gate_chain/0 marks only the last step as last" do
    chain = KanbanWeb.PageHTML.workflow_gate_chain()

    assert Enum.map(chain, &elem(&1, 2)) == List.duplicate(false, length(chain) - 1) ++ [true]

    assert Enum.map(chain, &elem(&1, 1)) |> Enum.uniq() |> Enum.sort() ==
             [:hook, :optional, :step, :subagent]

    assert [{"before_doing", :hook, false} | _] = chain
  end

  test "PageHTML.workflow_hooks/0 and workflow_quality_gates/0 cover every hook and gate" do
    assert Enum.map(KanbanWeb.PageHTML.workflow_hooks(), &elem(&1, 0)) == @workflows_hooks

    gates = KanbanWeb.PageHTML.workflow_quality_gates()

    assert Enum.map(gates, &elem(&1, 0)) ==
             ~w(explore review security-review exploratory-testing dependencies)

    # Only the two plugin-gated reviews are optional, and their pills say so.
    for {gate, pills, _title, optional?, _body} <- gates do
      assert optional? == gate in ~w(security-review exploratory-testing)
      assert optional? == Enum.any?(pills, &match?({_, :optional}, &1))
    end
  end

  test "PageHTML.workflow_pill/1 colours each kind of pill" do
    import Phoenix.Component, only: [sigil_H: 2]
    import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

    assigns = %{}

    hook =
      rendered_to_string(~H"""
      <KanbanWeb.PageHTML.workflow_pill kind={:hook}>after_goal</KanbanWeb.PageHTML.workflow_pill>
      """)

    assert hook =~ "var(--st-doing)"
    assert hook =~ "after_goal"
    refute hook =~ "border-dashed"

    optional =
      rendered_to_string(~H"""
      <KanbanWeb.PageHTML.workflow_pill kind={:optional}>
        stride-security-review
      </KanbanWeb.PageHTML.workflow_pill>
      """)

    assert optional =~ "border-dashed"
    assert optional =~ "var(--stride-violet-ink)"
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

    test "joins its Japanese and Chinese sentences with no space after 。", %{conn: conn} do
      for locale <- ~w(ja zh) do
        text =
          conn
          |> init_test_session(%{locale: locale})
          |> get(~p"/changelog")
          |> html_response(200)
          |> LazyHTML.from_document()
          |> LazyHTML.query("[data-changelog-announcement] p")
          |> Enum.map(&LazyHTML.text/1)

        refute Enum.any?(text, &(&1 =~ ~r/。\s+\S/u)),
               "space after 。 in the #{locale} announcement"
      end
    end

    test "separates its sentences with a space in English", %{conn: conn} do
      text =
        conn
        |> get(~p"/changelog")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("[data-changelog-announcement]")
        |> LazyHTML.text()

      assert text =~ "Launch date: to be announced on this page. The changes below take effect"
      assert text =~ "on launch day. Tasks waiting for you"
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

    test "stores a signed-in user's choice on the account", %{conn: conn} do
      user = Kanban.AccountsFixtures.user_fixture()
      assert user.locale == nil

      conn = conn |> log_in_user(user) |> post(~p"/locale/fr")

      assert get_session(conn, :locale) == "fr"
      assert Kanban.Repo.get!(Kanban.Accounts.User, user.id).locale == "fr"
    end

    test "ignores an unsupported locale for a signed-in user", %{conn: conn} do
      user = Kanban.AccountsFixtures.user_fixture()
      {:ok, _} = Kanban.Accounts.update_user_locale(user, "de")

      conn = conn |> log_in_user(user) |> post(~p"/locale/xx")

      assert redirected_to(conn) == "/"
      assert Kanban.Repo.get!(Kanban.Accounts.User, user.id).locale == "de"
    end
  end
end
