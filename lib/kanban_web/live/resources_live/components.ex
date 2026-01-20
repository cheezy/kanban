defmodule KanbanWeb.ResourcesLive.Components do
  @moduledoc """
  Reusable UI components for the Resources section.

  Provides function components for resource cards, search bar, tag filters,
  and how-to content rendering. All components follow DaisyUI patterns and
  support dark mode.
  """
  use Phoenix.Component
  use Gettext, backend: KanbanWeb.Gettext
  use Phoenix.VerifiedRoutes, endpoint: KanbanWeb.Endpoint, router: KanbanWeb.Router

  import KanbanWeb.CoreComponents, only: [icon: 1]

  alias KanbanWeb.ResourcesLive.HowToData

  @doc """
  Renders a resource card for the grid view.

  ## Attributes

    * `:how_to` - The how-to map with id, title, description, tags, content_type, reading_time
    * `:format_tag_fn` - Function to format tag display (optional, defaults to HowToData.format_tag/1)

  ## Examples

      <.resource_card how_to={@how_to} />
  """
  attr :how_to, :map, required: true
  attr :format_tag_fn, :any, default: &HowToData.format_tag/1

  def resource_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/resources/#{@how_to.id}"}
      class="group bg-base-100 rounded-xl shadow-lg hover:shadow-2xl transition-all duration-300 border border-base-300/50 hover:border-blue-300/50 overflow-hidden flex flex-col transform hover:-translate-y-1"
    >
      <!-- Thumbnail -->
      <div class="aspect-video relative overflow-hidden">
        <.category_illustration tags={@how_to.tags} />
        <!-- Content Type Badge -->
        <div class="absolute top-3 right-3">
          <.content_type_badge type={@how_to.content_type} />
        </div>
      </div>
      <!-- Content -->
      <div class="p-5 flex-1 flex flex-col">
        <h3 class="text-lg font-semibold text-base-content mb-2 group-hover:text-blue-600 transition-colors line-clamp-2">
          {@how_to.title}
        </h3>
        <p class="text-sm text-base-content/70 mb-4 flex-1 line-clamp-2">
          {@how_to.description}
        </p>
        <!-- Tags -->
        <div class="flex flex-wrap gap-1.5 mb-4">
          <span
            :for={tag <- Enum.take(@how_to.tags, 3)}
            class="px-2 py-0.5 rounded-full text-xs bg-base-200 text-base-content/70"
          >
            {@format_tag_fn.(tag)}
          </span>
        </div>
        <!-- Footer -->
        <div class="flex items-center justify-between pt-3 border-t border-base-300/60">
          <.reading_time minutes={@how_to.reading_time} />
          <span class="text-blue-600 group-hover:text-blue-700 text-sm font-medium flex items-center gap-1">
            {gettext("Read more")}
            <span class="group-hover:translate-x-1 transition-transform">&rarr;</span>
          </span>
        </div>
      </div>
    </.link>
    """
  end

  @doc """
  Renders a search bar with live update and debounce.

  ## Attributes

    * `:value` - Current search query value
    * `:placeholder` - Placeholder text (optional)
    * `:event` - The phx-keyup event name (default: "search")
    * `:debounce` - Debounce time in ms (default: 300)

  ## Examples

      <.search_bar value={@search_query} />
      <.search_bar value={@search_query} placeholder="Find guides..." event="filter" />
  """
  attr :value, :string, default: ""
  attr :placeholder, :string, default: nil
  attr :event, :string, default: "search"
  attr :debounce, :integer, default: 300

  def search_bar(assigns) do
    assigns =
      assign_new(assigns, :placeholder, fn -> gettext("Search for help...") end)

    ~H"""
    <div class="relative max-w-xl mx-auto">
      <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
        <.icon name="hero-magnifying-glass" class="h-5 w-5 text-base-content/40" />
      </div>
      <input
        type="text"
        name="query"
        value={@value}
        placeholder={@placeholder}
        phx-keyup={@event}
        phx-debounce={@debounce}
        class="block w-full pl-10 pr-3 py-3 border border-base-300 rounded-xl bg-base-100 text-base-content placeholder-base-content/40 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent transition-all"
      />
    </div>
    """
  end

  @doc """
  Renders tag filter pills with active state.

  ## Attributes

    * `:tags` - List of all available tags
    * `:selected` - List of currently selected tags
    * `:event` - The phx-click event name (default: "toggle_tag")
    * `:format_tag_fn` - Function to format tag display (optional)

  ## Examples

      <.tag_filter tags={@all_tags} selected={@selected_tags} />
  """
  attr :tags, :list, required: true
  attr :selected, :list, default: []
  attr :event, :string, default: "toggle_tag"
  attr :format_tag_fn, :any, default: &HowToData.format_tag/1

  def tag_filter(assigns) do
    ~H"""
    <div class="flex flex-wrap justify-center gap-2">
      <button
        :for={tag <- @tags}
        phx-click={@event}
        phx-value-tag={tag}
        class={[
          "px-3 py-1.5 rounded-full text-sm font-medium transition-all",
          if(tag in @selected,
            do: "bg-blue-600 text-white shadow-md",
            else: "bg-base-200 text-base-content/70 hover:bg-base-300"
          )
        ]}
      >
        {@format_tag_fn.(tag)}
      </button>
    </div>
    """
  end

  @doc """
  Renders the step-by-step content for a how-to guide.

  ## Attributes

    * `:steps` - List of step maps with title, content, and optional image
    * `:render_markdown_fn` - Function to render markdown content

  ## Examples

      <.how_to_content steps={@how_to.steps} render_markdown_fn={&render_markdown/1} />
  """
  attr :steps, :list, required: true
  attr :render_markdown_fn, :any, required: true

  def how_to_content(assigns) do
    ~H"""
    <div class="space-y-12">
      <%= for {step, index} <- Enum.with_index(@steps, 1) do %>
        <div class="relative">
          <!-- Step Number -->
          <div class="flex items-start gap-6">
            <div class="flex-shrink-0 w-10 h-10 rounded-full bg-blue-600 text-white flex items-center justify-center font-bold text-lg shadow-lg">
              {index}
            </div>
            <div class="flex-1 pt-1">
              <!-- Step Title -->
              <h2 class="text-xl font-semibold text-base-content mb-4">
                {step.title}
              </h2>
              <!-- Step Content -->
              <div class="prose prose-base dark:prose-invert max-w-prose text-base-content/80 leading-relaxed">
                {Phoenix.HTML.raw(@render_markdown_fn.(step.content))}
              </div>
              <!-- Step Image (if present) -->
              <%= if step[:image] do %>
                <div class="mt-6">
                  <img
                    src={step.image}
                    alt={"Step #{index}: #{step.title}"}
                    width={step[:image_width] || 1280}
                    height={step[:image_height] || 720}
                    class="rounded-xl shadow-lg border border-base-300/50 max-w-full h-auto"
                    loading="lazy"
                  />
                  <%= if String.ends_with?(step.image, ".svg") do %>
                    <p class="text-xs text-base-content/50 mt-2 italic text-center">
                      Placeholder image - Replace with actual screenshot ({step[:image_width] || 1280} × {step[:image_height] || 720}px)
                    </p>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
          <!-- Connector Line (except for last step) -->
          <%= if index < length(@steps) do %>
            <div class="absolute left-5 top-12 bottom-0 w-px bg-gradient-to-b from-blue-300 to-transparent dark:from-blue-600 -translate-x-1/2 h-[calc(100%-3rem)]">
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a content type badge with icon.

  ## Attributes

    * `:type` - The content type (guide, tutorial, reference, video)
    * `:size` - Size variant (:sm or :default)

  ## Examples

      <.content_type_badge type="guide" />
      <.content_type_badge type="tutorial" size={:sm} />
  """
  attr :type, :string, required: true
  attr :size, :atom, default: :default, values: [:sm, :default]

  def content_type_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 rounded-lg bg-base-100/90 dark:bg-base-100/80 font-medium text-base-content shadow-sm",
      @size == :sm && "px-2 py-0.5 text-xs",
      @size == :default && "px-2 py-1 text-xs"
    ]}>
      <.icon name={type_icon(@type)} class={(@size == :sm && "h-3 w-3") || "h-3.5 w-3.5"} />
      {String.capitalize(@type)}
    </span>
    """
  end

  @doc """
  Renders reading time with clock icon.

  ## Attributes

    * `:minutes` - Reading time in minutes

  ## Examples

      <.reading_time minutes={5} />
  """
  attr :minutes, :integer, required: true

  def reading_time(assigns) do
    ~H"""
    <span class="flex items-center gap-1 text-xs text-base-content/50">
      <.icon name="hero-clock" class="h-3.5 w-3.5" />
      {ngettext("%{count} min read", "%{count} min read", @minutes, count: @minutes)}
    </span>
    """
  end

  @doc """
  Renders the empty state when no results match filters.

  ## Attributes

    * `:clear_event` - The phx-click event to clear filters

  ## Examples

      <.empty_state clear_event="clear_filters" />
  """
  attr :clear_event, :string, default: "clear_filters"

  def empty_state(assigns) do
    ~H"""
    <div class="text-center py-16">
      <div class="inline-flex items-center justify-center w-20 h-20 rounded-full bg-base-200 mb-6">
        <.icon name="hero-document-magnifying-glass" class="h-10 w-10 text-base-content/40" />
      </div>
      <h2 class="text-xl font-semibold text-base-content mb-2">
        {gettext("No guides found")}
      </h2>
      <p class="text-base-content/60 mb-4">
        {gettext("Try adjusting your search or filters to find what you're looking for.")}
      </p>
      <button phx-click={@clear_event} class="btn btn-primary btn-sm">
        {gettext("Clear all filters")}
      </button>
    </div>
    """
  end

  @doc """
  Renders the completion message shown at the end of a how-to guide.

  ## Examples

      <.completion_message />
  """
  def completion_message(assigns) do
    ~H"""
    <div class="mt-16 p-8 rounded-2xl bg-gradient-to-br from-green-50 to-emerald-50 dark:from-green-900/20 dark:to-emerald-900/20 border border-green-200/50 dark:border-green-800/50 text-center">
      <div class="inline-flex items-center justify-center w-16 h-16 rounded-full bg-green-100 dark:bg-green-900/40 mb-4">
        <.icon name="hero-check-circle" class="h-8 w-8 text-green-600 dark:text-green-400" />
      </div>
      <h3 class="text-xl font-semibold text-base-content mb-2">
        {gettext("You're all set!")}
      </h3>
      <p class="text-base-content/70">
        {gettext("You've completed all the steps in this guide.")}
      </p>
    </div>
    """
  end

  @doc """
  Renders the previous/next navigation links.

  ## Attributes

    * `:prev_how_to` - Previous how-to map (or nil)
    * `:next_how_to` - Next how-to map (or nil)

  ## Examples

      <.how_to_navigation prev_how_to={@prev_how_to} next_how_to={@next_how_to} />
  """
  attr :prev_how_to, :map, default: nil
  attr :next_how_to, :map, default: nil

  def how_to_navigation(assigns) do
    ~H"""
    <div class="mt-12 pt-8 border-t border-base-300/60">
      <div class="flex flex-col sm:flex-row justify-between gap-4">
        <!-- Previous -->
        <div class="flex-1">
          <%= if @prev_how_to do %>
            <.link
              navigate={~p"/resources/#{@prev_how_to.id}"}
              class="group block p-4 rounded-xl border border-base-300/60 hover:border-blue-300/60 hover:bg-base-50 dark:hover:bg-base-200/50 transition-all"
            >
              <div class="text-sm text-base-content/50 mb-1 flex items-center gap-1">
                <span class="group-hover:-translate-x-1 transition-transform">&larr;</span>
                {gettext("Previous")}
              </div>
              <div class="font-medium text-base-content group-hover:text-blue-600 transition-colors line-clamp-1">
                {@prev_how_to.title}
              </div>
            </.link>
          <% else %>
            <div></div>
          <% end %>
        </div>
        <!-- Next -->
        <div class="flex-1">
          <%= if @next_how_to do %>
            <.link
              navigate={~p"/resources/#{@next_how_to.id}"}
              class="group block p-4 rounded-xl border border-base-300/60 hover:border-blue-300/60 hover:bg-base-50 dark:hover:bg-base-200/50 transition-all text-right"
            >
              <div class="text-sm text-base-content/50 mb-1 flex items-center justify-end gap-1">
                {gettext("Next")}
                <span class="group-hover:translate-x-1 transition-transform">&rarr;</span>
              </div>
              <div class="font-medium text-base-content group-hover:text-blue-600 transition-colors line-clamp-1">
                {@next_how_to.title}
              </div>
            </.link>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a category-specific illustration with gradient background.

  ## Attributes

    * `:tags` - List of tags to determine the category
  """
  attr :tags, :list, required: true

  def category_illustration(assigns) do
    # Determine category from tags
    category =
      cond do
        "getting-started" in assigns.tags -> :getting_started
        "developer" in assigns.tags -> :developer
        "non-developer" in assigns.tags -> :non_developer
        "best-practices" in assigns.tags -> :best_practices
        true -> :default
      end

    assigns = assign(assigns, :category, category)

    ~H"""
    <div class="absolute inset-0">
      <!-- Category-specific gradient backgrounds -->
      <div class={[
        "absolute inset-0 transition-all",
        @category == :getting_started && "bg-gradient-to-br from-green-100 to-blue-100 dark:from-green-900/30 dark:to-blue-900/30",
        @category == :developer && "bg-gradient-to-br from-purple-100 to-indigo-100 dark:from-purple-900/30 dark:to-indigo-900/30",
        @category == :non_developer && "bg-gradient-to-br from-orange-100 to-pink-100 dark:from-orange-900/30 dark:to-pink-900/30",
        @category == :best_practices && "bg-gradient-to-br from-yellow-100 to-amber-100 dark:from-yellow-900/30 dark:to-amber-900/30",
        @category == :default && "bg-gradient-to-br from-blue-100 to-purple-100 dark:from-blue-900/30 dark:to-purple-900/30"
      ]} />

      <!-- Category-specific illustrations -->
      <div class="absolute inset-0 flex items-center justify-center">
        <!-- Getting Started: Rocket launch -->
        <div :if={@category == :getting_started} class="relative">
          <.icon name="hero-rocket-launch" class="h-20 w-20 text-green-500/40 dark:text-green-400/40" />
          <.icon name="hero-sparkles" class="h-8 w-8 text-blue-500/30 dark:text-blue-400/30 absolute -top-2 -right-2" />
        </div>

        <!-- Developer: Code with terminal -->
        <div :if={@category == :developer} class="relative">
          <.icon name="hero-code-bracket-square" class="h-20 w-20 text-purple-500/40 dark:text-purple-400/40" />
          <.icon name="hero-command-line" class="h-10 w-10 text-indigo-500/30 dark:text-indigo-400/30 absolute -bottom-1 -right-1" />
        </div>

        <!-- Non-Developer: People with AI -->
        <div :if={@category == :non_developer} class="relative">
          <.icon name="hero-users" class="h-20 w-20 text-orange-500/40 dark:text-orange-400/40" />
          <.icon name="hero-cpu-chip" class="h-10 w-10 text-pink-500/30 dark:text-pink-400/30 absolute -top-1 -right-1" />
        </div>

        <!-- Best Practices: Star with checklist -->
        <div :if={@category == :best_practices} class="relative">
          <.icon name="hero-star" class="h-20 w-20 text-yellow-500/40 dark:text-yellow-400/40" />
          <.icon name="hero-check-badge" class="h-10 w-10 text-amber-500/30 dark:text-amber-400/30 absolute -bottom-1 -right-1" />
        </div>

        <!-- Default: Book -->
        <div :if={@category == :default} class="relative">
          <.icon name="hero-book-open" class="h-20 w-20 text-blue-500/40 dark:text-blue-400/40" />
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Returns the icon name for a content type.

  ## Examples

      iex> type_icon("guide")
      "hero-book-open"
  """
  def type_icon(content_type) do
    HowToData.type_icon(content_type)
  end
end
