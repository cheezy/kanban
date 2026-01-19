defmodule KanbanWeb.ResourcesLive.Index do
  @moduledoc """
  LiveView for the Resources landing page.
  Displays a searchable, filterable grid of how-to guides.
  Uses embedded Elixir data structures for content (no database).
  """
  use KanbanWeb, :live_view

  alias KanbanWeb.ResourcesLive.HowToData

  @impl true
  def mount(_params, session, socket) do
    locale = session["locale"] || "en"
    Gettext.put_locale(KanbanWeb.Gettext, locale)

    how_tos = HowToData.all_how_tos()

    {:ok,
     socket
     |> assign(:page_title, gettext("Resources & How-Tos"))
     |> assign(:all_how_tos, how_tos)
     |> assign(:filtered_how_tos, how_tos)
     |> assign(:all_tags, HowToData.all_tags())
     |> assign(:search_query, "")
     |> assign(:selected_tags, [])
     |> assign(:sort_by, "relevance")}
  end

  @impl true
  def handle_event("search", %{"value" => query}, socket) do
    filtered =
      filter_how_tos(socket.assigns.all_how_tos, query, socket.assigns.selected_tags)
      |> sort_how_tos(socket.assigns.sort_by)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:filtered_how_tos, filtered)}
  end

  @impl true
  def handle_event("toggle_tag", %{"tag" => tag}, socket) do
    selected_tags =
      if tag in socket.assigns.selected_tags do
        List.delete(socket.assigns.selected_tags, tag)
      else
        [tag | socket.assigns.selected_tags]
      end

    filtered =
      filter_how_tos(socket.assigns.all_how_tos, socket.assigns.search_query, selected_tags)
      |> sort_how_tos(socket.assigns.sort_by)

    {:noreply,
     socket
     |> assign(:selected_tags, selected_tags)
     |> assign(:filtered_how_tos, filtered)}
  end

  @impl true
  def handle_event("sort", %{"sort_by" => sort_by}, socket) do
    filtered = sort_how_tos(socket.assigns.filtered_how_tos, sort_by)

    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> assign(:filtered_how_tos, filtered)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    how_tos = HowToData.all_how_tos()

    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:selected_tags, [])
     |> assign(:sort_by, "relevance")
     |> assign(:filtered_how_tos, how_tos)}
  end

  @doc """
  Filters how-tos by search query and selected tags.
  """
  def filter_how_tos(how_tos, query, selected_tags) do
    how_tos
    |> filter_by_search(query)
    |> filter_by_tags(selected_tags)
  end

  defp filter_by_search(how_tos, ""), do: how_tos
  defp filter_by_search(how_tos, nil), do: how_tos

  defp filter_by_search(how_tos, query) do
    query = String.downcase(query)

    Enum.filter(how_tos, fn how_to ->
      String.contains?(String.downcase(how_to.title), query) ||
        String.contains?(String.downcase(how_to.description), query) ||
        Enum.any?(how_to.tags, &String.contains?(String.downcase(&1), query))
    end)
  end

  defp filter_by_tags(how_tos, []), do: how_tos

  defp filter_by_tags(how_tos, selected_tags) do
    Enum.filter(how_tos, fn how_to ->
      Enum.any?(selected_tags, &(&1 in how_to.tags))
    end)
  end

  defp sort_how_tos(how_tos, "relevance"), do: how_tos
  defp sort_how_tos(how_tos, "newest"), do: Enum.sort_by(how_tos, & &1.created_at, {:desc, Date})
  defp sort_how_tos(how_tos, "a-z"), do: Enum.sort_by(how_tos, & &1.title)

  # Delegate to shared module for consistency
  defdelegate type_icon(content_type), to: HowToData
  defdelegate format_tag(tag), to: HowToData
end
