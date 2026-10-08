defmodule KanbanWeb.Emails.NotificationEmail do
  @moduledoc """
  Builds the email for one `Kanban.Notifications.Notification`.

  The subject comes only from a translated heading for the event type, so
  free text carried by a notification (titles, review notes, unclaim
  reasons) never reaches it. Every value interpolated into the HTML body —
  text and hrefs alike — is HTML-escaped; the text body carries the same
  content unescaped.

  Every email carries a signed one-click unsubscribe link in the footer and
  in the `List-Unsubscribe` / `List-Unsubscribe-Post` headers (RFC 8058),
  built by `KanbanWeb.Emails.EmailHelpers`.

  Emails render in the calling process's Gettext locale; Oban jobs run with
  the default locale.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Swoosh.Email
  import KanbanWeb.Emails.EmailHelpers, only: [escape: 1]

  alias Kanban.Accounts.User
  alias Kanban.Notifications.Notification
  alias KanbanWeb.Emails.EmailHelpers
  alias KanbanWeb.NotificationLabels

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
    |> from(EmailHelpers.from())
    |> subject("[Stride] " <> heading)
    |> html_body(render_html(heading, lines, urls))
    |> text_body(render_text(heading, lines, urls))
    |> put_headers(notification, urls)
  end

  defp put_headers(email, notification, urls) do
    email
    |> header("Message-ID", "<notification-#{notification.id}@stridelikeaboss.com>")
    |> EmailHelpers.put_unsubscribe_headers(urls)
  end

  defp urls(notification, user) do
    link = KanbanWeb.Endpoint.url() <> (notification.url_path || "/")

    user.id
    |> EmailHelpers.unsubscribe_urls(notification.event_type)
    |> Map.put(:link, link)
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
        board_line(notification.board, notification.title),
        NotificationLabels.detail(notification),
        present(notification.body)
      ],
      &is_nil/1
    )
  end

  defp actor_line(name) when is_binary(name) and name != "",
    do: gettext("By %{actor}", actor: name)

  defp actor_line(_name), do: nil

  # A board access notice is titled with the board name already.
  defp board_line(%{name: title}, title), do: nil

  defp board_line(%{name: name}, _title) when is_binary(name),
    do: gettext("Board: %{board}", board: name)

  defp board_line(_board, _title), do: nil

  defp present(text) when is_binary(text) and text != "", do: text
  defp present(_text), do: nil

  defp render_html(heading, lines, urls) do
    paragraphs =
      Enum.map_join(
        lines,
        "\n",
        &~s(<p style="white-space:pre-line;overflow-wrap:anywhere;word-break:break-word;margin:0 0 12px">#{escape(&1)}</p>)
      )

    """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><meta name="color-scheme" content="light dark"></head>
    <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;line-height:1.5;max-width:600px;margin:0 auto;padding:24px">
    <h1 style="font-size:20px;margin:0 0 16px">#{escape(heading)}</h1>
    #{paragraphs}
    <p style="margin:24px 0"><a href="#{escape(urls.link)}" style="#{EmailHelpers.button_style()}">#{escape(gettext("View in Stride"))}</a></p>
    #{EmailHelpers.footer_html(urls)}
    </body>
    </html>
    """
  end

  defp render_text(heading, lines, urls) do
    footer = ["#{gettext("View in Stride")}: #{urls.link}" | EmailHelpers.footer_text_lines(urls)]

    Enum.join([heading | lines] ++ footer, "\n\n")
  end
end
