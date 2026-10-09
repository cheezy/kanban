defmodule KanbanWeb.LabelChipTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Labels.Label
  alias KanbanWeb.LabelChip

  defp render_label(label) do
    assigns = %{label: label}

    rendered_to_string(~H"""
    <LabelChip.label_chip label={@label} />
    """)
  end

  defp render_named(name, color) do
    assigns = %{name: name, color: color}

    rendered_to_string(~H"""
    <LabelChip.label_chip name={@name} color={@color} />
    """)
  end

  describe "label_chip/1" do
    test "renders every colour with its ink, its soft fill and a --line border" do
      for color <- Label.colors() do
        html = render_label(%Label{name: "Bug", color: color})

        assert html =~ "Bug"
        assert html =~ ~s(data-label-chip="#{color}")
        assert html =~ "color: var(--label-#{color});"
        assert html =~ "background: var(--label-#{color}-soft);"
        assert html =~ "border: 1px solid var(--line);"
        refute html =~ "transparent"
      end
    end

    test "accepts a name and a string colour instead of a label" do
      html = render_named("Docs", "teal")

      assert html =~ "Docs"
      assert html =~ "var(--label-teal-soft)"
    end

    test "falls back to gray for an unknown colour and never echoes it" do
      html = render_named("Bug", "red;background:url(x)")

      assert html =~ ~s(data-label-chip="gray")
      assert html =~ "var(--label-gray-soft)"
      refute html =~ "url(x)"

      assert render_named("Bug", nil) =~ "var(--label-gray)"
    end

    test "escapes HTML in the label name" do
      html = render_label(%Label{name: "<script>alert(1)</script>", color: :red})

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "truncates a long name and keeps the full name as a title" do
      name = String.duplicate("long", 10)
      html = render_label(%Label{name: name, color: :blue})

      assert html =~ ~s(title="#{name}")
      assert html =~ "max-width: 16em"
      assert html =~ "text-overflow: ellipsis"
      assert html =~ "white-space: nowrap"
    end
  end

  describe "color_token/1" do
    test "maps whitelisted atoms and strings to their name and anything else to gray" do
      for color <- Label.colors() do
        assert LabelChip.color_token(color) == Atom.to_string(color)
        assert color |> Atom.to_string() |> LabelChip.color_token() == Atom.to_string(color)
      end

      assert LabelChip.color_token(:magenta) == "gray"
      assert LabelChip.color_token("magenta") == "gray"
      assert LabelChip.color_token(42) == "gray"
    end
  end

  describe "color_label/1" do
    test "has a display name for every colour" do
      names = Enum.map(Label.colors(), &LabelChip.color_label/1)

      assert names == ~w(Gray Red Orange Yellow Green Teal Blue Purple Pink)
    end
  end

  describe "label_chip/1 size (W2234)" do
    test "the default :md size keeps the settings chip metrics" do
      html = render_label(%Label{name: "Bug", color: :red})

      assert html =~ "font-size: 11.5px"
      assert html =~ "padding: 2px 8px"
    end

    test ":sm renders the compact card chip" do
      assigns = %{label: %Label{name: "Bug", color: :red}}

      html =
        rendered_to_string(~H"""
        <LabelChip.label_chip label={@label} size={:sm} />
        """)

      assert html =~ "font-size: 10.5px"
      assert html =~ "padding: 1px 6px"
      assert html =~ "max-width: 10em"
      refute html =~ "font-size: 11.5px"
    end
  end

  describe "label_chips/1 (W2234)" do
    defp render_chips(labels, max \\ 3) do
      assigns = %{labels: labels, max: max}

      rendered_to_string(~H"""
      <LabelChip.label_chips labels={@labels} max={@max} size={:sm} />
      """)
    end

    defp labels(n),
      do: for(i <- 1..n, do: %Label{id: i, name: "Label #{i}", color: :blue})

    test "renders every label as a chip when there are no more than max" do
      html = render_chips(labels(3))

      assert html |> String.split("data-label-chip=") |> length() == 4
      refute html =~ "data-label-overflow"
    end

    test "renders max chips plus a +N count for the rest" do
      html = render_chips(labels(5))

      assert html |> String.split("data-label-chip=") |> length() == 4
      assert html =~ "Label 3"
      refute html =~ "Label 4"
      assert html =~ "data-label-overflow"
      assert html =~ "+2"
      assert html =~ ~s(title="2 more labels")
    end

    test "uses the singular for one more label" do
      assert render_chips(labels(4)) =~ ~s(title="1 more label")
    end

    test "renders nothing for no labels" do
      refute render_chips([]) =~ "data-card-labels"
    end

    test "the overflow count uses a token colour and no opacity" do
      html = render_chips(labels(4))

      assert html =~ "color: var(--ink-3)"
      refute html =~ "opacity"
    end
  end
end
