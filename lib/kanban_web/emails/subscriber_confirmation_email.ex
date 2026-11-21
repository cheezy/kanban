defmodule KanbanWeb.Emails.SubscriberConfirmationEmail do
  @moduledoc """
  Builds the double opt-in confirmation email of the release announcement
  list (`Kanban.Subscribers`), sent by `Kanban.Subscribers.Notifier`.

  It links to the confirmation page (`/releases/confirm`), which activates
  the address only when its button is pressed, and, like every email the list
  sends, carries an unsubscribe link (`/releases/unsubscribe`) and the
  RFC 8058 one-click `List-Unsubscribe` headers. Tokens travel only as
  `?token=` query parameters. In a locale other than English each link also
  carries `?locale=`, so the page opens in the email's language.

  Every value interpolated into the HTML body — text and hrefs alike — is
  HTML-escaped; the text body carries the same content unescaped. The email
  renders in the calling process's Gettext locale, which the notifier sets to
  the subscriber's.
  """

  use Gettext, backend: KanbanWeb.Gettext
  use KanbanWeb, :verified_routes

  import Swoosh.Email
  import KanbanWeb.Emails.EmailHelpers, only: [escape: 1]

  alias Kanban.Subscribers.Subscriber
  alias KanbanWeb.Emails.EmailHelpers

  # dark-mode-ignore: email HTML cannot use the app's CSS variables
  @rule_style "border:none;border-top:1px solid #d4d4d8;margin:24px 0 12px"
  @paragraph_style "margin:0 0 12px"
  @footer_style "font-size:12px;margin:0"

  @doc """
  Builds the confirmation email for `subscriber`, linking `confirm_token`
  and `unsubscribe_token`.
  """
  @spec build(Subscriber.t(), String.t(), String.t()) :: Swoosh.Email.t()
  def build(%Subscriber{} = subscriber, confirm_token, unsubscribe_token) do
    content = content()
    links = links(confirm_token, unsubscribe_token)

    new()
    |> to(subscriber.email)
    |> from(EmailHelpers.from())
    |> subject("[Stride] " <> content.subject)
    |> html_body(render_html(content, links))
    |> text_body(render_text(content, links))
    |> header("Message-ID", message_id(subscriber))
    |> EmailHelpers.put_list_unsubscribe_headers(links.one_click)
  end

  defp content do
    %{
      subject: gettext("Confirm your subscription to Stride release announcements"),
      heading: gettext("Confirm your subscription"),
      intro:
        gettext(
          "Someone asked to receive Stride release announcements at this address. Confirm to start receiving an email when a new version of Stride is released."
        ),
      button: gettext("Confirm subscription"),
      expiry:
        gettext(
          "This link expires in 7 days. If you did not ask for this, ignore this email and this address will not be added."
        ),
      notice:
        gettext(
          "You are receiving this email because this address was entered in the release announcement signup on the Stride changelog."
        ),
      unsubscribe: gettext("Unsubscribe")
    }
  end

  # Verified routes, so a renamed route fails to compile rather than sending
  # a dead link; subscriber_confirmation_email_test.exs pins the hrefs.
  defp links(confirm_token, unsubscribe_token) do
    locale = locale_params()

    %{
      confirm: url(~p"/releases/confirm?#{[token: confirm_token] ++ locale}"),
      unsubscribe: url(~p"/releases/unsubscribe?#{[token: unsubscribe_token] ++ locale}"),
      one_click: url(~p"/releases/unsubscribe/one-click?#{[token: unsubscribe_token] ++ locale}")
    }
  end

  defp locale_params do
    case Gettext.get_locale(KanbanWeb.Gettext) do
      "en" -> []
      locale -> [locale: locale]
    end
  end

  defp message_id(%Subscriber{id: id}),
    do: "<release-signup-#{id}-#{System.unique_integer([:positive])}@stridelikeaboss.com>"

  defp render_html(content, links) do
    """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><meta name="color-scheme" content="light dark"></head>
    <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;line-height:1.5;max-width:600px;margin:0 auto;padding:24px">
    <h1 style="font-size:20px;margin:0 0 16px">#{escape(content.heading)}</h1>
    <p style="#{@paragraph_style}">#{escape(content.intro)}</p>
    <p style="margin:24px 0"><a href="#{escape(links.confirm)}" style="#{EmailHelpers.button_style()}">#{escape(content.button)}</a></p>
    <p style="#{@paragraph_style}">#{escape(content.expiry)}</p>
    <hr style="#{@rule_style}">
    <p style="#{@footer_style}">#{escape(content.notice)}
    <a href="#{escape(links.unsubscribe)}">#{escape(content.unsubscribe)}</a></p>
    </body>
    </html>
    """
  end

  defp render_text(content, links) do
    Enum.join(
      [
        content.heading,
        content.intro,
        "#{content.button}: #{links.confirm}",
        content.expiry,
        "--\n#{content.notice}\n#{content.unsubscribe}: #{links.unsubscribe}"
      ],
      "\n\n"
    )
  end
end
