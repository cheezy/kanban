defmodule KanbanWeb.Emails.EmailHelpers do
  @moduledoc """
  Pieces shared by the notification emails: the sender, HTML escaping, the
  signed unsubscribe links and the footer that carries them, and the
  RFC 8058 `List-Unsubscribe` headers.

  `KanbanWeb.Emails.NotificationEmail` and `KanbanWeb.Emails.DigestEmail`
  build on these, so every email offers the same one-click unsubscribe.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Swoosh.Email

  alias KanbanWeb.UnsubscribeToken

  # Module attributes cannot use ~p, so these app-relative paths are plain
  # strings; notification_email_test.exs pins the rendered hrefs.
  # The token travels as a query parameter, never a path segment, so request
  # logs (which record the path) never contain it; "token" is listed in
  # :filter_parameters so logged params are redacted too.
  @unsubscribe_path "/notifications/unsubscribe?token="
  # RFC 8058: mail providers POST to the List-Unsubscribe URL itself, so the
  # header points at the session-less one-click endpoint while the footer
  # link opens the confirmation page.
  @one_click_path "/notifications/unsubscribe/one-click?token="
  @preferences_path "/users/notifications"
  @from {"Stride Support", "noreply@stridelikeaboss.com"}

  # Email clients cannot resolve the app's CSS theme tokens, so mail styles use
  # fixed colors chosen to read on both light and dark mail backgrounds.
  # dark-mode-ignore: email HTML cannot use the app's CSS variables
  @button_style "display:inline-block;padding:10px 18px;border-radius:6px;background:#4f46e5;color:#ffffff;text-decoration:none"
  # dark-mode-ignore: email HTML cannot use the app's CSS variables
  @rule_style "border:none;border-top:1px solid #d4d4d8;margin:24px 0 12px"
  @footer_style "font-size:12px;margin:0"
  # Mail clients pick their own light or dark background, and no fixed grey
  # reaches 4.5:1 on both, so the notice dims the client's text colour; the
  # links keep their full colour.
  @notice_style "opacity:0.75"

  @type urls :: %{unsubscribe: String.t(), one_click: String.t(), preferences: String.t()}

  @doc "The sender every notification email uses."
  @spec from() :: {String.t(), String.t()}
  def from, do: @from

  @doc "Inline style for the primary call-to-action link."
  @spec button_style() :: String.t()
  def button_style, do: @button_style

  @doc "HTML-escapes `text` for interpolation into an email body or href."
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  @doc """
  Absolute URLs for the footer and headers: the unsubscribe confirmation
  page, the one-click endpoint (both carrying a token signed for `user_id`
  and `event_type`), and the preferences page.
  """
  @spec unsubscribe_urls(pos_integer(), atom()) :: urls()
  def unsubscribe_urls(user_id, event_type) do
    base = KanbanWeb.Endpoint.url()
    token = UnsubscribeToken.sign(user_id, event_type)

    %{
      unsubscribe: base <> @unsubscribe_path <> URI.encode_www_form(token),
      one_click: base <> @one_click_path <> URI.encode_www_form(token),
      preferences: base <> @preferences_path
    }
  end

  @doc "Adds the RFC 8058 one-click `List-Unsubscribe` headers."
  @spec put_unsubscribe_headers(Swoosh.Email.t(), urls()) :: Swoosh.Email.t()
  def put_unsubscribe_headers(email, urls) do
    email
    |> header("List-Unsubscribe", "<" <> urls.one_click <> ">")
    |> header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
  end

  @doc "The HTML footer: why the email was sent, unsubscribe and preferences links."
  @spec footer_html(urls()) :: String.t()
  def footer_html(urls) do
    """
    <hr style="#{@rule_style}">
    <p style="#{@footer_style}"><span style="#{@notice_style}">#{escape(gettext("You are receiving this because email notifications for this event type are on."))}</span>
    <a href="#{escape(urls.unsubscribe)}">#{escape(gettext("Unsubscribe from these emails"))}</a> ·
    <a href="#{escape(urls.preferences)}">#{escape(gettext("Manage notification preferences"))}</a></p>
    """
  end

  @doc "The text footer, as lines to join after the body."
  @spec footer_text_lines(urls()) :: [String.t()]
  def footer_text_lines(urls) do
    [
      "--",
      gettext("You are receiving this because email notifications for this event type are on."),
      "#{gettext("Unsubscribe from these emails")}: #{urls.unsubscribe}",
      "#{gettext("Manage notification preferences")}: #{urls.preferences}"
    ]
  end
end
