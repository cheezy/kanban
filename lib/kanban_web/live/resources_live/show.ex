defmodule KanbanWeb.ResourcesLive.Show do
  @moduledoc """
  LiveView for displaying a single how-to guide.
  Shows step-by-step content with images and navigation.
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
        {prev_how_to, next_how_to} = HowToData.get_navigation(how_to)

        {:ok,
         socket
         |> assign(:page_title, how_to.title)
         |> assign(:how_to, how_to)
         |> assign(:prev_how_to, prev_how_to)
         |> assign(:next_how_to, next_how_to)}

      :error ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Not Found"))
         |> assign(:how_to, nil)
         |> assign(:prev_how_to, nil)
         |> assign(:next_how_to, nil)}
    end
  end

  # Delegate helper functions to shared module
  defdelegate type_icon(content_type), to: HowToData
  defdelegate format_tag(tag), to: HowToData

  @doc """
  Renders markdown content to HTML.
  Supports basic formatting: **bold**, `code`, links, and newlines.
  """
  def render_markdown(content) when is_binary(content) do
    content
    |> escape_html()
    |> convert_bold()
    |> convert_inline_code()
    |> convert_links()
    |> convert_code_blocks()
    |> convert_lists()
    |> convert_paragraphs()
  end

  def render_markdown(nil), do: ""

  defp escape_html(content) do
    content
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp convert_bold(content) do
    String.replace(content, ~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
  end

  defp convert_inline_code(content) do
    String.replace(
      content,
      ~r/`([^`]+)`/,
      "<code class=\"px-1.5 py-0.5 rounded bg-base-200 text-sm font-mono\">\\1</code>"
    )
  end

  defp convert_links(content) do
    Regex.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, content, fn _, text, url ->
      if safe_url?(url) do
        "<a href=\"#{url}\" class=\"text-blue-600 dark:text-blue-400 hover:underline\" target=\"_blank\" rel=\"noopener noreferrer\">#{text}</a>"
      else
        text
      end
    end)
  end

  defp safe_url?(url) do
    normalized = url |> String.trim() |> String.downcase()
    not String.starts_with?(normalized, ["javascript:", "data:", "vbscript:"])
  end

  defp convert_code_blocks(content) do
    Regex.replace(~r/```\w*\n([\s\S]*?)```/, content, fn _, code ->
      code = String.trim(code)

      "<pre class=\"p-4 rounded-lg bg-base-200 overflow-x-auto\"><code class=\"text-sm font-mono\">#{code}</code></pre>"
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
      String.starts_with?(para, "<pre") -> para
      String.starts_with?(para, "<ul") -> para
      para == "" -> ""
      true -> "<p>#{String.replace(para, "\n", "<br/>")}</p>"
    end
  end

  defp convert_lists(content) do
    if has_list_items?(content) do
      content
      |> String.split("\n")
      |> process_list_lines()
      |> Enum.reverse()
      |> Enum.join("\n")
    else
      content
    end
  end

  defp has_list_items?(content) do
    String.contains?(content, "\n- ") or String.starts_with?(content, "- ")
  end

  defp process_list_lines(lines) do
    {result, in_list} =
      Enum.reduce(lines, {[], false}, &process_line/2)

    if in_list, do: ["</ul>" | result], else: result
  end

  defp process_line(line, {acc, in_list}) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "- ") ->
        handle_list_item(trimmed, acc, in_list)

      in_list and trimmed == "" ->
        {["</ul>" | acc], false}

      in_list ->
        {["</ul>", line | acc], false}

      true ->
        {[line | acc], in_list}
    end
  end

  defp handle_list_item(trimmed, acc, in_list) do
    item = String.trim_leading(trimmed, "- ")
    li = "<li>#{item}</li>"

    if in_list do
      {[li | acc], true}
    else
      {[li, "<ul class=\"list-disc list-inside space-y-1 my-2\">" | acc], true}
    end
  end
end
