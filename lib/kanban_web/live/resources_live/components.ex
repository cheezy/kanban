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
      class="group"
      style={[
        "display: flex; flex-direction: column; overflow: hidden;",
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 10px;",
        "text-decoration: none;",
        "transition: border-color 160ms ease, transform 160ms ease, box-shadow 160ms ease;"
      ]}
    >
      <div class="aspect-video" style="position: relative; overflow: hidden;">
        <.category_illustration tags={@how_to.tags} />
        <div style="position: absolute; top: 12px; right: 12px;">
          <.content_type_badge type={@how_to.content_type} />
        </div>
      </div>
      <div style="padding: 18px; flex: 1; display: flex; flex-direction: column;">
        <h3
          class="line-clamp-2"
          style={[
            "margin: 0 0 6px;",
            "font-size: 14px; font-weight: 600; letter-spacing: -0.01em;",
            "color: var(--ink);"
          ]}
        >
          {@how_to.title}
        </h3>
        <p
          class="line-clamp-2"
          style={[
            "margin: 0 0 14px;",
            "font-size: 12.5px; color: var(--ink-3); flex: 1;"
          ]}
        >
          {@how_to.description}
        </p>
        <div style="display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 14px;">
          <span
            :for={tag <- Enum.take(@how_to.tags, 3)}
            style={[
              "padding: 2px 8px; border-radius: 999px;",
              "background: var(--surface-sunken); color: var(--ink-3);",
              "font-size: 10.5px; font-family: var(--font-mono);"
            ]}
          >
            {@format_tag_fn.(tag)}
          </span>
        </div>
        <div style={[
          "display: flex; align-items: center; justify-content: space-between;",
          "padding-top: 12px; border-top: 1px solid var(--line);"
        ]}>
          <.reading_time minutes={@how_to.reading_time} />
          <span style={[
            "display: inline-flex; align-items: center; gap: 4px;",
            "font-size: 11.5px; font-weight: 500;",
            "color: var(--stride-orange);"
          ]}>
            {gettext("Read more")}
            <span>&rarr;</span>
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
    <div style="position: relative; max-width: 36rem; margin: 0 auto;">
      <div style={[
        "position: absolute; inset-block: 0; left: 0;",
        "padding-left: 12px; display: flex; align-items: center;",
        "pointer-events: none; color: var(--ink-4);"
      ]}>
        <.icon name="hero-magnifying-glass" class="h-4 w-4" />
      </div>
      <input
        type="text"
        name="query"
        value={@value}
        placeholder={@placeholder}
        phx-keyup={@event}
        phx-debounce={@debounce}
        style={[
          "display: block; width: 100%;",
          "padding: 10px 12px 10px 36px;",
          "font-size: 13px; color: var(--ink);",
          "background: var(--surface);",
          "border: 1px solid var(--line); border-radius: 8px;",
          "outline: none; transition: border-color 160ms ease;"
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
    <div style="display: flex; flex-wrap: wrap; justify-content: center; gap: 8px;">
      <button
        :for={tag <- @tags}
        phx-click={@event}
        phx-value-tag={tag}
        data-tag-filter-active={tag in @selected && "true"}
        style={
          if tag in @selected do
            "padding: 5px 12px; border-radius: 999px; font-size: 12px; font-weight: 500; cursor: pointer; background: var(--stride-orange); color: white; border: 1px solid var(--stride-orange);"
          else
            "padding: 5px 12px; border-radius: 999px; font-size: 12px; font-weight: 500; cursor: pointer; background: var(--surface-sunken); color: var(--ink-2); border: 1px solid var(--line);"
          end
        }
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
      style={
        if @size == :sm do
          "display: inline-flex; align-items: center; gap: 4px; padding: 2px 8px; border-radius: 999px; font-size: 10.5px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); font-family: var(--font-mono);"
        else
          "display: inline-flex; align-items: center; gap: 4px; padding: 4px 10px; border-radius: 999px; font-size: 11px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); font-family: var(--font-mono);"
        end
      }
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
    <span style={[
      "display: inline-flex; align-items: center; gap: 4px;",
      "font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);"
    ]}>
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
    <div style="text-align: center; padding: 56px 0;">
      <div style={[
        "display: inline-flex; align-items: center; justify-content: center;",
        "width: 64px; height: 64px; border-radius: 999px;",
        "background: var(--surface-sunken); color: var(--ink-4);",
        "margin-bottom: 18px;"
      ]}>
        <.icon name="hero-document-magnifying-glass" class="h-8 w-8" />
      </div>
      <h2 style={[
        "margin: 0 0 6px;",
        "font-size: 16px; font-weight: 600; color: var(--ink);"
      ]}>
        {gettext("No guides found")}
      </h2>
      <p style="margin: 0 0 16px; font-size: 12.5px; color: var(--ink-3);">
        {gettext("Try adjusting your search or filters to find what you're looking for.")}
      </p>
      <button
        phx-click={@clear_event}
        style={[
          "padding: 6px 14px; border-radius: 6px;",
          "font-size: 12px; font-weight: 500; cursor: pointer;",
          "background: var(--stride-orange); color: white;",
          "border: 1px solid var(--stride-orange);"
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
      |> assign(:bg_style, category_bg_style(category))
      |> assign(:icon_color, category_icon_color(category))

    ~H"""
    <div style="position: absolute; inset: 0;">
      <div data-category={@category} style={@bg_style}></div>

      <div style={[
        "position: absolute; inset: 0;",
        "display: flex; align-items: center; justify-content: center;"
      ]}>
        <div :if={@category == :getting_started} style="position: relative;">
          <span style={"display: inline-flex; color: #{@icon_color};"}>
            <.icon name="hero-rocket-launch" class="h-16 w-16" />
          </span>
          <span style={[
            "position: absolute; top: -8px; right: -8px;",
            "display: inline-flex; color: var(--stride-orange);"
          ]}>
            <.icon name="hero-sparkles" class="h-6 w-6" />
          </span>
        </div>

        <div :if={@category == :developer} style="position: relative;">
          <span style={"display: inline-flex; color: #{@icon_color};"}>
            <.icon name="hero-code-bracket-square" class="h-16 w-16" />
          </span>
          <span style={[
            "position: absolute; bottom: -4px; right: -4px;",
            "display: inline-flex; color: var(--stride-violet);"
          ]}>
            <.icon name="hero-command-line" class="h-8 w-8" />
          </span>
        </div>

        <div :if={@category == :non_developer} style="position: relative;">
          <span style={"display: inline-flex; color: #{@icon_color};"}>
            <.icon name="hero-users" class="h-16 w-16" />
          </span>
          <span style={[
            "position: absolute; top: -4px; right: -4px;",
            "display: inline-flex; color: var(--stride-orange);"
          ]}>
            <.icon name="hero-cpu-chip" class="h-8 w-8" />
          </span>
        </div>

        <div :if={@category == :best_practices} style="position: relative;">
          <span style={"display: inline-flex; color: #{@icon_color};"}>
            <.icon name="hero-star" class="h-16 w-16" />
          </span>
          <span style={[
            "position: absolute; bottom: -4px; right: -4px;",
            "display: inline-flex; color: var(--stride-orange);"
          ]}>
            <.icon name="hero-check-badge" class="h-8 w-8" />
          </span>
        </div>

        <div :if={@category == :default} style="position: relative;">
          <span style={"display: inline-flex; color: #{@icon_color};"}>
            <.icon name="hero-book-open" class="h-16 w-16" />
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp category_bg_style(:getting_started) do
    "position: absolute; inset: 0; background: linear-gradient(135deg, var(--st-done-soft), var(--st-ready-soft));"
  end

  defp category_bg_style(:developer) do
    "position: absolute; inset: 0; background: linear-gradient(135deg, var(--stride-violet-soft), var(--st-ready-soft));"
  end

  defp category_bg_style(:non_developer) do
    "position: absolute; inset: 0; background: linear-gradient(135deg, var(--stride-orange-soft), var(--st-blocked-soft));"
  end

  defp category_bg_style(:best_practices) do
    "position: absolute; inset: 0; background: linear-gradient(135deg, var(--st-doing-soft), var(--stride-orange-soft));"
  end

  defp category_bg_style(:default) do
    "position: absolute; inset: 0; background: linear-gradient(135deg, var(--st-ready-soft), var(--stride-violet-soft));"
  end

  defp category_icon_color(:getting_started), do: "var(--st-done)"
  defp category_icon_color(:developer), do: "var(--stride-violet)"
  defp category_icon_color(:non_developer), do: "var(--stride-orange)"
  defp category_icon_color(:best_practices), do: "var(--st-doing)"
  defp category_icon_color(:default), do: "var(--st-ready)"

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
