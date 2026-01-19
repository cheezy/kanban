defmodule KanbanWeb.ResourcesLive.ComponentsTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest

  alias KanbanWeb.ResourcesLive.Components

  describe "resource_card/1" do
    test "renders thumbnail with type icon" do
      how_to = sample_how_to()
      html = render_component(&Components.resource_card/1, how_to: how_to)

      assert html =~ "hero-book-open"
      assert html =~ "aspect-video"
    end

    test "renders title" do
      how_to = sample_how_to()
      html = render_component(&Components.resource_card/1, how_to: how_to)

      assert html =~ "Test Guide"
    end

    test "renders description" do
      how_to = sample_how_to()
      html = render_component(&Components.resource_card/1, how_to: how_to)

      assert html =~ "A test guide description"
    end

    test "renders tags (max 3)" do
      how_to = sample_how_to()
      html = render_component(&Components.resource_card/1, how_to: how_to)

      assert html =~ "Getting Started"
      assert html =~ "Beginner"
      assert html =~ "Boards"
    end

    test "renders content type badge" do
      how_to = sample_how_to()
      html = render_component(&Components.resource_card/1, how_to: how_to)

      assert html =~ "Guide"
    end

    test "renders reading time" do
      how_to = sample_how_to()
      html = render_component(&Components.resource_card/1, how_to: how_to)

      assert html =~ "5 min read"
    end

    test "renders read more link" do
      how_to = sample_how_to()
      html = render_component(&Components.resource_card/1, how_to: how_to)

      assert html =~ "Read more"
      assert html =~ ~s(href="/resources/test-guide")
    end
  end

  describe "search_bar/1" do
    test "renders input with search icon" do
      html = render_component(&Components.search_bar/1, value: "")

      assert html =~ "hero-magnifying-glass"
      assert html =~ ~s(type="text")
      assert html =~ ~s(name="query")
    end

    test "renders with current value" do
      html = render_component(&Components.search_bar/1, value: "test query")

      assert html =~ ~s(value="test query")
    end

    test "renders with custom placeholder" do
      html = render_component(&Components.search_bar/1, value: "", placeholder: "Find stuff...")

      assert html =~ "Find stuff..."
    end

    test "renders with default debounce" do
      html = render_component(&Components.search_bar/1, value: "")

      assert html =~ "phx-debounce=\"300\""
    end

    test "renders with custom event" do
      html = render_component(&Components.search_bar/1, value: "", event: "filter")

      assert html =~ "phx-keyup=\"filter\""
    end
  end

  describe "tag_filter/1" do
    test "renders all tags as pills" do
      html =
        render_component(&Components.tag_filter/1,
          tags: ["getting-started", "developer"],
          selected: []
        )

      assert html =~ "Getting Started"
      assert html =~ "Developer"
    end

    test "renders selected tags with active state" do
      html =
        render_component(&Components.tag_filter/1,
          tags: ["getting-started", "developer"],
          selected: ["getting-started"]
        )

      # Active state has bg-blue-600
      assert html =~ "bg-blue-600"
      # Inactive state has bg-base-200
      assert html =~ "bg-base-200"
    end

    test "renders with toggle event" do
      html =
        render_component(&Components.tag_filter/1,
          tags: ["getting-started"],
          selected: []
        )

      assert html =~ "phx-click=\"toggle_tag\""
      assert html =~ "phx-value-tag=\"getting-started\""
    end

    test "renders with custom event" do
      html =
        render_component(&Components.tag_filter/1,
          tags: ["test"],
          selected: [],
          event: "select_tag"
        )

      assert html =~ "phx-click=\"select_tag\""
    end
  end

  describe "how_to_content/1" do
    test "renders steps with numbers" do
      steps = sample_steps()

      html =
        render_component(&Components.how_to_content/1,
          steps: steps,
          render_markdown_fn: &simple_markdown/1
        )

      # Should have numbered step indicators
      assert html =~ "rounded-full"
      assert html =~ "Step 1 Title"
      assert html =~ "Step 2 Title"
    end

    test "renders step titles" do
      steps = sample_steps()

      html =
        render_component(&Components.how_to_content/1,
          steps: steps,
          render_markdown_fn: &simple_markdown/1
        )

      assert html =~ "Step 1 Title"
      assert html =~ "Step 2 Title"
    end

    test "renders step content" do
      steps = sample_steps()

      html =
        render_component(&Components.how_to_content/1,
          steps: steps,
          render_markdown_fn: &simple_markdown/1
        )

      assert html =~ "Step 1 content"
      assert html =~ "Step 2 content"
    end

    test "renders step images when present" do
      steps = [
        %{title: "Step with image", content: "Content", image: "/images/test.png"}
      ]

      html =
        render_component(&Components.how_to_content/1,
          steps: steps,
          render_markdown_fn: &simple_markdown/1
        )

      assert html =~ ~s(src="/images/test.png")
      assert html =~ ~s(alt="Step 1: Step with image")
    end

    test "does not render image when nil" do
      steps = [%{title: "No image step", content: "Content", image: nil}]

      html =
        render_component(&Components.how_to_content/1,
          steps: steps,
          render_markdown_fn: &simple_markdown/1
        )

      refute html =~ "<img"
    end
  end

  describe "content_type_badge/1" do
    test "renders guide badge" do
      html = render_component(&Components.content_type_badge/1, type: "guide")

      assert html =~ "hero-book-open"
      assert html =~ "Guide"
    end

    test "renders tutorial badge" do
      html = render_component(&Components.content_type_badge/1, type: "tutorial")

      assert html =~ "hero-academic-cap"
      assert html =~ "Tutorial"
    end

    test "renders reference badge" do
      html = render_component(&Components.content_type_badge/1, type: "reference")

      assert html =~ "hero-document-text"
      assert html =~ "Reference"
    end

    test "renders video badge" do
      html = render_component(&Components.content_type_badge/1, type: "video")

      assert html =~ "hero-play-circle"
      assert html =~ "Video"
    end

    test "renders small size variant" do
      html = render_component(&Components.content_type_badge/1, type: "guide", size: :sm)

      assert html =~ "px-2 py-0.5"
      assert html =~ "h-3 w-3"
    end
  end

  describe "reading_time/1" do
    test "renders minutes with clock icon" do
      html = render_component(&Components.reading_time/1, minutes: 5)

      assert html =~ "hero-clock"
      assert html =~ "5 min read"
    end

    test "renders singular minute" do
      html = render_component(&Components.reading_time/1, minutes: 1)

      assert html =~ "1 min read"
    end
  end

  describe "empty_state/1" do
    test "renders no guides found message" do
      html = render_component(&Components.empty_state/1, %{})

      assert html =~ "No guides found"
      assert html =~ "Try adjusting your search"
    end

    test "renders clear filters button" do
      html = render_component(&Components.empty_state/1, %{})

      assert html =~ "Clear all filters"
      assert html =~ "phx-click=\"clear_filters\""
    end

    test "renders with custom clear event" do
      html = render_component(&Components.empty_state/1, clear_event: "reset_filters")

      assert html =~ "phx-click=\"reset_filters\""
    end
  end

  describe "completion_message/1" do
    test "renders success message" do
      html = render_component(&Components.completion_message/1, %{})

      assert html =~ "all set"
      assert html =~ "completed all the steps"
    end

    test "renders check icon" do
      html = render_component(&Components.completion_message/1, %{})

      assert html =~ "hero-check-circle"
    end
  end

  describe "how_to_navigation/1" do
    test "renders previous link when available" do
      prev = %{id: "prev-guide", title: "Previous Guide"}

      html =
        render_component(&Components.how_to_navigation/1,
          prev_how_to: prev,
          next_how_to: nil
        )

      assert html =~ "Previous"
      assert html =~ "Previous Guide"
      assert html =~ ~s(href="/resources/prev-guide")
    end

    test "renders next link when available" do
      next = %{id: "next-guide", title: "Next Guide"}

      html =
        render_component(&Components.how_to_navigation/1,
          prev_how_to: nil,
          next_how_to: next
        )

      assert html =~ "Next"
      assert html =~ "Next Guide"
      assert html =~ ~s(href="/resources/next-guide")
    end

    test "renders both when both available" do
      prev = %{id: "prev-guide", title: "Previous Guide"}
      next = %{id: "next-guide", title: "Next Guide"}

      html =
        render_component(&Components.how_to_navigation/1,
          prev_how_to: prev,
          next_how_to: next
        )

      assert html =~ "Previous Guide"
      assert html =~ "Next Guide"
    end

    test "renders empty placeholder when neither available" do
      html =
        render_component(&Components.how_to_navigation/1,
          prev_how_to: nil,
          next_how_to: nil
        )

      # Should still render the container
      assert html =~ "border-t"
    end
  end

  describe "type_icon/1" do
    test "returns correct icon for guide" do
      assert Components.type_icon("guide") == "hero-book-open"
    end

    test "returns correct icon for tutorial" do
      assert Components.type_icon("tutorial") == "hero-academic-cap"
    end

    test "returns default icon for unknown" do
      assert Components.type_icon("unknown") == "hero-document"
    end
  end

  # Helper functions

  defp sample_how_to do
    %{
      id: "test-guide",
      title: "Test Guide",
      description: "A test guide description",
      tags: ["getting-started", "beginner", "boards"],
      content_type: "guide",
      reading_time: 5
    }
  end

  defp sample_steps do
    [
      %{title: "Step 1 Title", content: "Step 1 content", image: nil},
      %{title: "Step 2 Title", content: "Step 2 content", image: nil}
    ]
  end

  defp simple_markdown(content), do: content
end
