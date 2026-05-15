defmodule KanbanWeb.BoardLive.SettingsFormComponent do
  @moduledoc """
  Modal-friendly board settings form. Handles editing of the board's
  name, description, public-readable flag, and per-board field
  visibility toggles. Mounted as a `live_component` from
  `KanbanWeb.BoardLive.Show` when the `:board_settings` live action
  is active.
  """
  use KanbanWeb, :live_component

  alias Kanban.Boards
  alias Kanban.Boards.Board

  @impl true
  def update(%{board: board, current_scope: scope} = assigns, socket) do
    field_visibility = board.field_visibility || %{}

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(Boards.change_board(board)))
     |> assign(:field_visibility, field_visibility)
     |> assign(:scope, scope)}
  end

  @impl true
  def handle_event("validate", %{"board" => board_params}, socket) do
    changeset =
      socket.assigns.board
      |> Boards.change_board(board_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"board" => board_params}, socket) do
    case Boards.update_board(socket.assigns.board, board_params, socket.assigns.scope.user) do
      {:ok, board} ->
        notify_parent({:saved, board})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Board updated successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("toggle_field", %{"field" => field_name}, socket) do
    if field_name in Board.toggleable_fields() do
      perform_toggle(socket, field_name)
    else
      {:noreply, put_flash(socket, :error, gettext("Invalid field name"))}
    end
  end

  defp perform_toggle(socket, field_name) do
    new_visibility = build_toggled_visibility(socket.assigns.field_visibility, field_name)

    case Boards.update_field_visibility(
           socket.assigns.board,
           new_visibility,
           socket.assigns.scope.user
         ) do
      {:ok, updated_board} ->
        notify_parent({:field_visibility_updated, updated_board.field_visibility})
        {:noreply, assign(socket, :field_visibility, updated_board.field_visibility)}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only board owners can change field visibility"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update field visibility"))}
    end
  end

  defp build_toggled_visibility(current, field_name) do
    defaults = Map.new(Board.toggleable_fields(), fn key -> {key, false} end)
    complete = Map.merge(defaults, current)
    Map.put(complete, field_name, !Map.get(complete, field_name, false))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div class="stride-screen">
      <.form
        :let={f}
        for={@form}
        id={"board-settings-form-#{@board.id}"}
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
        <section style={[
          "background: var(--surface); border: 1px solid var(--line);",
          "border-radius: 10px; padding: 14px 16px; margin-bottom: 14px;"
        ]}>
          <.stride_field label={gettext("Name")}>
            <.stride_input field={f[:name]} type="text" />
          </.stride_field>

          <.stride_field label={gettext("Description")} style="margin-top: 12px;">
            <.stride_input field={f[:description]} type="textarea" />
          </.stride_field>

          <label style={[
            "display: flex; align-items: flex-start; gap: 10px;",
            "margin-top: 14px; padding: 10px 12px; border-radius: 6px;",
            "background: var(--surface-sunken); cursor: pointer;"
          ]}>
            <input
              type="checkbox"
              name={f[:read_only].name}
              checked={Phoenix.HTML.Form.normalize_value("checkbox", f[:read_only].value)}
              style="margin-top: 2px;"
            />
            <div style="flex: 1; min-width: 0;">
              <div style="font-size: 12.5px; font-weight: 500; color: var(--ink);">
                {gettext("Make board publicly readable")}
              </div>
              <p style="margin: 4px 0 0; font-size: 11.5px; color: var(--ink-3); line-height: 1.5;">
                {gettext(
                  "When enabled, anyone with the direct link can view this board (read-only access). Members retain their assigned permissions."
                )}
              </p>
            </div>
          </label>
        </section>

        <section style={[
          "background: var(--surface); border: 1px solid var(--line);",
          "border-radius: 10px; padding: 14px 16px; margin-bottom: 14px;"
        ]}>
          <div style="margin-bottom: 4px;">
            <h3 style="margin: 0; font-size: 13px; font-weight: 600; color: var(--ink); letter-spacing: -0.015em;">
              {gettext("Field visibility")}
            </h3>
            <p style="margin: 4px 0 12px; font-size: 11.5px; color: var(--ink-3); line-height: 1.5;">
              {gettext("Control which task fields are visible on the board.")}
            </p>
          </div>
          <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 4px;">
            <.field_toggle
              :for={{field, label} <- toggleable_fields_with_labels()}
              myself={@myself}
              field={field}
              label={label}
              checked={Map.get(@field_visibility, field, false)}
            />
          </div>
        </section>

        <div style="display: flex; align-items: center; gap: 12px; justify-content: flex-end;">
          <.link
            patch={@patch}
            style="font-size: 12.5px; color: var(--ink-2); text-decoration: underline; text-underline-offset: 2px;"
          >
            {gettext("Cancel")}
          </.link>
          <button
            type="submit"
            phx-disable-with={gettext("Saving...")}
            style={[
              "padding: 6px 12px; border-radius: 5px; border: none;",
              "background: var(--ink); color: white;",
              "font-size: 12px; font-weight: 500; cursor: pointer;",
              "box-shadow: 0 1px 0 rgba(255,255,255,.1) inset, 0 1px 2px rgba(0,0,0,.2);"
            ]}
          >
            {gettext("Save")}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :style, :string, default: ""
  slot :inner_block, required: true

  defp stride_field(assigns) do
    ~H"""
    <label style={"display: flex; flex-direction: column; gap: 5px; #{@style}"}>
      <span
        class="ucase"
        style="font-size: 10.5px; font-weight: 500; color: var(--ink-3); letter-spacing: 0.04em;"
      >
        {@label}
      </span>
      {render_slot(@inner_block)}
    </label>
    """
  end

  attr :field, :map, required: true
  attr :type, :string, default: "text"

  defp stride_input(%{type: "textarea"} = assigns) do
    ~H"""
    <textarea
      name={@field.name}
      id={@field.id}
      rows="3"
      style={[
        "padding: 8px 10px; border-radius: 5px;",
        "background: var(--surface); color: var(--ink);",
        "border: 1px solid var(--line-strong);",
        "font-size: 12.5px; line-height: 1.5; resize: vertical; min-height: 64px;"
      ]}
    ><%= Phoenix.HTML.Form.normalize_value("textarea", @field.value) %></textarea>
    """
  end

  defp stride_input(assigns) do
    ~H"""
    <input
      type={@type}
      name={@field.name}
      id={@field.id}
      value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
      style={[
        "height: 32px; padding: 0 10px; border-radius: 5px;",
        "background: var(--surface); color: var(--ink);",
        "border: 1px solid var(--line-strong);",
        "font-size: 12.5px;"
      ]}
    />
    """
  end

  attr :myself, :any, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, required: true

  defp field_toggle(assigns) do
    ~H"""
    <label style={[
      "display: flex; align-items: center; gap: 8px;",
      "padding: 6px 8px; border-radius: 4px;",
      "font-size: 12px; color: var(--ink-2); cursor: pointer;"
    ]}>
      <input
        type="checkbox"
        phx-click="toggle_field"
        phx-value-field={@field}
        phx-target={@myself}
        checked={@checked}
      />
      {@label}
    </label>
    """
  end

  defp toggleable_fields_with_labels do
    [
      {"acceptance_criteria", gettext("Acceptance Criteria")},
      {"complexity", gettext("Complexity & Scope")},
      {"context", gettext("Context (Why/What/Where)")},
      {"key_files", gettext("Key Files")},
      {"verification_steps", gettext("Verification Steps")},
      {"technical_notes", gettext("Technical Notes")},
      {"observability", gettext("Observability")},
      {"error_handling", gettext("Error Handling")},
      {"technology_requirements", gettext("Technology Requirements")},
      {"pitfalls", gettext("Pitfalls")},
      {"out_of_scope", gettext("Out of Scope")},
      {"required_capabilities", gettext("Required Agent Capabilities")},
      {"security_considerations", gettext("Security Considerations")},
      {"testing_strategy", gettext("Testing Strategy")},
      {"integration_points", gettext("Integration Points")}
    ]
  end
end
