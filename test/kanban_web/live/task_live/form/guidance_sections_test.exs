defmodule KanbanWeb.TaskLive.Form.GuidanceSectionsTest do
  @moduledoc """
  Unit tests for the task form's four plain string-list sections.

  All four share one shape — a visibility gate, an always-present empty hidden
  input, one text input per existing entry, and indexed remove buttons — so the
  tests below drive them from one table rather than repeating four near-identical
  blocks. What matters per section is that its gate is keyed to its OWN field
  name and that its inputs/events carry its own names.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.Form.GuidanceSections

  # {schema field, form field name, add event, remove event}
  @sections [
    {:technology_requirements, "technology_requirements", "add-technology", "remove-technology"},
    {:pitfalls, "pitfalls", "add-pitfall", "remove-pitfall"},
    {:out_of_scope, "out_of_scope", "add-out-of-scope", "remove-out-of-scope"},
    {:security_considerations, "security_considerations", "add-security-consideration",
     "remove-security-consideration"}
  ]

  defp render_sections(task_attrs, visibility, myself \\ nil) do
    form =
      %Task{}
      |> Task.changeset(task_attrs)
      |> to_form(as: :task)

    assigns = %{f: form, field_visibility: visibility, myself: myself}

    rendered_to_string(~H"""
    <GuidanceSections.guidance_sections
      f={@f}
      field_visibility={@field_visibility}
      myself={@myself}
    />
    """)
  end

  defp all_visible, do: Map.new(@sections, fn {_, name, _, _} -> {name, true} end)

  describe "visibility gating" do
    test "renders nothing at all when the visibility map is empty" do
      assert render_sections(%{}, %{}) |> String.trim() == ""
    end

    test "a field absent from the visibility map defaults to hidden" do
      # Only pitfalls is named; the other three keys are missing entirely.
      html = render_sections(%{pitfalls: ["p"]}, %{"pitfalls" => true})

      assert html =~ "add-pitfall"
      refute html =~ "add-technology"
      refute html =~ "add-out-of-scope"
      refute html =~ "add-security-consideration"
    end

    test "an explicit false hides the section just as an absent key does" do
      for {_field, name, add_event, _remove} <- @sections do
        refute render_sections(%{}, %{name => false}) =~ add_event
      end
    end

    test "each section is gated on its own field name, independently" do
      for {field, name, add_event, _remove} <- @sections do
        html = render_sections(%{field => ["only me"]}, %{name => true})

        assert html =~ add_event, "#{name} should render when its own key is true"

        others = Enum.reject(@sections, fn {_, other, _, _} -> other == name end)

        for {_, _, other_add, _} <- others do
          refute html =~ other_add,
                 "#{name} being visible must not render #{other_add}"
        end
      end
    end

    test "all four render together when all four are visible" do
      html = render_sections(%{}, all_visible())

      for {_field, _name, add_event, _remove} <- @sections do
        assert html =~ add_event
      end
    end
  end

  describe "entry rendering" do
    test "renders one text input per existing entry, carrying its value" do
      html =
        render_sections(
          %{pitfalls: ["Do not modify the card layout", "Avoid N+1 queries"]},
          %{"pitfalls" => true}
        )

      assert html =~ "Do not modify the card layout"
      assert html =~ "Avoid N+1 queries"
      assert length(Regex.scan(~r/name="task\[pitfalls\]\[\]"/, html)) == 3
    end

    test "remove buttons carry the entry's zero-based index" do
      html = render_sections(%{pitfalls: ["a", "b", "c"]}, %{"pitfalls" => true})

      assert html =~ ~s(phx-value-index="0")
      assert html =~ ~s(phx-value-index="1")
      assert html =~ ~s(phx-value-index="2")
      refute html =~ ~s(phx-value-index="3")
    end

    test "an empty list renders the add button but no entry rows" do
      html = render_sections(%{pitfalls: []}, %{"pitfalls" => true})

      assert html =~ "add-pitfall"
      refute html =~ "remove-pitfall"
      # Only the hidden clearing input remains.
      assert length(Regex.scan(~r/name="task\[pitfalls\]\[\]"/, html)) == 1
    end

    test "a nil list is tolerated and renders no entry rows" do
      # technology_requirements has no schema default, so an untouched changeset
      # yields nil rather than [] — the `|| []` guard in the component.
      html = render_sections(%{}, %{"technology_requirements" => true})

      assert html =~ "add-technology"
      refute html =~ "remove-technology"
    end

    test "always emits the empty hidden input, so clearing the last row submits an empty list" do
      # Without this the browser sends no key at all for an emptied list and the
      # change would be silently dropped rather than persisted as [].
      for {field, name, _add, _remove} <- @sections do
        html = render_sections(%{field => []}, %{name => true})

        assert html =~ ~s(<input type="hidden" name="task[#{name}][]" value=""),
               "#{name} must emit the empty hidden input"
      end
    end

    test "entry values are HTML-escaped rather than injected as markup" do
      html =
        render_sections(
          %{pitfalls: [~s[<script>alert("xss")</script>]]},
          %{"pitfalls" => true}
        )

      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "event targeting" do
    test "add and remove buttons target the passed-in component" do
      html = render_sections(%{pitfalls: ["a"]}, %{"pitfalls" => true}, "#task-form")

      assert html =~ ~s(phx-target="#task-form")
      # Both the add and the remove button carry the target.
      assert length(Regex.scan(~r/phx-target="#task-form"/, html)) == 2
    end

    test "each section emits its own add and remove event names" do
      html = render_sections(%{}, all_visible())

      for {field, name, add_event, remove_event} <- @sections do
        assert html =~ ~s(phx-click="#{add_event}")

        with_entry = render_sections(%{field => ["x"]}, %{name => true})
        assert with_entry =~ ~s(phx-click="#{remove_event}")
      end
    end
  end

  describe "error rendering" do
    test "surfaces a changeset error on the section's own field" do
      changeset =
        %Task{}
        |> Task.changeset(%{pitfalls: ["p"]})
        |> Ecto.Changeset.add_error(:pitfalls, "is too long")
        |> Map.put(:action, :validate)

      assigns = %{
        f: to_form(changeset, as: :task),
        field_visibility: %{"pitfalls" => true},
        myself: nil
      }

      html =
        rendered_to_string(~H"""
        <GuidanceSections.guidance_sections
          f={@f}
          field_visibility={@field_visibility}
          myself={@myself}
        />
        """)

      assert html =~ "is too long"
    end
  end
end
