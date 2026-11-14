defmodule KanbanWeb.Emails.AuditStreamEmailTest do
  use ExUnit.Case, async: true

  alias Kanban.Accounts.User
  alias KanbanWeb.Emails.AuditStreamEmail

  @user %User{id: 42, email: "admin@example.com"}
  @ref "5f0c1a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b"

  @splunk %{
    id: 7,
    kind: :splunk_hec,
    name: "Main SIEM",
    url_host: "collector.example.com",
    url_hint: "ndex",
    credential_hint: "wxyz",
    site: nil
  }

  @datadog %{
    id: 8,
    kind: :datadog,
    name: "Datadog EU",
    url_host: nil,
    url_hint: nil,
    credential_hint: "9876",
    site: "datadoghq.eu"
  }

  @gap %{
    reason: :retention,
    events: 3,
    first_at: ~U[2026-10-01 08:00:00Z],
    last_at: ~U[2026-10-03 17:30:00Z],
    opened: true
  }

  # Words that appear only in the English text of these emails, so a
  # translated email that still carries one was not translated.
  @english_labels [
    "created the audit streaming destination",
    "Open the destination",
    "Credential"
  ]

  defp alert(kind, overrides \\ %{}) do
    Map.merge(
      %{kind: kind, ref: @ref, destination: @splunk, actor: {:user, "alex@example.com"}},
      Map.new(overrides)
    )
  end

  defp build(alert, locale \\ "en") do
    Gettext.with_locale(KanbanWeb.Gettext, locale, fn -> AuditStreamEmail.build(@user, alert) end)
  end

  defp all_alerts do
    [
      alert(:created, start_from: "now"),
      alert(:created, start_from: "7d"),
      alert(:updated, changed: ["url", "credential", "index"]),
      alert(:paused),
      alert(:resumed),
      alert(:deleted),
      alert(:failing, reason: :no_success, actor: :stride),
      alert(:failing, reason: :credentials_unreadable, actor: :stride),
      alert(:recovered, actor: :stride),
      alert(:txid_reset, actor: :stride),
      alert(:gap, gap: @gap, actor: :stride),
      alert(:gap, gap: %{@gap | opened: false}, actor: :stride)
    ]
  end

  test "each kind's subject and body name the actor, destination, type, host and hint and link to its page" do
    for %{kind: kind} = alert <- all_alerts() do
      email = build(alert)

      assert email.to == [{"", "admin@example.com"}]
      assert String.starts_with?(email.subject, "[Stride] ")
      assert email.subject =~ "Main SIEM", "#{kind} subject"

      for body <- [email.text_body, email.html_body] do
        assert body =~ "Main SIEM", "#{kind} names the destination"
        assert body =~ "Splunk", "#{kind} names the type"
        assert body =~ "collector.example.com", "#{kind} names the host"
        assert body =~ "•••• wxyz", "#{kind} names the credential hint"
      end

      if kind in [:failing, :recovered, :txid_reset, :gap] do
        assert email.text_body =~ "By: Stride recorded this"
      else
        assert email.text_body =~ "alex@example.com"
      end

      if kind == :deleted,
        do: assert(email.text_body =~ "/org/audit/streaming\n"),
        else: assert(email.text_body =~ "/org/audit/streaming/7")

      assert email.headers["Message-ID"] ==
               "<audit-stream-#{@ref}-42@stridelikeaboss.com>"
    end
  end

  test "a catch-up creation names the catch-up in the subject and from now does not" do
    assert build(alert(:created, start_from: "now")).subject ==
             "[Stride] Audit streaming destination created: \u2068Main SIEM\u2069"

    for {start_from, words} <- [
          {"24h", "catching up the last 24 hours"},
          {"7d", "catching up the last 7 days"},
          {"all", "sending the whole audit log"}
        ] do
      email = build(alert(:created, start_from: start_from))
      assert email.subject =~ words
      assert email.text_body =~ "It is catching up"
    end

    datadog = build(alert(:created, start_from: "17h", destination: @datadog))
    assert datadog.subject =~ "catching up the last 17 hours"
    assert datadog.text_body =~ "Start from: The last 17 hours"
    refute build(alert(:created, start_from: "now")).text_body =~ "It is catching up"
  end

  test "an update names the changed fields with the destination's own labels" do
    email = build(alert(:updated, changed: ["url", "credential", "excluded_actions", "index"]))
    assert email.text_body =~ "Changed: HEC URL, HEC token, Excluded actions, Index"

    https = %{@splunk | kind: :https, credential_hint: nil}
    email = build(alert(:updated, destination: https, changed: ["header_name"]))
    assert email.text_body =~ "Changed: Authorization header name"
    assert email.html_body =~ "Authorization header name"
    refute email.text_body =~ "Signature header"
    refute email.html_body =~ "Signature header"
    assert email.text_body =~ "Credential: •••• ndex"
  end

  test "bodies escape a destination name with markup and carry no List-Unsubscribe header" do
    name = "<script>alert(1)</script> \u05E9\u05DC\u05D5\u05DD\r\nBcc: x@example.com"
    email = build(alert(:created, start_from: "now", destination: %{@splunk | name: name}))

    refute email.html_body =~ "<script>"
    assert email.html_body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute email.subject =~ "\n"
    refute email.subject =~ "\r"
    assert email.subject =~ "\u2068<script>alert(1)</script> \u05E9\u05DC\u05D5\u05DD  Bcc"
    refute Map.has_key?(email.headers, "List-Unsubscribe")
    refute email.html_body =~ "unsubscribe"
    refute email.text_body =~ "unsubscribe"
  end

  test "an actor who no longer exists is named as a deleted account" do
    email = build(alert(:paused, actor: :deleted_account))
    assert email.text_body =~ "A deleted account paused the audit streaming destination"
  end

  test "the credentials_unreadable Failing email asks to re-enter the credentials" do
    email = build(alert(:failing, reason: :credentials_unreadable, actor: :stride))

    assert email.text_body =~ "credentials can't be read"
    assert email.text_body =~ "must enter them again"
    assert email.text_body =~ "Enter the credentials again: http"
    assert email.text_body =~ "/org/audit/streaming/7/edit"
    assert email.html_body =~ "/org/audit/streaming/7/edit"
  end

  test "each failing reason has its own sentence" do
    for {reason, words} <- [
          unauthorized: "refused the credentials Stride sends",
          config_error: "its configuration is wrong",
          no_success: "No delivery has succeeded for 30 minutes",
          rejected_batch: "Retry now or Skip this batch",
          blocked_address: "until an org-admin changes its URL",
          unknown: "Deliveries to the destination are failing"
        ] do
      assert build(alert(:failing, reason: reason, actor: :stride)).text_body =~ words
    end
  end

  test "every emailed field has a label" do
    datadog = build(alert(:updated, destination: @datadog, changed: ~w(url site service tags)))
    assert datadog.text_body =~ "Changed: URL, Site, Service, Tags"

    other = build(alert(:updated, changed: ~w(include_personal_data something_else)))
    assert other.text_body =~ "Changed: Email and IP addresses, Settings"
  end

  test "a Datadog failing email says events are lost after 17 hours" do
    datadog = build(alert(:failing, reason: :unauthorized, destination: @datadog, actor: :stride))
    assert datadog.text_body =~ "within 17 hours"
    assert datadog.text_body =~ "Host: http-intake.logs.datadoghq.eu"

    refute build(alert(:failing, reason: :unauthorized, actor: :stride)).text_body =~ "17 hours"
  end

  test "the txid_reset email asks an operator to re-seed" do
    email = build(alert(:txid_reset, actor: :stride))
    assert email.subject =~ "must be re-seeded"
    assert email.text_body =~ "An operator must re-seed audit streaming"
  end

  test "a gap email gives its count, dates and reason, and a growing gap says so" do
    opened = build(alert(:gap, gap: @gap, actor: :stride))
    assert opened.subject =~ "Audit events lost for"
    assert opened.text_body =~ "3 audit events will never reach this destination."
    assert opened.text_body =~ "between 2026-10-01 08:00 and 2026-10-03 17:30 UTC"
    assert opened.text_body =~ "Reason: Deleted by retention before it was sent"
    assert opened.text_body =~ "at most once every 7 days"

    grown = build(alert(:gap, gap: %{@gap | opened: false, events: 1}, actor: :stride))
    assert grown.subject =~ "still being lost"
    assert grown.text_body =~ "1 audit event will never reach this destination."
  end

  test "renders in every locale" do
    english = Enum.map(all_alerts(), &build/1)

    for locale <- Gettext.known_locales(KanbanWeb.Gettext), locale != "en" do
      for {alert, english_email} <- Enum.zip(all_alerts(), english) do
        email = build(alert, locale)
        refute email.subject == english_email.subject, "#{alert.kind} subject in #{locale}"

        for label <- @english_labels do
          refute email.text_body =~ label, "#{inspect(label)} untranslated in #{locale}"
        end

        assert email.text_body =~ "?locale=#{locale}"
      end
    end
  end

  test "gap counts use the locale's plural forms and Japanese and Chinese sentences join with no space" do
    for locale <- ["ja", "zh"] do
      one = build(alert(:gap, gap: %{@gap | events: 1}, actor: :stride), locale)
      many = build(alert(:gap, gap: %{@gap | events: 5}, actor: :stride), locale)

      assert one.text_body =~ "1"
      assert many.text_body =~ "5"
      refute many.text_body =~ "。 ", "space after 。 in the #{locale} email"
    end

    fr = build(alert(:gap, gap: %{@gap | events: 1}, actor: :stride), "fr")
    refute fr.text_body =~ "1 audit event"
  end
end
