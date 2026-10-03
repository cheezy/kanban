defmodule KanbanWeb.Emails.DigestEmail do
  @moduledoc """
  Builds the weekly digest email from a `Kanban.Notifications.Digest`.

  The subject is a fixed translated heading. Board names, task titles and
  identifiers are user-controlled, so every value interpolated into the HTML
  body — text and hrefs alike — is HTML-escaped; the text body carries the
  same content unescaped. Each board links to its page and the reviews
  section links to the review queue.

  Like every notification email it carries a signed one-click unsubscribe
  link (for `:weekly_digest`) in the footer and the `List-Unsubscribe`
  headers. The `Message-ID` is stable per user and ISO week, so a resend
  collapses into the first copy in mail clients.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Swoosh.Email
  import KanbanWeb.Emails.EmailHelpers, only: [escape: 1]

  alias Kanban.Accounts.User
  alias Kanban.Notifications.Digest
  alias KanbanWeb.Emails.EmailHelpers

  # dark-mode-ignore: email HTML cannot use the app's CSS variables
  @cell_style "padding:6px 8px;border-bottom:1px solid #d4d4d8;text-align:left"
  # Mail clients pick their own light or dark background, and no fixed grey
  # reaches 4.5:1 on both, so muted text dims the client's text colour.
  @muted_style "opacity:0.75;font-size:13px"
  # dark-mode-ignore: email HTML cannot use the app's CSS variables
  @num_style "padding:6px 8px;border-bottom:1px solid #d4d4d8;text-align:right"
  @section_style "font-size:16px;margin:24px 0 8px"

  @doc """
  Builds the digest email for `user` covering ISO `week` (`"YYYY-Www"`).
  """
  @spec build(User.t(), Digest.t(), String.t()) :: Swoosh.Email.t()
  def build(%User{} = user, digest, week) when is_binary(week) do
    urls = urls(user)
    heading = gettext("Your weekly digest")

    new()
    |> to(user.email)
    |> from(EmailHelpers.from())
    |> subject("[Stride] " <> heading)
    |> html_body(render_html(heading, digest, urls))
    |> text_body(render_text(heading, digest, urls))
    |> header("Message-ID", "<weekly-digest-#{user.id}-#{week}@stridelikeaboss.com>")
    |> EmailHelpers.put_unsubscribe_headers(urls)
  end

  defp urls(user) do
    base = KanbanWeb.Endpoint.url()

    user.id
    |> EmailHelpers.unsubscribe_urls(:weekly_digest)
    |> Map.merge(%{base: base, review: base <> "/review"})
  end

  defp board_url(urls, board_id), do: "#{urls.base}/boards/#{board_id}"

  defp period(digest) do
    gettext("Summary for %{start} – %{end} (UTC)",
      start: Date.to_iso8601(digest.window_start),
      end: Date.to_iso8601(digest.window_end)
    )
  end

  defp summary_lines(digest) do
    [
      "#{gettext("Tasks done")}: #{digest.tasks_done}",
      "#{gettext("Goals completed")}: #{digest.goals_completed}",
      "#{gettext("Waiting for review")}: #{digest.reviews.count}"
    ]
  end

  defp more_boards_line(%{more_boards: 0}), do: nil
  defp more_boards_line(%{more_boards: n}), do: gettext("Other boards: %{count}", count: n)

  defp review_line(row) do
    gettext("%{identifier} on %{board}, waiting %{age}",
      identifier: row.identifier || "",
      board: row.board_name,
      age: format_age(row.age_hours)
    )
  end

  defp format_age(hours) when hours >= 48, do: gettext("%{count} d", count: div(hours, 24))
  defp format_age(hours), do: gettext("%{count} h", count: hours)

  # -- HTML ------------------------------------------------------------------

  defp render_html(heading, digest, urls) do
    """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><meta name="color-scheme" content="light dark"></head>
    <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;line-height:1.5;max-width:600px;margin:0 auto;padding:24px">
    <h1 style="font-size:20px;margin:0 0 4px">#{escape(heading)}</h1>
    <p style="#{@muted_style};margin:0 0 16px">#{escape(period(digest))}</p>
    #{summary_html(digest)}
    #{boards_html(digest, urls)}
    #{reviews_html(digest, urls)}
    #{EmailHelpers.footer_html(urls)}
    </body>
    </html>
    """
  end

  defp summary_html(digest) do
    items = digest |> summary_lines() |> Enum.map_join("\n", &"<li>#{escape(&1)}</li>")
    ~s(<ul style="margin:0 0 8px;padding-left:20px">\n#{items}\n</ul>)
  end

  defp boards_html(digest, urls) do
    rows = Enum.map_join(digest.boards, "\n", &board_row_html(&1, urls))

    """
    <h2 style="#{@section_style}">#{escape(gettext("Your boards"))}</h2>
    <table style="border-collapse:collapse;width:100%;font-size:14px">
    <tr>#{header_cells_html()}</tr>
    #{rows}
    </table>
    #{more_boards_html(digest)}
    """
  end

  defp header_cells_html do
    [
      {gettext("Board"), @cell_style},
      {gettext("To Do"), @num_style},
      {gettext("Doing"), @num_style},
      {gettext("Review"), @num_style},
      {gettext("Done"), @num_style}
    ]
    |> Enum.map_join(fn {label, style} -> ~s(<th style="#{style}">#{escape(label)}</th>) end)
  end

  defp board_row_html(row, urls) do
    counts =
      [row.open, row.doing, row.review, row.done_this_week]
      |> Enum.map_join(&~s(<td style="#{@num_style}">#{&1}</td>))

    ~s(<tr><td style="#{@cell_style}"><a href="#{escape(board_url(urls, row.id))}">) <>
      ~s(#{escape(row.name)}</a></td>#{counts}</tr>)
  end

  defp more_boards_html(digest) do
    case more_boards_line(digest) do
      nil -> ""
      line -> ~s(<p style="#{@muted_style};margin:8px 0 0">#{escape(line)}</p>)
    end
  end

  defp reviews_html(%{reviews: %{count: 0}}, urls) do
    """
    <h2 style="#{@section_style}">#{escape(gettext("Review queue"))}</h2>
    <p style="margin:0">#{escape(gettext("Nothing is waiting for review."))}
    <a href="#{escape(urls.review)}">#{escape(gettext("Open the review queue"))}</a></p>
    """
  end

  defp reviews_html(%{reviews: reviews}, urls) do
    items = Enum.map_join(reviews.oldest, "\n", &review_row_html/1)

    """
    <h2 style="#{@section_style}">#{escape(gettext("Oldest pending reviews"))}</h2>
    <ul style="margin:0 0 16px;padding-left:20px">
    #{items}
    </ul>
    <p style="margin:24px 0"><a href="#{escape(urls.review)}" style="#{EmailHelpers.button_style()}">#{escape(gettext("Open the review queue"))}</a></p>
    """
  end

  defp review_row_html(row) do
    ~s(<li><strong>#{escape(row.title)}</strong><br>) <>
      ~s(<span style="#{@muted_style}">#{escape(review_line(row))}</span></li>)
  end

  # -- Text ------------------------------------------------------------------

  defp render_text(heading, digest, urls) do
    summary = digest |> summary_lines() |> Enum.join("\n")

    [heading, period(digest), summary, boards_text(digest, urls), reviews_text(digest, urls)]
    |> Kernel.++(EmailHelpers.footer_text_lines(urls))
    |> Enum.join("\n\n")
  end

  defp boards_text(digest, urls) do
    rows =
      Enum.map(digest.boards, fn row ->
        "- #{row.name}: #{gettext("To Do")} #{row.open}, #{gettext("Doing")} #{row.doing}, " <>
          "#{gettext("Review")} #{row.review}, #{gettext("Done")} " <>
          "#{row.done_this_week}\n  #{board_url(urls, row.id)}"
      end)

    more = digest |> more_boards_line() |> List.wrap()

    Enum.join([gettext("Your boards") | rows] ++ more, "\n")
  end

  defp reviews_text(%{reviews: %{count: 0}}, urls) do
    "#{gettext("Nothing is waiting for review.")}\n#{gettext("Open the review queue")}: #{urls.review}"
  end

  defp reviews_text(%{reviews: reviews}, urls) do
    rows = Enum.map(reviews.oldest, &"- #{&1.title}\n  #{review_line(&1)}")

    [gettext("Oldest pending reviews") | rows]
    |> Kernel.++(["#{gettext("Open the review queue")}: #{urls.review}"])
    |> Enum.join("\n")
  end
end
