defmodule KanbanWeb.ResourcesLive.Components do
  @moduledoc """
  Reusable UI components for the Resources section.

  Provides function components for resource cards, search bar, tag filters,
  and how-to content rendering. Restyled to the stride-screen token system —
  every chrome element renders inline styles referencing the design-system
  CSS variables defined in `assets/css/app.css`.
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
      class="group flex flex-col overflow-hidden no-underline transition-all hover:-translate-y-0.5"
      style={[
        "background: var(--surface);",
        "border: 1px solid var(--line);",
        "border-radius: var(--r-lg);",
        "box-shadow: var(--shadow-sm);"
      ]}
    >
      <div class="aspect-video relative overflow-hidden">
        <.category_illustration tags={@how_to.tags} />
        <div class="absolute top-3 right-3">
          <.content_type_badge type={@how_to.content_type} />
        </div>
      </div>
      <div class="p-[18px] flex-1 flex flex-col">
        <h3
          class="line-clamp-2 m-0 mb-1.5 text-[14px] font-semibold tracking-tight"
          style="color: var(--ink);"
        >
          {@how_to.title}
        </h3>
        <p
          class="line-clamp-2 m-0 mb-[14px] text-[12.5px] flex-1"
          style="color: var(--ink-2);"
        >
          {@how_to.description}
        </p>
        <div class="flex flex-wrap gap-1.5 mb-[14px]">
          <span
            :for={tag <- Enum.take(@how_to.tags, 3)}
            class="px-2 py-0.5 text-[10.5px] font-mono"
            style={[
              "background: var(--surface-2);",
              "color: var(--ink-2);",
              "border: 1px solid var(--line);",
              "border-radius: 999px;"
            ]}
          >
            {@format_tag_fn.(tag)}
          </span>
        </div>
        <div
          class="flex items-center justify-between pt-3"
          style="border-top: 1px solid var(--line);"
        >
          <.reading_time minutes={@how_to.reading_time} />
          <span
            class="inline-flex items-center gap-1 text-[11.5px] font-medium"
            style="color: var(--stride-orange);"
          >
            {gettext("Read more")}
            <.icon name="hero-arrow-right" class="h-3 w-3" />
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
      <div
        class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none"
        style="color: var(--ink-3);"
      >
        <.icon name="hero-magnifying-glass" class="h-4 w-4" />
      </div>
      <input
        type="text"
        name="query"
        value={@value}
        placeholder={@placeholder}
        phx-keyup={@event}
        phx-debounce={@debounce}
        class="block w-full py-2.5 pr-3 pl-9 text-[13px] outline-none transition-colors"
        style={[
          "background: var(--surface);",
          "color: var(--ink);",
          "border: 1px solid var(--line);",
          "border-radius: var(--r-md);"
        ]}
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
        type="button"
        phx-click={@event}
        phx-value-tag={tag}
        data-tag-filter-active={tag in @selected && "true"}
        class="px-3 py-[5px] text-[11.5px] font-medium cursor-pointer transition-colors"
        style={[
          "border-radius: 999px;",
          if(tag in @selected,
            do:
              "background: var(--stride-orange); color: white; border: 1px solid var(--stride-orange);",
            else: "background: var(--surface-2); color: var(--ink-2); border: 1px solid var(--line);"
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
    <div style="display: flex; flex-direction: column; gap: 36px;">
      <%= for {step, index} <- Enum.with_index(@steps, 1) do %>
        <div style="position: relative;">
          <div style="display: flex; align-items: flex-start; gap: 18px;">
            <div
              class="rounded-full"
              style={[
                "flex-shrink: 0; width: 36px; height: 36px;",
                "display: flex; align-items: center; justify-content: center;",
                "background: var(--stride-orange); color: white;",
                "font-weight: 600; font-size: 14px; font-family: var(--font-mono);"
              ]}
            >
              {index}
            </div>
            <div style="flex: 1; padding-top: 4px;">
              <h2 style={[
                "margin: 0 0 12px;",
                "font-size: 16px; font-weight: 600; color: var(--ink);"
              ]}>
                {step.title}
              </h2>
              <div
                class="prose max-w-prose"
                style="color: var(--ink-2); line-height: 1.6;"
              >
                {Phoenix.HTML.raw(@render_markdown_fn.(step.content))}
              </div>
              <%= if step[:images] do %>
                <div style={[
                  "margin-top: 18px; display: grid; gap: 12px;",
                  "grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));"
                ]}>
                  <%= for img <- step.images do %>
                    <div>
                      <img
                        src={img.url}
                        alt={img[:alt] || "Step #{index}: #{step.title}"}
                        width={img[:width] || 640}
                        height={img[:height] || 360}
                        style={[
                          "max-width: 100%; height: auto;",
                          "border-radius: 8px;",
                          "border: 1px solid var(--line);"
                        ]}
                        loading="lazy"
                      />
                      <%= if String.ends_with?(img.url, ".svg") do %>
                        <p style={[
                          "margin: 6px 0 0; text-align: center;",
                          "font-size: 11px; color: var(--ink-4); font-style: italic;"
                        ]}>
                          Placeholder - {img[:width] || 640} × {img[:height] || 360}px
                        </p>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
              <%= if step[:image] do %>
                <div style="margin-top: 18px;">
                  <img
                    src={step.image}
                    alt={"Step #{index}: #{step.title}"}
                    width={step[:image_width] || 1280}
                    height={step[:image_height] || 720}
                    style={[
                      "max-width: 100%; height: auto;",
                      "border-radius: 8px;",
                      "border: 1px solid var(--line);"
                    ]}
                    loading="lazy"
                  />
                  <%= if String.ends_with?(step.image, ".svg") do %>
                    <p style={[
                      "margin: 6px 0 0; text-align: center;",
                      "font-size: 11px; color: var(--ink-4); font-style: italic;"
                    ]}>
                      Placeholder image - Replace with actual screenshot ({step[:image_width] || 1280} × {step[
                        :image_height
                      ] || 720}px)
                    </p>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
          <%= if index < length(@steps) do %>
            <div style={[
              "position: absolute; left: 18px; top: 44px;",
              "width: 1px; background: var(--line);",
              "transform: translateX(-50%); height: calc(100% - 36px);"
            ]}>
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
    <span
      data-content-type-size={@size}
      class={[
        "inline-flex items-center gap-1 font-medium font-mono",
        if(@size == :sm, do: "px-2 py-0.5 text-[10.5px]", else: "px-2.5 py-1 text-[11px]")
      ]}
      style={[
        "background: var(--surface);",
        "color: var(--ink-2);",
        "border: 1px solid var(--line);",
        "border-radius: 999px;"
      ]}
    >
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
    <span
      class="inline-flex items-center gap-1 text-[11px] font-mono"
      style="color: var(--ink-3);"
    >
      <.icon name="hero-clock" class="h-3 w-3" />
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
    <div class="text-center py-14">
      <div
        class="inline-flex items-center justify-center w-16 h-16 mb-[18px]"
        style={[
          "background: var(--surface-2);",
          "color: var(--ink-3);",
          "border: 1px solid var(--line);",
          "border-radius: 999px;"
        ]}
      >
        <.icon name="hero-document-magnifying-glass" class="h-8 w-8" />
      </div>
      <h2
        class="m-0 mb-1.5 text-[16px] font-semibold"
        style="color: var(--ink);"
      >
        {gettext("No guides found")}
      </h2>
      <p
        class="m-0 mb-4 text-[12.5px]"
        style="color: var(--ink-2);"
      >
        {gettext("Try adjusting your search or filters to find what you're looking for.")}
      </p>
      <button
        type="button"
        phx-click={@clear_event}
        class="px-3.5 py-1.5 text-[12px] font-medium cursor-pointer"
        style={[
          "background: var(--stride-orange);",
          "color: white;",
          "border: 1px solid var(--stride-orange);",
          "border-radius: var(--r-md);"
        ]}
      >
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
    <div style={[
      "margin-top: 48px; padding: 32px; text-align: center;",
      "background: var(--st-done-soft);",
      "border: 1px solid var(--st-done); border-radius: 10px;"
    ]}>
      <div style={[
        "display: inline-flex; align-items: center; justify-content: center;",
        "width: 56px; height: 56px; border-radius: 999px;",
        "background: var(--surface); color: var(--st-done);",
        "margin-bottom: 14px;"
      ]}>
        <.icon name="hero-check-circle" class="h-7 w-7" />
      </div>
      <h3 style={[
        "margin: 0 0 6px;",
        "font-size: 16px; font-weight: 600; color: var(--ink);"
      ]}>
        {gettext("You're all set!")}
      </h3>
      <p style="margin: 0; font-size: 12.5px; color: var(--ink-3);">
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
    <div
      class="border-t"
      style="margin-top: 36px; padding-top: 24px; border-top: 1px solid var(--line);"
    >
      <div style={[
        "display: flex; justify-content: space-between; gap: 14px;",
        "flex-wrap: wrap;"
      ]}>
        <div style="flex: 1; min-width: 240px;">
          <%= if @prev_how_to do %>
            <.link
              navigate={~p"/resources/#{@prev_how_to.id}"}
              class="group"
              style={[
                "display: block; padding: 14px;",
                "background: var(--surface);",
                "border: 1px solid var(--line); border-radius: 8px;",
                "text-decoration: none;",
                "transition: border-color 160ms ease;"
              ]}
            >
              <div style={[
                "display: flex; align-items: center; gap: 4px;",
                "margin-bottom: 4px;",
                "font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);",
                "text-transform: uppercase; letter-spacing: 0.08em;"
              ]}>
                <span>&larr;</span> {gettext("Previous")}
              </div>
              <div
                class="line-clamp-1"
                style={[
                  "font-size: 13px; font-weight: 500; color: var(--ink);"
                ]}
              >
                {@prev_how_to.title}
              </div>
            </.link>
          <% else %>
            <div></div>
          <% end %>
        </div>
        <div style="flex: 1; min-width: 240px;">
          <%= if @next_how_to do %>
            <.link
              navigate={~p"/resources/#{@next_how_to.id}"}
              class="group"
              style={[
                "display: block; padding: 14px; text-align: right;",
                "background: var(--surface);",
                "border: 1px solid var(--line); border-radius: 8px;",
                "text-decoration: none;",
                "transition: border-color 160ms ease;"
              ]}
            >
              <div style={[
                "display: flex; align-items: center; justify-content: flex-end; gap: 4px;",
                "margin-bottom: 4px;",
                "font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);",
                "text-transform: uppercase; letter-spacing: 0.08em;"
              ]}>
                {gettext("Next")} <span>&rarr;</span>
              </div>
              <div
                class="line-clamp-1"
                style={[
                  "font-size: 13px; font-weight: 500; color: var(--ink);"
                ]}
              >
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
    category =
      cond do
        "getting-started" in assigns.tags -> :getting_started
        "developer" in assigns.tags -> :developer
        "non-developer" in assigns.tags -> :non_developer
        "best-practices" in assigns.tags -> :best_practices
        true -> :default
      end

    assigns =
      assigns
      |> assign(:category, category)
      |> assign(:bg_class, category_bg_class(category))
      |> assign(:icon_class, category_icon_class(category))

    ~H"""
    <div class="absolute inset-0">
      <div data-category={@category} class={["absolute inset-0 bg-gradient-to-br", @bg_class]}></div>

      <div class="absolute inset-0 flex items-center justify-center">
        <div :if={@category == :getting_started} class="relative">
          <span class={["inline-flex", @icon_class]}>
            <.icon name="hero-rocket-launch" class="h-16 w-16" />
          </span>
          <span class="absolute -top-2 -right-2 inline-flex text-warning">
            <.icon name="hero-sparkles" class="h-6 w-6" />
          </span>
        </div>

        <div :if={@category == :developer} class="relative">
          <span class={["inline-flex", @icon_class]}>
            <.icon name="hero-code-bracket-square" class="h-16 w-16" />
          </span>
          <span class="absolute -bottom-1 -right-1 inline-flex text-secondary">
            <.icon name="hero-command-line" class="h-8 w-8" />
          </span>
        </div>

        <div :if={@category == :non_developer} class="relative">
          <span class={["inline-flex", @icon_class]}>
            <.icon name="hero-users" class="h-16 w-16" />
          </span>
          <span class="absolute -top-1 -right-1 inline-flex text-warning">
            <.icon name="hero-cpu-chip" class="h-8 w-8" />
          </span>
        </div>

        <div :if={@category == :best_practices} class="relative">
          <span class={["inline-flex", @icon_class]}>
            <.icon name="hero-star" class="h-16 w-16" />
          </span>
          <span class="absolute -bottom-1 -right-1 inline-flex text-warning">
            <.icon name="hero-check-badge" class="h-8 w-8" />
          </span>
        </div>

        <div :if={@category == :default} class="relative">
          <span class={["inline-flex", @icon_class]}>
            <.icon name="hero-book-open" class="h-16 w-16" />
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp category_bg_class(:getting_started), do: "from-success/20 to-info/20"
  defp category_bg_class(:developer), do: "from-secondary/20 to-info/20"
  defp category_bg_class(:non_developer), do: "from-warning/20 to-error/20"
  defp category_bg_class(:best_practices), do: "from-accent/20 to-warning/20"
  defp category_bg_class(:default), do: "from-info/20 to-secondary/20"

  defp category_icon_class(:getting_started), do: "text-success"
  defp category_icon_class(:developer), do: "text-secondary"
  defp category_icon_class(:non_developer), do: "text-warning"
  defp category_icon_class(:best_practices), do: "text-accent"
  defp category_icon_class(:default), do: "text-info"

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
