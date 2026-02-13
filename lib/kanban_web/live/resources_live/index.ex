defmodule KanbanWeb.ResourcesLive.Index do
  @moduledoc """
  LiveView for the Resources landing page.
  Displays a searchable, filterable grid of how-to guides.
  Uses embedded Elixir data structures for content (no database).
  """
  use KanbanWeb, :live_view

  import KanbanWeb.ResourcesLive.Components

  alias KanbanWeb.ResourcesLive.HowToData

  @impl true
  def mount(_params, session, socket) do
    locale = session["locale"] || "en"
    Gettext.put_locale(KanbanWeb.Gettext, locale)

    {:ok, assign(socket, :page_title, gettext("Resources & How-Tos"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    how_tos = HowToData.all_how_tos()
    search_query = params["search"] || ""
    selected_tags = parse_tags(params["tags"])
    sort_by = params["sort_by"] || "relevance"

    filtered =
      filter_how_tos(how_tos, search_query, selected_tags)
      |> sort_how_tos(sort_by)

    {:noreply,
     socket
     |> assign(:all_how_tos, how_tos)
     |> assign(:all_tags, HowToData.all_tags())
     |> assign(:search_query, search_query)
     |> assign(:selected_tags, selected_tags)
     |> assign(:sort_by, sort_by)
     |> assign(:filtered_how_tos, filtered)}
  end

  @impl true
  def handle_event("search", %{"value" => query}, socket) do
    {:noreply, push_filter_params(socket, search: query)}
  end

  @impl true
  def handle_event("toggle_tag", %{"tag" => tag}, socket) do
    selected_tags =
      if tag in socket.assigns.selected_tags do
        List.delete(socket.assigns.selected_tags, tag)
      else
        [tag | socket.assigns.selected_tags]
      end

    {:noreply, push_filter_params(socket, tags: selected_tags)}
  end

  @impl true
  def handle_event("sort", %{"sort_by" => sort_by}, socket) do
    {:noreply, push_filter_params(socket, sort_by: sort_by)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/resources")}
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

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []

  defp parse_tags(tags_string) do
    tags_string
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp push_filter_params(socket, overrides) do
    search = Keyword.get(overrides, :search, socket.assigns.search_query)
    tags = Keyword.get(overrides, :tags, socket.assigns.selected_tags)
    sort_by = Keyword.get(overrides, :sort_by, socket.assigns.sort_by)

    query_params =
      %{}
      |> then(fn params -> if search != "", do: Map.put(params, "search", search), else: params end)
      |> then(fn params ->
        if tags != [], do: Map.put(params, "tags", Enum.join(tags, ",")), else: params
      end)
      |> then(fn params ->
        if sort_by != "relevance", do: Map.put(params, "sort_by", sort_by), else: params
      end)

    path =
      case URI.encode_query(query_params) do
        "" -> ~p"/resources"
        query -> ~p"/resources" <> "?" <> query
      end

    push_patch(socket, to: path)
  end

  # Delegate to shared module for consistency
  defdelegate type_icon(content_type), to: HowToData
  defdelegate format_tag(tag), to: HowToData
end
