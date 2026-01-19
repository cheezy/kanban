defmodule KanbanWeb.ResourcesLive.Index do
  @moduledoc """
  LiveView for the Resources landing page.
  Displays a searchable, filterable grid of how-to guides.
  Uses embedded Elixir data structures for content (no database).
  """
  use KanbanWeb, :live_view

  @type_icons %{
    "guide" => "hero-book-open",
    "tutorial" => "hero-academic-cap",
    "reference" => "hero-document-text",
    "video" => "hero-play-circle"
  }

  @how_tos [
    %{
      id: "creating-your-first-board",
      title: "Creating Your First Board",
      description:
        "Learn how to create and configure a new Stride board for your team or project.",
      tags: ["getting-started", "beginner", "boards"],
      content_type: "guide",
      reading_time: 3,
      thumbnail: "/images/resources/board-creation.png",
      created_at: ~D[2026-01-15]
    },
    %{
      id: "understanding-columns",
      title: "Understanding Board Columns and Workflow",
      description:
        "Discover how columns help organize your tasks and create efficient workflows.",
      tags: ["getting-started", "beginner", "workflow"],
      content_type: "guide",
      reading_time: 4,
      thumbnail: "/images/resources/columns-workflow.png",
      created_at: ~D[2026-01-15]
    },
    %{
      id: "adding-your-first-task",
      title: "Adding Your First Task",
      description: "A step-by-step guide to creating tasks with all the essential fields.",
      tags: ["getting-started", "beginner", "tasks"],
      content_type: "guide",
      reading_time: 3,
      thumbnail: "/images/resources/task-creation.png",
      created_at: ~D[2026-01-15]
    },
    %{
      id: "inviting-team-members",
      title: "Inviting Team Members",
      description: "Learn how to invite collaborators and manage board access permissions.",
      tags: ["getting-started", "beginner", "collaboration"],
      content_type: "guide",
      reading_time: 2,
      thumbnail: "/images/resources/invite-members.png",
      created_at: ~D[2026-01-15]
    },
    %{
      id: "setting-up-hooks",
      title: "Setting Up Hook Execution",
      description:
        "Configure client-side hooks for automated workflows when claiming and completing tasks.",
      tags: ["developer", "hooks", "automation"],
      content_type: "tutorial",
      reading_time: 8,
      thumbnail: "/images/resources/hooks-setup.png",
      created_at: ~D[2026-01-16]
    },
    %{
      id: "api-authentication",
      title: "Configuring API Authentication",
      description:
        "Set up API tokens for secure access to the Stride API from your applications.",
      tags: ["developer", "api", "security"],
      content_type: "tutorial",
      reading_time: 5,
      thumbnail: "/images/resources/api-auth.png",
      created_at: ~D[2026-01-16]
    },
    %{
      id: "claim-complete-workflow",
      title: "Understanding Claim/Complete Workflow",
      description:
        "Master the task lifecycle with claiming, completing, and review workflows for AI agents.",
      tags: ["developer", "workflow", "api"],
      content_type: "guide",
      reading_time: 10,
      thumbnail: "/images/resources/claim-complete.png",
      created_at: ~D[2026-01-16]
    },
    %{
      id: "debugging-hooks",
      title: "Debugging Hook Failures",
      description:
        "Troubleshoot common hook execution issues and learn best practices for reliable automation.",
      tags: ["developer", "hooks", "troubleshooting"],
      content_type: "guide",
      reading_time: 6,
      thumbnail: "/images/resources/debug-hooks.png",
      created_at: ~D[2026-01-16]
    }
  ]

  @all_tags [
    "getting-started",
    "beginner",
    "developer",
    "boards",
    "tasks",
    "workflow",
    "collaboration",
    "hooks",
    "api",
    "automation",
    "security",
    "troubleshooting"
  ]

  @impl true
  def mount(_params, session, socket) do
    locale = session["locale"] || "en"
    Gettext.put_locale(KanbanWeb.Gettext, locale)

    {:ok,
     socket
     |> assign(:page_title, gettext("Resources & How-Tos"))
     |> assign(:all_how_tos, @how_tos)
     |> assign(:filtered_how_tos, @how_tos)
     |> assign(:all_tags, @all_tags)
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
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:selected_tags, [])
     |> assign(:sort_by, "relevance")
     |> assign(:filtered_how_tos, @how_tos)}
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

  def type_icon(content_type) do
    Map.get(@type_icons, content_type, "hero-document")
  end

  def format_tag(tag) do
    tag
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
