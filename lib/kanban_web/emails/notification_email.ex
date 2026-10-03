defmodule KanbanWeb.Emails.NotificationEmail do
  @moduledoc """
  Builds the email for one `Kanban.Notifications.Notification`.

  The subject comes only from a translated heading for the event type, so
  free text carried by a notification (titles, review notes, unclaim
  reasons) never reaches it. Every value interpolated into the HTML body —
  text and hrefs alike — is HTML-escaped; the text body carries the same
  content unescaped.

  Every email carries a signed one-click unsubscribe link in the footer and
  in the `List-Unsubscribe` / `List-Unsubscribe-Post` headers (RFC 8058).

  Emails render in the calling process's Gettext locale; Oban jobs run with
  the default locale.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Swoosh.Email

  alias Kanban.Accounts.User
  alias Kanban.Notifications.Notification
  alias KanbanWeb.NotificationLabels
  alias KanbanWeb.UnsubscribeToken

  # The unsubscribe (W2202) and preferences (W2206) routes do not exist yet,
  # so these paths are plain strings rather than ~p sigils; switch to
  # url(~p"...") once those routes land.
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
  # dark-mode-ignore: email HTML cannot use the app's CSS variables
  @footer_style "font-size:12px;color:#71717a;margin:0"

  @doc """
  Builds the email for `notification`, addressed to `user`.

  `notification.board` may be preloaded to add a board line; it is optional.
  """
  @spec build(Notification.t(), User.t()) :: Swoosh.Email.t()
  def build(%Notification{} = notification, %User{} = user) do
    urls = urls(notification, user)
    heading = heading(notification.event_type)
    lines = content_lines(notification)

    new()
    |> to(user.email)
    |> from(@from)
    |> subject("[Stride] " <> heading)
    |> html_body(render_html(heading, lines, urls))
    |> text_body(render_text(heading, lines, urls))
    |> put_headers(notification, urls)
  end

  defp put_headers(email, notification, urls) do
    email
    |> header("Message-ID", "<notification-#{notification.id}@stridelikeaboss.com>")
    |> header("List-Unsubscribe", "<" <> urls.one_click <> ">")
    |> header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
  end

  defp urls(notification, user) do
    base = KanbanWeb.Endpoint.url()
    token = UnsubscribeToken.sign(user.id, notification.event_type)

    %{
      link: base <> (notification.url_path || "/"),
      unsubscribe: base <> @unsubscribe_path <> URI.encode_www_form(token),
      one_click: base <> @one_click_path <> URI.encode_www_form(token),
      preferences: base <> @preferences_path
    }
  end

  defp heading(:review_requested), do: gettext("Review requested")
  defp heading(:task_assigned), do: gettext("Task assigned to you")
  defp heading(:claim_expired), do: gettext("Your claim expired")
  defp heading(:goal_completed), do: gettext("Goal completed")
  defp heading(:weekly_digest), do: gettext("Your weekly digest")
  defp heading(:comment_added), do: gettext("New comment")
  defp heading(:mentioned), do: gettext("You were mentioned")
  defp heading(:task_reviewed), do: gettext("Your task was reviewed")
  defp heading(:task_unclaimed), do: gettext("Task unclaimed")
  defp heading(:board_access_changed), do: gettext("Your board access changed")
  defp heading(:after_goal_failed), do: gettext("After-goal hook failed")
  defp heading(:target_status_changed), do: gettext("Target status changed")

  defp content_lines(notification) do
    Enum.reject(
      [
        notification.title,
        actor_line(notification.actor_name),
        board_line(notification.board),
        NotificationLabels.detail(notification),
        present(notification.body)
      ],
      &is_nil/1
    )
  end

  defp actor_line(name) when is_binary(name) and name != "",
    do: gettext("By %{actor}", actor: name)

  defp actor_line(_name), do: nil

  defp board_line(%{name: name}) when is_binary(name), do: gettext("Board: %{board}", board: name)
  defp board_line(_board), do: nil

  defp present(text) when is_binary(text) and text != "", do: text
  defp present(_text), do: nil

  defp render_html(heading, lines, urls) do
    paragraphs =
      Enum.map_join(
        lines,
        "\n",
        &~s(<p style="white-space:pre-line;margin:0 0 12px">#{escape(&1)}</p>)
      )

    """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><meta name="color-scheme" content="light dark"></head>
    <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;line-height:1.5;max-width:600px;margin:0 auto;padding:24px">
    <h1 style="font-size:20px;margin:0 0 16px">#{escape(heading)}</h1>
    #{paragraphs}
    <p style="margin:24px 0"><a href="#{escape(urls.link)}" style="#{@button_style}">#{escape(gettext("View in Stride"))}</a></p>
    #{footer_html(urls)}
    </body>
    </html>
    """
  end

  defp footer_html(urls) do
    """
    <hr style="#{@rule_style}">
    <p style="#{@footer_style}">#{escape(gettext("You are receiving this because email notifications for this event type are on."))}
    <a href="#{escape(urls.unsubscribe)}">#{escape(gettext("Unsubscribe from these emails"))}</a> ·
    <a href="#{escape(urls.preferences)}">#{escape(gettext("Manage notification preferences"))}</a></p>
    """
  end

  defp render_text(heading, lines, urls) do
    footer = [
      "#{gettext("View in Stride")}: #{urls.link}",
      "--",
      gettext("You are receiving this because email notifications for this event type are on."),
      "#{gettext("Unsubscribe from these emails")}: #{urls.unsubscribe}",
      "#{gettext("Manage notification preferences")}: #{urls.preferences}"
    ]

    Enum.join([heading | lines] ++ footer, "\n\n")
  end

  defp escape(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
