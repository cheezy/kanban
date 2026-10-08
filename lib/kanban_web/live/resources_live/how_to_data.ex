defmodule KanbanWeb.ResourcesLive.HowToData do
  @moduledoc """
  Embedded how-to guide data for the Resources section.
  All content is version-controlled and deployed with the app.

  The guides themselves are in the `KanbanWeb.ResourcesLive.HowTos.*`
  modules, one per area; this module assembles them into the catalog and
  answers lookups, tags and navigation.
  """

  alias KanbanWeb.ResourcesLive.HowTos

  @type_icons %{
    "guide" => "hero-book-open",
    "tutorial" => "hero-academic-cap",
    "reference" => "hero-document-text",
    "video" => "hero-play-circle"
  }

  # The guide data lives in one module per area (HowTos.*); the order here is
  # the catalog order, which also drives previous/next navigation.
  @how_tos HowTos.GettingStarted.how_tos() ++
             HowTos.Account.how_tos() ++
             HowTos.Developer.how_tos() ++
             HowTos.WorkingWithTasks.how_tos() ++
             HowTos.Metrics.how_tos()

  @all_tags [
    "getting-started",
    "beginner",
    "developer",
    "non-developer",
    "best-practices",
    "boards",
    "tasks",
    "workflow",
    "collaboration",
    "hooks",
    "api",
    "automation",
    "security",
    "troubleshooting",
    "ai-agents",
    "monitoring",
    "reviewing",
    "dependencies",
    "priority",
    "metrics"
  ]

  @doc """
  Returns all how-to guides.
  """
  def all_how_tos, do: @how_tos

  @doc """
  Returns all available tags.
  """
  def all_tags, do: @all_tags

  @doc """
  Returns the type icon mapping.
  """
  def type_icons, do: @type_icons

  @doc """
  Finds a how-to by its ID.
  Returns `{:ok, how_to}` or `:error`.
  """
  def get_how_to(id) do
    case Enum.find(@how_tos, &(&1.id == id)) do
      nil -> :error
      how_to -> {:ok, how_to}
    end
  end

  @doc """
  Returns the type icon for a content type.
  """
  def type_icon(content_type) do
    Map.get(@type_icons, content_type, "hero-document")
  end

  @doc """
  Formats a tag for display (kebab-case to Title Case).
  """
  def format_tag(tag) do
    tag
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  Returns previous and next how-tos within the same tags.
  """
  def get_navigation(current_how_to) do
    # Get how-tos that share at least one tag
    primary_tag = List.first(current_how_to.tags)

    related =
      @how_tos
      |> Enum.filter(&(primary_tag in &1.tags))
      |> Enum.with_index()

    current_index =
      Enum.find_index(related, fn {how_to, _} -> how_to.id == current_how_to.id end)

    {neighbor_at(related, current_index, -1), neighbor_at(related, current_index, +1)}
  end

  defp neighbor_at(_related, nil, _offset), do: nil

  defp neighbor_at(related, current_index, offset) do
    target_index = current_index + offset

    if target_index >= 0 and target_index < length(related) do
      {how_to, _} = Enum.at(related, target_index)
      how_to
    end
  end
end
