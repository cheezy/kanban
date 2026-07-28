defmodule KanbanWeb.TaskLive.Form.EmbedSectionsTest do
  @moduledoc """
  Unit tests for the task form's three embed repeaters — `key_files`,
  `verification_steps` and `behaviour_test_matrix`.

  Unlike the plain string-list sections, these render through `<.inputs_for>`,
  so each row carries indexed input names and a hidden `position`. Losing that
  hidden field is the failure mode worth guarding: the row would still render
  and still submit, but its ordering would silently reset on save.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.Form.EmbedSections
  alias KanbanWeb.TaskLive.Form.OptionBuilders

  # {form field name, add event, remove event}
  @embeds [
    {"key_files", "add-key-file", "remove-key-file"},
    {"verification_steps", "add-verification-step", "remove-verification-step"},
    {"behaviour_test_matrix", "add-behaviour-test-row", "remove-behaviour-test-row"}
  ]

  defp render_sections(task_attrs, visibility, myself \\ nil) do
    form =
      %Task{}
      |> Task.changeset(task_attrs)
      |> to_form(as: :task)

    assigns = %{f: form, field_visibility: visibility, myself: myself}

    rendered_to_string(~H"""
    <EmbedSections.embed_sections
      f={@f}
      field_visibility={@field_visibility}
      myself={@myself}
    />
    """)
  end

  defp all_visible, do: Map.new(@embeds, fn {name, _, _} -> {name, true} end)

  describe "visibility gating" do
    test "renders nothing at all when the visibility map is empty" do
      assert render_sections(%{}, %{}) |> String.trim() == ""
    end

    test "each embed is gated on its own field name, independently" do
      for {name, add_event, _remove} <- @embeds do
        html = render_sections(%{}, %{name => true})

        assert html =~ add_event

        others = Enum.reject(@embeds, fn {other, _, _} -> other == name end)

        for {_, other_add, _} <- others do
          refute html =~ other_add, "#{name} being visible must not render #{other_add}"
        end
      end
    end

    test "an explicit false hides the section just as an absent key does" do
      for {name, add_event, _remove} <- @embeds do
        refute render_sections(%{}, %{name => false}) =~ add_event
      end
    end

    test "a visible embed with no rows renders its add button but no remove buttons" do
      for {name, add_event, remove_event} <- @embeds do
        html = render_sections(%{}, %{name => true})

        assert html =~ add_event
        refute html =~ remove_event
      end
    end
  end

  describe "key_files rows" do
    test "renders one row per entry with indexed file_path and note inputs" do
      html =
        render_sections(
          %{
            key_files: [
              %{file_path: "lib/kanban/tasks.ex", note: "context module", position: 0},
              %{file_path: "test/kanban/tasks_test.exs", note: "coverage", position: 1}
            ]
          },
          %{"key_files" => true}
        )

      assert html =~ "lib/kanban/tasks.ex"
      assert html =~ "test/kanban/tasks_test.exs"
      assert html =~ "context module"
      assert html =~ ~s(name="task[key_files][0][file_path]")
      assert html =~ ~s(name="task[key_files][1][file_path]")
    end

    test "every row carries a hidden position input, so ordering survives a save" do
      html =
        render_sections(
          %{
            key_files: [
              %{file_path: "a.ex", note: "first", position: 0},
              %{file_path: "b.ex", note: "second", position: 1}
            ]
          },
          %{"key_files" => true}
        )

      assert html =~ ~s(name="task[key_files][0][position]")
      assert html =~ ~s(name="task[key_files][1][position]")
    end

    test "remove buttons carry the row's index" do
      html =
        render_sections(
          %{
            key_files: [
              %{file_path: "a.ex", position: 0},
              %{file_path: "b.ex", position: 1},
              %{file_path: "c.ex", position: 2}
            ]
          },
          %{"key_files" => true}
        )

      assert html =~ ~s(phx-value-index="0")
      assert html =~ ~s(phx-value-index="1")
      assert html =~ ~s(phx-value-index="2")
      refute html =~ ~s(phx-value-index="3")
    end

    test "file paths are HTML-escaped rather than injected as markup" do
      html =
        render_sections(
          %{key_files: [%{file_path: ~s[<script>x</script>], position: 0}]},
          %{"key_files" => true}
        )

      refute html =~ "<script>x"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "verification_steps rows" do
    test "renders the step_type select with exactly the command and manual options" do
      html =
        render_sections(
          %{verification_steps: [%{step_type: "command", step_text: "mix test", position: 0}]},
          %{"verification_steps" => true}
        )

      assert html =~ ~s(name="task[verification_steps][0][step_type]")
      assert html =~ ~s(value="command")
      assert html =~ ~s(value="manual")
    end

    test "marks the row's current step_type as selected" do
      html =
        render_sections(
          %{verification_steps: [%{step_type: "manual", step_text: "click it", position: 0}]},
          %{"verification_steps" => true}
        )

      assert html =~ ~s(<option selected value="manual">)
    end

    test "renders step_text and expected_result inputs carrying their values" do
      html =
        render_sections(
          %{
            verification_steps: [
              %{
                step_type: "command",
                step_text: "mix test path/to_test.exs",
                expected_result: "All tests pass",
                position: 0
              }
            ]
          },
          %{"verification_steps" => true}
        )

      assert html =~ "mix test path/to_test.exs"
      assert html =~ "All tests pass"
      assert html =~ ~s(name="task[verification_steps][0][position]")
    end
  end

  describe "behaviour_test_matrix rows" do
    @row %{
      category: "happy_path",
      behaviour: "a valid payload completes",
      test_name: "completes on valid payload",
      type: "unit",
      status: "planned",
      position: 0
    }

    test "renders the column header row only once rows exist" do
      empty = render_sections(%{}, %{"behaviour_test_matrix" => true})
      refute empty =~ "Behaviour to verify"

      with_row =
        render_sections(%{behaviour_test_matrix: [@row]}, %{"behaviour_test_matrix" => true})

      assert with_row =~ "Behaviour to verify"
      assert with_row =~ "Why not applicable?"
    end

    test "renders all six per-row fields plus the hidden position" do
      html = render_sections(%{behaviour_test_matrix: [@row]}, %{"behaviour_test_matrix" => true})

      for field <- ~w(category behaviour test_name type status na_reason position) do
        assert html =~ ~s(name="task[behaviour_test_matrix][0][#{field}]"),
               "row is missing the #{field} input"
      end
    end

    test "the category select offers every canonical category option" do
      html = render_sections(%{behaviour_test_matrix: [@row]}, %{"behaviour_test_matrix" => true})

      for {_label, value} <- OptionBuilders.build_behaviour_test_category_options() do
        assert html =~ ~s(value="#{value}"), "category option #{value} is missing"
      end
    end

    test "the status select offers every canonical status option" do
      html = render_sections(%{behaviour_test_matrix: [@row]}, %{"behaviour_test_matrix" => true})

      for {_label, value} <- OptionBuilders.build_behaviour_test_status_options() do
        assert html =~ ~s(value="#{value}"), "status option #{value} is missing"
      end
    end

    test "renders the guidance line explaining the not-applicable escape hatch" do
      html = render_sections(%{}, %{"behaviour_test_matrix" => true})

      assert html =~ "Cover every category at least once"
    end

    test "renders one indexed row per matrix entry" do
      rows = [
        @row,
        %{@row | category: "error_path", behaviour: "an invalid payload 422s", position: 1}
      ]

      html = render_sections(%{behaviour_test_matrix: rows}, %{"behaviour_test_matrix" => true})

      assert html =~ "a valid payload completes"
      assert html =~ "an invalid payload 422s"
      assert html =~ ~s(name="task[behaviour_test_matrix][1][behaviour]")
    end
  end

  describe "event targeting" do
    test "add and remove buttons target the passed-in component" do
      html =
        render_sections(
          %{key_files: [%{file_path: "a.ex", position: 0}]},
          %{"key_files" => true},
          "#task-form"
        )

      assert html =~ ~s(phx-target="#task-form")
      assert length(Regex.scan(~r/phx-target="#task-form"/, html)) == 2
    end

    test "all three embeds render together when all three are visible" do
      html = render_sections(%{}, all_visible())

      for {_name, add_event, _remove} <- @embeds do
        assert html =~ add_event
      end
    end
  end

  describe "error rendering" do
    test "surfaces a changeset error on the embed field itself" do
      changeset =
        %Task{}
        |> Task.changeset(%{})
        |> Ecto.Changeset.add_error(:behaviour_test_matrix, "must cover every category")
        |> Map.put(:action, :validate)

      assigns = %{
        f: to_form(changeset, as: :task),
        field_visibility: %{"behaviour_test_matrix" => true},
        myself: nil
      }

      html =
        rendered_to_string(~H"""
        <EmbedSections.embed_sections
          f={@f}
          field_visibility={@field_visibility}
          myself={@myself}
        />
        """)

      assert html =~ "must cover every category"
    end
  end
end
