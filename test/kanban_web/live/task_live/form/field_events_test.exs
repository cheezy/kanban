defmodule KanbanWeb.TaskLive.Form.FieldEventsTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias KanbanWeb.TaskLive.Form.FieldEvents
  alias KanbanWeb.TaskLive.FormComponent

  describe "rows/1" do
    test "returns a list as given" do
      assert FieldEvents.rows([]) == []
      assert FieldEvents.rows(["a", "b"]) == ["a", "b"]
    end

    test "reads a bare string, a valid stored shape, as one row" do
      assert FieldEvents.rows("Test each function") == ["Test each function"]
      assert FieldEvents.rows("") == [""]
    end

    test "reads every other value as no rows" do
      for value <- [nil, %{"0" => "x"}, 42, true, :atom] do
        assert FieldEvents.rows(value) == [], "#{inspect(value)} was not read as []"
      end
    end
  end

  describe "map_or_empty/1" do
    test "returns a plain map as given" do
      assert FieldEvents.map_or_empty(%{}) == %{}
      assert FieldEvents.map_or_empty(%{"unit_tests" => ["a"]}) == %{"unit_tests" => ["a"]}
    end

    test "reads every other value, structs included, as an empty map" do
      for value <- [nil, "abc", ["a"], 42, ~D[2026-10-20]] do
        assert FieldEvents.map_or_empty(value) == %{}, "#{inspect(value)} was not read as %{}"
      end
    end
  end

  # A crafted phx-change="validate" event can put any JSON value under a
  # testing_strategy / integration_points key; the :map cast keeps it. (A bare
  # string is a valid stored shape and is one row; see the string tests.)
  @crafted_values [%{"0" => "a map"}, 42, true]

  @map_array_events [
    {"unit-test", :testing_strategy, "unit_tests"},
    {"integration-test", :testing_strategy, "integration_tests"},
    {"manual-test", :testing_strategy, "manual_tests"},
    {"telemetry-event", :integration_points, "telemetry_events"},
    {"pubsub-broadcast", :integration_points, "pubsub_broadcasts"},
    {"phoenix-channel", :integration_points, "phoenix_channels"},
    {"external-api", :integration_points, "external_apis"}
  ]

  describe "map-array add/remove events with a crafted non-list value" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Stored title",
          testing_strategy: %{"unit_tests" => ["Stored unit test"], "edge_cases" => ["Kept"]}
        })

      %{socket: form_socket(user, board, column, task)}
    end

    test "remove-* leaves the form unchanged", %{socket: socket} do
      for {suffix, field, key} <- @map_array_events, value <- @crafted_values do
        crafted = craft(socket, field, key, value)

        assert {:noreply, ^crafted} =
                 FormComponent.handle_event("remove-#{suffix}", %{"index" => "0"}, crafted),
               "remove-#{suffix} over #{inspect(value)} changed the form"

        assert field_value(crafted, :title) == "Typed title"
      end
    end

    test "add-* reads the value as an empty list and keeps the other keys and fields",
         %{socket: socket} do
      for {suffix, field, key} <- @map_array_events, value <- @crafted_values do
        crafted = craft(socket, field, key, value)

        {:noreply, updated} = FormComponent.handle_event("add-#{suffix}", %{}, crafted)

        assert field_value(updated, field)[key] == [""],
               "add-#{suffix} over #{inspect(value)} gave #{inspect(field_value(updated, field)[key])}"

        assert field_value(updated, :title) == "Typed title"

        if field == :testing_strategy and key != "unit_tests" do
          assert field_value(updated, :testing_strategy)["unit_tests"] == ["Stored unit test"]
        end
      end
    end

    test "a bare string is one row: add keeps it, remove 0 removes it", %{socket: socket} do
      for {suffix, field, key} <- @map_array_events do
        crafted = craft(socket, field, key, "Test each function")

        {:noreply, added} = FormComponent.handle_event("add-#{suffix}", %{}, crafted)
        assert field_value(added, field)[key] == ["Test each function", ""]

        {:noreply, removed} =
          FormComponent.handle_event("remove-#{suffix}", %{"index" => "0"}, crafted)

        assert field_value(removed, field)[key] == []
        assert field_value(removed, :title) == "Typed title"

        assert {:noreply, ^crafted} =
                 FormComponent.handle_event("remove-#{suffix}", %{"index" => "1"}, crafted)
      end
    end

    test "a real list still gains and loses rows", %{socket: socket} do
      {:noreply, added} = FormComponent.handle_event("add-unit-test", %{}, socket)
      assert field_value(added, :testing_strategy)["unit_tests"] == ["Stored unit test", ""]

      {:noreply, removed} =
        FormComponent.handle_event("remove-unit-test", %{"index" => "0"}, added)

      assert field_value(removed, :testing_strategy)["unit_tests"] == [""]
      assert field_value(removed, :testing_strategy)["edge_cases"] == ["Kept"]
    end

    test "an index past the end of a real list changes nothing", %{socket: socket} do
      assert {:noreply, ^socket} =
               FormComponent.handle_event("remove-unit-test", %{"index" => "1"}, socket)

      assert {:noreply, ^socket} =
               FormComponent.handle_event("remove-pitfall", %{"index" => "0"}, socket)
    end
  end

  describe "crafted map-array values in the live edit form" do
    setup :register_and_log_in_user

    test "a stored bare string renders as one row whose Remove button removes it",
         %{conn: conn, user: user} do
      board =
        board_fixture(user, %{
          field_visibility: %{"testing_strategy" => true, "integration_points" => true}
        })

      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          testing_strategy: %{"unit_tests" => "Stored string strategy"},
          integration_points: %{"external_apis" => "Stored string API"}
        })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      assert render(view) =~ "Stored string strategy"
      assert render(view) =~ "Stored string API"

      for event <- ~w[remove-unit-test remove-external-api] do
        view
        |> element(~s(#task-form button[phx-click="#{event}"][phx-value-index="0"]))
        |> render_click()
      end

      html = render(view)
      refute html =~ "Stored string strategy"
      refute html =~ "Stored string API"
      refute has_element?(view, ~s(#task-form button[phx-click="remove-unit-test"]))
      refute has_element?(view, ~s(#task-form button[phx-click="remove-external-api"]))
    end

    test "the form stays alive and keeps its rows", %{conn: conn, user: user} do
      board =
        board_fixture(user, %{
          field_visibility: %{"testing_strategy" => true, "integration_points" => true}
        })

      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Stored title",
          testing_strategy: %{"unit_tests" => ["Stored unit test"]}
        })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      view
      |> element("#task-form")
      |> render_change(%{
        "task" => %{
          "title" => "Typed title",
          "testing_strategy" => %{"integration_tests" => "not a list"},
          "integration_points" => %{"external_apis" => %{"0" => "a map"}}
        }
      })

      # The string renders as one row, and its Remove button removes it.
      view
      |> element(~s(#task-form button[phx-click="remove-integration-test"][phx-value-index="0"]))
      |> render_click()

      refute render(view) =~ "not a list"

      for event <- ~w[add-integration-test add-external-api] do
        view |> element(~s(#task-form button[phx-click="#{event}"])) |> render_click()
      end

      assert Process.alive?(view.pid)
      html = render(view)
      assert html =~ "Typed title"
      assert html =~ "Stored unit test"
      assert html =~ ~s(name="task[testing_strategy][integration_tests][]")
    end
  end

  defp form_socket(user, board, column, task) do
    {:ok, socket} =
      FormComponent.update(
        %{
          current_scope: %{user: user},
          task: task,
          board: board,
          action: :edit_task,
          column_id: column.id,
          patch: "/boards/#{board.id}"
        },
        %Phoenix.LiveView.Socket{}
      )

    socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

    {:noreply, socket} =
      FormComponent.handle_event("validate", %{"task" => %{"title" => "Typed title"}}, socket)

    socket
  end

  # Puts `value` under `key` of the map `field` as a crafted validate event would.
  defp craft(socket, field, key, value) do
    map = Map.put(field_value(socket, field) || %{}, key, value)
    changeset = Ecto.Changeset.put_change(socket.assigns.form.source, field, map)

    Phoenix.Component.assign(socket, :form, Phoenix.Component.to_form(changeset))
  end

  defp field_value(socket, field), do: Ecto.Changeset.get_field(socket.assigns.form.source, field)
end
