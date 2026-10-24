defmodule KanbanWeb.ResourcesLive.Show do
  @moduledoc """
  LiveView for displaying a single how-to guide.
  Shows step-by-step content with images and navigation. Step text is a
  small, escape-first markdown subset rendered by `render_markdown/1`:
  bold, inline code, links, fenced code, bullet lists and numbered lists.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.ResourcesLive.Components

  alias KanbanWeb.ResourcesLive.HowToData

  @impl true
  def mount(%{"id" => id}, session, socket) do
    locale = session["locale"] || "en"
    Gettext.put_locale(KanbanWeb.Gettext, locale)

    case HowToData.get_how_to(id) do
      {:ok, how_to} ->
        {:ok, assign_how_to(socket, how_to)}

      :error ->
        {:ok, assign_how_to_not_found(socket)}
    end
  end

  defp assign_how_to(socket, how_to) do
    {prev_how_to, next_how_to} = HowToData.get_navigation(how_to)

    socket
    |> assign(:page_title, how_to.title)
    |> assign(:how_to, how_to)
    |> assign(:prev_how_to, prev_how_to)
    |> assign(:next_how_to, next_how_to)
  end

  defp assign_how_to_not_found(socket) do
    socket
    |> assign(:page_title, gettext("Not Found"))
    |> assign(:how_to, nil)
    |> assign(:prev_how_to, nil)
    |> assign(:next_how_to, nil)
  end

  # Delegate helper functions to shared module
  defdelegate type_icon(content_type), to: HowToData
  defdelegate format_tag(tag), to: HowToData

  @doc """
  Renders markdown content to HTML.

  Supported syntax: `**bold**`, backtick `code`, `[text](url)` links,
  fenced code blocks, `- ` bullet lists, `1. ` numbered lists and
  paragraphs separated by a blank line. A numbered item is a line that
  starts with digits and a dot, followed by a space or the end of the
  line, so a number inside a sentence stays plain text. Straight after
  a line of text only a `1. ` line starts a numbered list; the browser
  numbers items from 1 either way.
  Headings, italics and raw HTML are not supported: HTML in the source
  is shown as text.

  Pipeline: escape any HTML in the source first (so `<script>` in the
  markdown can never reach the page as an executable tag), then set
  fenced code blocks aside so nothing below rewrites their contents,
  then apply the inline transformations, lists and paragraphs, and
  finally put the code blocks back. The escape-first ordering and the
  URL-protocol allow-list in `convert_links/1` are load-bearing — see
  the contract tests in `show_test.exs` "render_markdown/1 XSS
  prevention" describe block which assert script-tag escape,
  event-handler escape, `javascript:`/`data:`/`vbscript:` blocking.

  A full swap to Earmark was attempted but reverted: Earmark passes
  inline HTML through by default, and the `:escape` option that would
  block it does not exist in Earmark's option set as of v1.4. A safe
  full-swap would require either HtmlSanitizeEx (a new dep) or a
  pre-escape pass — at which point the pipeline below is still
  doing most of the work. Earmark IS installed in the project for
  future use by other markdown-rendering call sites where a sanitizer
  dep is acceptable.
  """
  def render_markdown(content) when is_binary(content) do
    {content, code_blocks} =
      content
      |> escape_html()
      |> extract_code_blocks()

    content
    |> convert_bold()
    |> convert_inline_code()
    |> convert_links()
    |> convert_lists()
    |> convert_paragraphs()
    |> restore_code_blocks(code_blocks)
  end

  def render_markdown(nil), do: ""

  # Marks where a fenced code block sat while the rest of the pipeline runs.
  # U+E000 is a private-use character, so escaped guide text never contains it.
  @code_block_marker "\uE000"

  defp escape_html(content) do
    content
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp convert_bold(content) do
    String.replace(content, ~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
  end

  # break-words lets a long file name or token wrap on a phone instead of
  # pushing the page sideways.
  defp convert_inline_code(content) do
    String.replace(
      content,
      ~r/`([^`]+)`/,
      "<code class=\"px-1.5 py-0.5 rounded bg-base-200 text-sm font-mono break-words\">\\1</code>"
    )
  end

  defp convert_links(content) do
    Regex.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, content, fn _, text, url ->
      if safe_url?(url) do
        "<a href=\"#{url}\" class=\"text-[var(--ink)] hover:text-[var(--stride-orange)] hover:underline\" target=\"_blank\" rel=\"noopener noreferrer\">#{text}</a>"
      else
        text
      end
    end)
  end

  # XSS guard called from convert_links/1; analyzer regex misses predicate `?` callers.
  defp safe_url?(url) do
    normalized = url |> String.trim() |> String.downcase()
    not String.starts_with?(normalized, ["javascript:", "data:", "vbscript:"])
  end

  # Swaps each fenced code block for a numbered marker on its own paragraph,
  # so bold, inline code, links and lists never rewrite code, and returns the
  # rendered blocks in order for restore_code_blocks/2.
  defp extract_code_blocks(content) do
    {parts, blocks} =
      code_block_pattern()
      |> Regex.split(content, include_captures: true)
      |> Enum.reduce({[], []}, &extract_code_block/2)

    {parts |> Enum.reverse() |> Enum.join(), Enum.reverse(blocks)}
  end

  defp extract_code_block(part, {parts, blocks}) do
    case Regex.run(code_block_pattern(), part) do
      [^part, code] ->
        marker = "\n\n#{@code_block_marker}#{length(blocks)}#{@code_block_marker}\n\n"
        {[marker | parts], [render_code_block(code) | blocks]}

      _ ->
        {[part | parts], blocks}
    end
  end

  # A function, not a module attribute: OTP 28 can't store a compiled regex in one.
  defp code_block_pattern, do: ~r/```\w*\n([\s\S]*?)```/

  defp render_code_block(code) do
    "<pre class=\"p-4 rounded-lg bg-base-200 overflow-x-auto\"><code class=\"text-sm font-mono\">#{String.trim(code)}</code></pre>"
  end

  defp restore_code_blocks(content, blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.reduce(content, fn {block, index}, acc ->
      String.replace(acc, "#{@code_block_marker}#{index}#{@code_block_marker}", block)
    end)
  end

  defp convert_paragraphs(content) do
    content
    |> String.split(~r/\n\n+/)
    |> Enum.map_join("\n", &wrap_paragraph/1)
  end

  defp wrap_paragraph(para) do
    para = String.trim(para)

    cond do
      String.starts_with?(para, ["<ul", "<ol", @code_block_marker]) -> para
      para == "" -> ""
      true -> "<p>#{String.replace(para, "\n", "<br/>")}</p>"
    end
  end

  # Groups consecutive list lines into one <ul> or <ol>. A list always sits in
  # its own paragraph: a blank line is kept on each side of it, so the text
  # before and after it is wrapped in <p> and the list is not.
  defp convert_lists(content) do
    {acc, open} =
      content
      |> String.split("\n")
      |> Enum.reduce({[], nil}, &process_line/2)

    acc
    |> close_list(open)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp process_line(line, {acc, open}) do
    line
    |> classify_line()
    |> demote_interrupting_item(acc, open)
    |> apply_line(line, acc, open)
  end

  defp apply_line({open, item, _number}, _line, acc, open), do: {[list_item(item) | acc], open}

  defp apply_line({kind, item, _number}, _line, acc, open) do
    acc = acc |> close_list(open) |> ensure_blank()
    {[list_item(item), list_open_tag(kind) | acc], kind}
  end

  defp apply_line(:blank, _line, acc, open) when open != nil,
    do: {["" | close_list(acc, open)], nil}

  defp apply_line(:text, line, acc, open) when open != nil,
    do: {[line, "" | close_list(acc, open)], nil}

  defp apply_line(_classified, line, acc, _open), do: {[line | acc], nil}

  defp list_item(item), do: "<li>#{item}</li>"

  defp classify_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> :blank
      String.starts_with?(trimmed, "- ") -> {:ul, String.trim_leading(trimmed, "- "), nil}
      match = Regex.run(~r/^(\d+)\.(?: (.*)|$)/, trimmed) -> ordered_item(match)
      true -> :text
    end
  end

  # Like CommonMark, only a "1. " line can start a list straight after text,
  # so "2026. was a year" on a wrapped line stays in the paragraph.
  defp demote_interrupting_item({:ol, _item, number}, [previous | _], nil)
       when number != 1 and previous != "",
       do: :text

  defp demote_interrupting_item(classified, _acc, _open), do: classified

  defp ordered_item([_, number, item]), do: {:ol, item, String.to_integer(number)}
  defp ordered_item([_, number]), do: {:ol, "", String.to_integer(number)}

  defp list_open_tag(:ul), do: "<ul class=\"list-disc list-inside space-y-1 my-2\">"
  defp list_open_tag(:ol), do: "<ol class=\"list-decimal list-inside space-y-1 my-2\">"

  defp close_list(acc, nil), do: acc
  defp close_list(acc, :ul), do: ["</ul>" | acc]
  defp close_list(acc, :ol), do: ["</ol>" | acc]

  # Adds a blank line before a list unless one is already there.
  defp ensure_blank([]), do: []
  defp ensure_blank(["" | _] = acc), do: acc
  defp ensure_blank(acc), do: ["" | acc]
end
