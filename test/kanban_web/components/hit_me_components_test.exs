defmodule KanbanWeb.HitMeComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.HitMeComponents

  defp render_highlight(text, values, highlight_class \\ "hitme-accent") do
    assigns = %{text: text, values: values, highlight_class: highlight_class}

    rendered_to_string(~H"""
    <HitMeComponents.hitme_highlight
      text={@text}
      values={@values}
      highlight_class={@highlight_class}
    />
    """)
  end

  defp spans(html, class) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("span.#{class}")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  describe "hitme_highlight/1" do
    test "renders each placeholder value in its styled span" do
      html =
        render_highlight("Start with {desire}, leave with {knowledge}", %{
          "desire" => "desire",
          "knowledge" => "knowledge"
        })

      assert spans(html, "hitme-accent") == ["desire", "knowledge"]
      assert text(html) == "Start with desire, leave with knowledge"
    end

    test "uses the given highlight class" do
      html =
        render_highlight(
          "{lead} to create the Backlog.",
          %{"lead" => "You ideate with an agent"},
          "hitme-step-strong"
        )

      assert spans(html, "hitme-step-strong") == ["You ideate with an agent"]
      assert text(html) == "You ideate with an agent to create the Backlog."
    end

    test "escapes HTML in both the sentence and the values" do
      html =
        render_highlight("<b>Bold</b> {name}", %{"name" => "<script>alert(1)</script>"})

      refute html =~ "<b>"
      refute html =~ "<script>"
      assert html =~ "&lt;b&gt;Bold&lt;/b&gt;"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "renders a sentence with no placeholders unchanged" do
      html = render_highlight("Everybody celebrates.", %{})

      assert spans(html, "hitme-accent") == []
      assert text(html) == "Everybody celebrates."
    end

    test "renders a placeholder with no value as its literal text" do
      html = render_highlight("Start with {desire}", %{})

      assert spans(html, "hitme-accent") == []
      assert text(html) == "Start with {desire}"
    end

    test "renders a placeholder moved to the start or the end of the sentence" do
      start = render_highlight("{lead} und baut sie.", %{"lead" => "Ein Agent übernimmt sie"})
      finish = render_highlight("ナレッジ{knowledge}", %{"knowledge" => "知識"})

      assert text(start) == "Ein Agent übernimmt sie und baut sie."
      assert spans(start, "hitme-accent") == ["Ein Agent übernimmt sie"]
      assert text(finish) == "ナレッジ知識"
      assert spans(finish, "hitme-accent") == ["知識"]
    end
  end

  describe "highlight_parts/2" do
    test "splits text and highlights in order" do
      assert HitMeComponents.highlight_parts("a {x} b {y}", %{"x" => "X", "y" => "Y"}) ==
               [{:text, "a "}, {:highlight, "X"}, {:text, " b "}, {:highlight, "Y"}]
    end

    test "leaves unbalanced and non-lowercase braces as literal text" do
      assert HitMeComponents.highlight_parts("a {y and {Name} b", %{"y" => "Y", "Name" => "N"}) ==
               [{:text, "a {y and {Name} b"}]
    end

    test "returns no parts for an empty sentence" do
      assert HitMeComponents.highlight_parts("", %{}) == []
    end
  end
end
