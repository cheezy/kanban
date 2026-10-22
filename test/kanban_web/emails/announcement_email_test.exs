defmodule KanbanWeb.Emails.AnnouncementEmailTest do
  use ExUnit.Case, async: true

  alias Kanban.Accounts.User
  alias KanbanWeb.Emails.AnnouncementEmail

  @user %User{id: 42, email: "announce@example.com"}
  @key "organizations-launch"

  # Every English string the email renders, so a locale that falls back to
  # English for any of them fails below.
  @english_labels [
    "Announcing Organizations and the Free plan",
    "The launch date is published on the Stride changelog.",
    "Free boards: up to 3 people",
    "Becoming Organization-only",
    "Staying free",
    "If you review tasks on a free board",
    "Read the changelog",
    "You are receiving this one-time service notice"
  ]

  defp build, do: AnnouncementEmail.build(@user, @key)

  test "addresses the user from the shared sender with a stable Message-ID" do
    email = build()

    assert email.to == [{"", "announce@example.com"}]
    assert email.from == {"Stride Support", "noreply@stridelikeaboss.com"}
    assert email.subject == "[Stride] Announcing Organizations and the Free plan"

    assert email.headers["Message-ID"] ==
             "<announcement-organizations-launch-42@stridelikeaboss.com>"
  end

  test "links to the changelog, pricing, contact, terms, review queue and My Work in both bodies" do
    email = build()
    base = KanbanWeb.Endpoint.url()

    for path <- ["/changelog", "/pricing", "/pricing#contact", "/terms", "/review", "/my-work"] do
      assert email.html_body =~ ~s(href="#{base}#{path}")
      assert email.text_body =~ "#{base}#{path}"
    end

    refute email.text_body =~ "?locale="
  end

  test "a translated email's links open the pages in its language" do
    email = Gettext.with_locale(KanbanWeb.Gettext, "de", fn -> build() end)
    base = KanbanWeb.Endpoint.url()

    for path <- ["/changelog", "/pricing", "/terms", "/review", "/my-work"] do
      assert email.html_body =~ ~s(href="#{base}#{path}?locale=de")
      assert email.text_body =~ "#{base}#{path}?locale=de"
    end

    assert email.text_body =~ "#{base}/pricing?locale=de#contact"
  end

  test "joins Japanese and Chinese sentences with no space after 。" do
    for locale <- ~w(ja zh) do
      email = Gettext.with_locale(KanbanWeb.Gettext, locale, fn -> build() end)

      refute email.text_body =~ "。 ", "space after 。 in the #{locale} email"
    end
  end

  test "names the plans as /pricing and /terms do in every translation" do
    # The /pricing and /terms wording for the Organization plan in each locale.
    names = %{
      "de" => "Organisationsplan",
      "es" => "plan Organización",
      "fr" => "offre Organisation",
      "ja" => "組織プラン",
      "pt" => "plano Organização",
      "zh" => "组织方案"
    }

    for {locale, name} <- names do
      email = Gettext.with_locale(KanbanWeb.Gettext, locale, fn -> build() end)

      assert email.text_body =~ name, "#{locale} email does not say #{name}"
      refute email.text_body =~ "Free", "#{locale} email names the Free plan in English"
      refute email.text_body =~ "Organization", "#{locale} email names the plan in English"
    end
  end

  test "carries the changelog announcement's content" do
    email = build()

    for text <- [
          "Stride is adding a paid Organization plan.",
          "Up to 3 people per board — AI agents do not count",
          "Integrations (webhooks) — webhooks on free boards are paused, not deleted",
          "MCP access",
          "Unlimited boards, tasks and goals",
          "Free accounts stop receiving notification emails on launch day.",
          "To move your team into an organization, or to ask about pricing, contact Stride."
        ] do
      assert email.text_body =~ text
      assert email.html_body =~ text
    end
  end

  test "is a service notice: no unsubscribe link or List-Unsubscribe header" do
    email = build()

    refute Map.has_key?(email.headers, "List-Unsubscribe")
    refute Map.has_key?(email.headers, "List-Unsubscribe-Post")
    refute email.html_body =~ "unsubscribe"
    assert email.text_body =~ "You are receiving this one-time service notice"
  end

  test "carries no per-user secret or token" do
    email = build()

    refute email.html_body =~ "token"
    refute email.text_body =~ "token"
  end

  test "renders in every supported locale" do
    english = build()

    for locale <- ~w(de es fr ja pt zh) do
      email = Gettext.with_locale(KanbanWeb.Gettext, locale, fn -> build() end)

      refute email.subject == english.subject, "subject not translated for #{locale}"

      for label <- @english_labels do
        refute email.html_body =~ label, "#{label} not translated for #{locale}"
        refute email.text_body =~ label, "#{label} not translated for #{locale}"
      end
    end
  end
end
