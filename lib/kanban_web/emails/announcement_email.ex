defmodule KanbanWeb.Emails.AnnouncementEmail do
  @moduledoc """
  Builds a one-time service announcement email (W2416), sent by
  `Kanban.Notifications.AnnouncementWorker`.

  The `"organizations-launch"` announcement repeats the Organizations and Free
  plan entry on `/changelog`, reusing its translated text, and links to
  `/changelog`, `/pricing`, its `#contact` section, `/terms`, `/review` and
  `/my-work`. In a locale other than English each link carries `?locale=`, so
  the page opens in the email's language (`KanbanWeb.Plugs.Locale`). It is a
  service notice sent to every
  account, so it carries no unsubscribe link or `List-Unsubscribe` header:
  those are for the notification emails a user can turn off.

  Every value interpolated into the HTML body — text and hrefs alike — is
  HTML-escaped; the text body carries the same content unescaped. The email
  renders in the calling process's Gettext locale, which the worker sets to
  the recipient's.
  """

  use Gettext, backend: KanbanWeb.Gettext
  use KanbanWeb, :verified_routes

  import Swoosh.Email
  import KanbanWeb.Emails.EmailHelpers, only: [escape: 1]

  alias Kanban.Accounts.User
  alias KanbanWeb.Emails.EmailHelpers
  alias KanbanWeb.Sentences

  # dark-mode-ignore: email HTML cannot use the app's CSS variables
  @rule_style "border:none;border-top:1px solid #d4d4d8;margin:24px 0 12px"
  @paragraph_style "margin:0 0 12px"
  @heading_style "font-size:16px;margin:20px 0 8px"
  @list_style "margin:0 0 12px;padding-left:20px"
  @footer_style "font-size:12px;margin:0;opacity:0.75"

  @doc """
  Builds the announcement `key` for `user`. Only `"organizations-launch"`
  has an email.
  """
  @spec build(User.t(), String.t()) :: Swoosh.Email.t()
  def build(%User{} = user, "organizations-launch" = key) do
    content = organizations_launch()
    links = links()

    new()
    |> to(user.email)
    |> from(EmailHelpers.from())
    |> subject("[Stride] " <> content.heading)
    |> html_body(render_html(content, links))
    |> text_body(render_text(content, links))
    |> header("Message-ID", "<announcement-#{key}-#{user.id}@stridelikeaboss.com>")
  end

  # The same text as the announcement on /changelog
  # (lib/kanban_web/controllers/page_html/changelog.html.heex), so the
  # existing translations apply. Its "to be announced on this page" line is
  # replaced: the runbook publishes the date there before this email is sent.
  defp organizations_launch do
    %{
      heading: gettext("Announcing Organizations and the Free plan"),
      intro: [
        gettext(
          "Stride is adding a paid Organization plan. Stride stays free for individuals and small teams, and a few features become available to organizations only."
        ),
        Sentences.join([
          gettext("The launch date is published on the Stride changelog."),
          gettext("The changes below take effect on launch day.")
        ])
      ],
      sections: [
        free_boards_section(),
        organization_only_section(),
        staying_free_section(),
        reviewers_section(),
        questions_section()
      ],
      notice:
        gettext(
          "You are receiving this one-time service notice because you have a Stride account. It is sent to every account, whatever your notification settings."
        )
    }
  end

  defp free_boards_section do
    {gettext("Free boards: up to 3 people"),
     {:list,
      [
        gettext("Up to 3 people per board — AI agents do not count"),
        gettext(
          "Existing boards keep every member they already have. A board over the limit cannot add anyone until it has fewer than 3 people."
        )
      ]}}
  end

  defp organization_only_section do
    {gettext("Becoming Organization-only"),
     {:list,
      [
        gettext("Notifications"),
        gettext("Bulk actions"),
        gettext("Integrations (webhooks)") <>
          " — " <>
          gettext(
            "webhooks on free boards are paused, not deleted, and resume when the board moves into an organization. Events that happen while paused are not delivered later."
          ),
        gettext("Task telemetry fields"),
        gettext("MCP access")
      ]}}
  end

  defp staying_free_section do
    {gettext("Staying free"),
     {:list,
      [
        gettext("Unlimited boards, tasks and goals"),
        gettext("The full REST API and client-side hooks"),
        gettext("Metrics and exports")
      ]}}
  end

  defp reviewers_section do
    {gettext("If you review tasks on a free board"),
     {:text,
      Sentences.join([
        gettext("Free accounts stop receiving notification emails on launch day."),
        gettext("Tasks waiting for you are always listed in the Review queue and My Work.")
      ])}}
  end

  defp questions_section do
    {gettext("Questions"),
     {:text,
      gettext("To move your team into an organization, or to ask about pricing, contact Stride.")}}
  end

  # Verified routes, so a renamed page fails to compile rather than sending a
  # dead link; announcement_email_test.exs pins the rendered hrefs.
  defp links do
    Enum.map(page_links() ++ app_links(), fn {label, url, fragment} ->
      {label, localized(url) <> fragment}
    end)
  end

  defp page_links do
    [
      {gettext("Read the changelog"), url(~p"/changelog"), ""},
      {gettext("Pricing"), url(~p"/pricing"), ""},
      {gettext("Contact us"), url(~p"/pricing"), "#contact"},
      {gettext("Terms of Service"), url(~p"/terms"), ""}
    ]
  end

  defp app_links do
    [
      {gettext("Review queue"), url(~p"/review"), ""},
      {gettext("My Work"), url(~p"/my-work"), ""}
    ]
  end

  defp localized(url) do
    case Gettext.get_locale(KanbanWeb.Gettext) do
      "en" -> url
      locale -> url <> "?" <> URI.encode_query(locale: locale)
    end
  end

  defp render_html(content, links) do
    """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><meta name="color-scheme" content="light dark"></head>
    <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;line-height:1.5;max-width:600px;margin:0 auto;padding:24px">
    <h1 style="font-size:20px;margin:0 0 16px">#{escape(content.heading)}</h1>
    #{Enum.map_join(content.intro, "\n", &html_paragraph/1)}
    #{Enum.map_join(content.sections, "\n", &html_section/1)}
    #{html_links(links)}
    <hr style="#{@rule_style}">
    <p style="#{@footer_style}">#{escape(content.notice)}</p>
    </body>
    </html>
    """
  end

  defp html_paragraph(text), do: ~s(<p style="#{@paragraph_style}">#{escape(text)}</p>)

  defp html_section({heading, body}) do
    ~s(<h2 style="#{@heading_style}">#{escape(heading)}</h2>\n) <> html_section_body(body)
  end

  defp html_section_body({:list, items}) do
    ~s(<ul style="#{@list_style}">) <>
      Enum.map_join(items, "", &"<li>#{escape(&1)}</li>") <> "</ul>"
  end

  defp html_section_body({:text, text}), do: html_paragraph(text)

  defp html_links([{label, url} | rest]) do
    primary =
      ~s(<a href="#{escape(url)}" style="#{EmailHelpers.button_style()}">#{escape(label)}</a>)

    others =
      Enum.map_join(rest, " · ", fn {l, u} -> ~s(<a href="#{escape(u)}">#{escape(l)}</a>) end)

    ~s(<p style="margin:24px 0">#{primary}</p>\n<p style="#{@paragraph_style}">#{others}</p>)
  end

  defp render_text(content, links) do
    sections = Enum.map(content.sections, &text_section/1)
    link_lines = Enum.map_join(links, "\n", fn {label, url} -> "#{label}: #{url}" end)

    Enum.join(
      [content.heading | content.intro] ++ sections ++ [link_lines, "--\n" <> content.notice],
      "\n\n"
    )
  end

  defp text_section({heading, {:list, items}}),
    do: Enum.join([heading | Enum.map(items, &("- " <> &1))], "\n")

  defp text_section({heading, {:text, text}}), do: heading <> "\n" <> text
end
