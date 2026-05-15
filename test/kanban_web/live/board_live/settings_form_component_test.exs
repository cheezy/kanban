defmodule KanbanWeb.BoardLive.SettingsFormComponentTest do
  use KanbanWeb.ConnCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias KanbanWeb.BoardLive.SettingsFormComponent

  defp setup_owner(_) do
    user = user_fixture()
    board = board_fixture(user, %{name: "Old name", description: "Old description"})
    scope = Scope.for_user(user)
    %{user: user, board: board, scope: scope}
  end

  describe "update/2" do
    setup [:setup_owner]

    test "initializes the form with the board's current values", %{board: board, scope: scope} do
      {:ok, socket} =
        SettingsFormComponent.update(
          %{
            id: "board-settings-#{board.id}",
            board: board,
            current_scope: scope,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      assert socket.assigns.board == board
      assert socket.assigns.scope == scope
      assert socket.assigns.form
      assert socket.assigns.form.source.data == board
      assert is_map(socket.assigns.field_visibility)
    end

    test "carries field_visibility through from the board", %{user: user, board: board, scope: scope} do
      vis = %{"acceptance_criteria" => true, "complexity" => false}
      {:ok, board} = Boards.update_field_visibility(board, vis, user)

      {:ok, socket} =
        SettingsFormComponent.update(
          %{
            id: "board-settings-#{board.id}",
            board: board,
            current_scope: scope,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      assert socket.assigns.field_visibility == vis
    end
  end

  describe "render/1" do
    setup [:setup_owner]

    test "renders the name and description fields populated from the board", %{
      board: board,
      scope: scope
    } do
      html =
        render_component(
          &SettingsFormComponent.render/1,
          assign_for_render(board, scope)
        )

      assert html =~ "Name"
      assert html =~ "Description"
      assert html =~ "Old name"
      assert html =~ "Old description"
    end

    test "renders the public-readable toggle", %{board: board, scope: scope} do
      html =
        render_component(
          &SettingsFormComponent.render/1,
          assign_for_render(board, scope)
        )

      assert html =~ "Make board publicly readable"
    end

    test "renders every toggleable field as a checkbox row", %{board: board, scope: scope} do
      html =
        render_component(
          &SettingsFormComponent.render/1,
          assign_for_render(board, scope)
        )

      # & is HTML-escaped in the rendered markup, so match a portion that
      # avoids the entity-encoding for the &-bearing labels.
      labels = [
        "Acceptance Criteria",
        "Complexity",
        "Context (Why/What/Where)",
        "Key Files",
        "Verification Steps",
        "Technical Notes",
        "Observability",
        "Error Handling",
        "Technology Requirements",
        "Pitfalls",
        "Out of Scope",
        "Required Agent Capabilities",
        "Security Considerations",
        "Testing Strategy",
        "Integration Points"
      ]

      for label <- labels do
        assert html =~ label, "expected field-visibility row #{label}"
      end
    end

    test "Save button and Cancel link point at @patch", %{board: board, scope: scope} do
      html =
        render_component(
          &SettingsFormComponent.render/1,
          assign_for_render(board, scope)
        )

      assert html =~ ~s|href="/boards/#{board.id}"|
      assert html =~ "Save"
      assert html =~ "Cancel"
    end
  end

  describe "handle_event validate" do
    setup [:setup_owner]

    test "produces a validating form when name is blank", %{board: board, scope: scope} do
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        SettingsFormComponent.handle_event("validate", %{"board" => %{"name" => ""}}, socket)

      assert socket.assigns.form.source.action == :validate
      refute socket.assigns.form.source.valid?
    end

    test "carries valid params through to the form", %{board: board, scope: scope} do
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        SettingsFormComponent.handle_event(
          "validate",
          %{"board" => %{"name" => "New title"}},
          socket
        )

      assert socket.assigns.form.params["name"] == "New title"
    end
  end

  describe "handle_event save" do
    setup [:setup_owner]

    test "updates the board, flashes success, patches back, notifies parent",
         %{board: board, scope: scope} do
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        SettingsFormComponent.handle_event(
          "save",
          %{"board" => %{"name" => "Updated name"}},
          socket
        )

      assert socket.assigns.flash["info"] == "Board updated successfully"
      assert socket.redirected == {:live, :patch, %{kind: :push, to: "/boards/#{board.id}"}}
      assert {:ok, %{name: "Updated name"}} = Boards.get_board(board.id, scope.user)

      assert_received {SettingsFormComponent, {:saved, %{name: "Updated name"}}}
    end

    test "returns invalid form on changeset error", %{board: board, scope: scope} do
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        SettingsFormComponent.handle_event("save", %{"board" => %{"name" => ""}}, socket)

      refute socket.assigns.form.source.valid?
      refute_received {SettingsFormComponent, {:saved, _}}
    end
  end

  describe "handle_event toggle_field" do
    setup [:setup_owner]

    test "flips a toggleable field, notifies parent, and updates the assign",
         %{board: board, scope: scope} do
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        SettingsFormComponent.handle_event(
          "toggle_field",
          %{"field" => "complexity"},
          socket
        )

      assert socket.assigns.field_visibility["complexity"] == true
      assert_received {SettingsFormComponent, {:field_visibility_updated, %{}}}
    end

    test "rejects field names that are not in the allow-list",
         %{board: board, scope: scope} do
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        SettingsFormComponent.handle_event(
          "toggle_field",
          %{"field" => "not_a_real_field"},
          socket
        )

      assert socket.assigns.flash["error"] == "Invalid field name"
      refute_received {SettingsFormComponent, {:field_visibility_updated, _}}
    end

    test "returns an unauthorized flash when the scope user is not the owner",
         %{board: board} do
      stranger = user_fixture()
      stranger_scope = Scope.for_user(stranger)
      socket = build_update_socket(board, stranger_scope)

      {:noreply, socket} =
        SettingsFormComponent.handle_event(
          "toggle_field",
          %{"field" => "complexity"},
          socket
        )

      assert socket.assigns.flash["error"] == "Only board owners can change field visibility"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_update_socket(board, scope) do
    base = %{%Phoenix.LiveView.Socket{} | assigns: %{flash: %{}, __changed__: %{}}}

    {:ok, socket} =
      SettingsFormComponent.update(
        %{
          id: "board-settings-#{board.id}",
          board: board,
          current_scope: scope,
          patch: "/boards/#{board.id}"
        },
        base
      )

    socket
  end

  # Helper: build the assigns map render_component expects after running update/2.
  defp assign_for_render(board, scope) do
    form = to_form(Boards.change_board(board))

    %{
      id: "board-settings-#{board.id}",
      board: board,
      scope: scope,
      current_scope: scope,
      patch: "/boards/#{board.id}",
      form: form,
      field_visibility: board.field_visibility || %{},
      myself: %Phoenix.LiveComponent.CID{cid: 1}
    }
  end
end
