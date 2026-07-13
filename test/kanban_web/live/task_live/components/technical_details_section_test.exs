defmodule KanbanWeb.TaskLive.Components.TechnicalDetailsSectionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskLive.Components.TechnicalDetailsSection

  defp render_details(technical_details) do
    render_component(
      &TechnicalDetailsSection.technical_details_section/1,
      technical_details: technical_details
    )
  end

  describe "technical_details_section/1" do
    test "renders a top-level key and its string value" do
      html = render_details(%{"approach" => "use Ecto.Multi"})

      assert html =~ "approach"
      assert html =~ "use Ecto.Multi"
    end

    test "renders numeric and boolean scalar values" do
      html = render_details(%{"retries" => 3, "async" => true})

      assert html =~ "retries"
      assert html =~ "3"
      assert html =~ "async"
      assert html =~ "true"
    end

    test "renders a nested object readably as JSON" do
      html = render_details(%{"config" => %{"deep" => true, "name" => "x"}})

      assert html =~ "config"
      assert html =~ "<pre"
      # The nested object is JSON-encoded, so its keys appear in the output.
      assert html =~ "deep"
      assert html =~ "name"
    end

    test "renders an array value readably as JSON" do
      html = render_details(%{"steps" => ["one", "two", "three"]})

      assert html =~ "steps"
      assert html =~ "<pre"
      assert html =~ "one"
      assert html =~ "two"
      assert html =~ "three"
    end

    test "uses the theme-aware violet palette tokens" do
      html = render_details(%{"k" => "v"})

      assert html =~ "var(--stride-violet-soft)"
      assert html =~ "var(--stride-violet-ink)"
    end

    test "renders nothing for an empty map" do
      html = render_details(%{})

      refute html =~ "var(--stride-violet-soft)"
      refute html =~ "<pre"
    end

    test "escapes HTML-ish scalar content rather than injecting raw markup" do
      html = render_details(%{"xss" => "<script>alert(1)</script>"})

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "escapes HTML inside nested JSON values" do
      html = render_details(%{"nested" => %{"x" => "<img src=x onerror=1>"}})

      refute html =~ "<img src=x onerror=1>"
      assert html =~ "&lt;img"
    end

    test "renders a non-JSON scalar (atom) via the inspect fallback" do
      html = render_details(%{"status" => :in_progress})

      assert html =~ "status"
      # The fallback clause inspects the value, so the atom renders with its colon.
      assert html =~ ":in_progress"
    end

    test "renders a tuple value via the inspect fallback without crashing" do
      html = render_details(%{"pair" => {:ok, 42}})

      assert html =~ "pair"
      # Tuples are not JSON-encodable; inspect/1 output is escaped text.
      assert html =~ "{:ok, 42}"
    end
  end
end
