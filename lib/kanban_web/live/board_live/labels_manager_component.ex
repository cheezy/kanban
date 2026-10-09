defmodule KanbanWeb.BoardLive.LabelsManagerComponent do
  @moduledoc """
  The Labels section of the board settings modal (W2233).

  Lists the board's labels as `KanbanWeb.LabelChip` chips. Users with owner or
  modify access can also add, rename, recolor and delete labels; changes save
  immediately, and changeset errors render inline next to the field.

  Authorization lives in `Kanban.Labels`: every mutation goes through the
  context, which re-checks the caller's board access and returns
  `{:error, :unauthorized}` for anyone else. `:can_modify` only decides which
  controls render (and gates the UI-only events), so a forged event from a
  read-only member is refused server-side, not merely hidden. Label ids from
  the client are only ever resolved against a fresh load of this board's own
  labels, so a label on another board can never be targeted, and one deleted
  in another session gets a "no longer exists" flash rather than a crash.

  A live component's own flash never reaches the page, so denials and label
  changes are sent to the parent LiveView, which applies them with
  `apply_parent_message/2`.
  """
  use KanbanWeb, :live_component

  alias Kanban.Labels
  alias Kanban.Labels.Label
  alias KanbanWeb.BoardLive.FilterActions
  alias KanbanWeb.LabelChip

  @impl true
  def update(%{board: board, current_scope: scope} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:can_modify, fn -> false end)
     |> assign(:labels, Labels.list_viewable_labels(scope, board))
     |> assign_new(:editing_id, fn -> nil end)
     |> assign_new(:edit_form, fn -> nil end)
     |> assign_new(:new_form, fn -> new_form() end)
     |> assign_new(:new_form_rev, fn -> 0 end)}
  end

  @doc """
  Applies a message this component sent to its parent LiveView: a label
  change reloads the board filter bar's options, and a flash is shown.
  """
  def apply_parent_message(socket, :labels_changed) do
    FilterActions.reload_options(socket, socket.assigns.board)
  end

  def apply_parent_message(socket, {:flash, kind, message}) when kind in [:info, :error] do
    Phoenix.LiveView.put_flash(socket, kind, message)
  end

  @impl true
  def handle_event("validate", params, %{assigns: %{can_modify: true}} = socket) do
    {:noreply, validate(socket, params)}
  end

  @impl true
  def handle_event("create", %{"label" => params}, socket) do
    %{current_scope: scope, board: board} = socket.assigns

    case Labels.create_label(scope, board, params) do
      {:ok, _label} ->
        notify_parent(:labels_changed)
        {:noreply, reset_new_form(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :new_form, to_form(changeset))}

      {:error, :unauthorized} ->
        deny(socket)
    end
  end

  @impl true
  def handle_event("edit", %{"id" => id}, %{assigns: %{can_modify: true}} = socket) do
    with_label(socket, id, fn socket, label ->
      {:noreply,
       socket
       |> assign(:editing_id, label.id)
       |> assign(:edit_form, to_form(Labels.change_label(label)))}
    end)
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply, cancel_edit(socket)}
  end

  @impl true
  def handle_event("update", %{"label_id" => id, "label" => params}, socket) do
    with_label(socket, id, fn socket, label ->
      case Labels.update_label(socket.assigns.current_scope, label, params) do
        {:ok, _label} ->
          notify_parent(:labels_changed)
          {:noreply, socket |> cancel_edit() |> reload_labels()}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, edit_failed(socket, changeset)}

        {:error, :unauthorized} ->
          deny(socket)
      end
    end)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    with_label(socket, id, fn socket, label ->
      case Labels.delete_label(socket.assigns.current_scope, label) do
        {:ok, _label} ->
          notify_parent(:labels_changed)
          {:noreply, socket |> cancel_edit() |> reload_labels()}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, label_gone(socket)}

        {:error, :unauthorized} ->
          deny(socket)
      end
    end)
  end

  # Any other event — a UI-only event from a user without modify access, or a
  # malformed one — is refused rather than crashing the page.
  @impl true
  def handle_event(_event, _params, socket), do: deny(socket)

  defp validate(socket, %{"label_id" => id, "label" => params}) do
    case find_label(socket, id) do
      %Label{} = label ->
        changeset = label |> Labels.change_label(params) |> Map.put(:action, :validate)
        assign(socket, :edit_form, to_form(changeset))

      nil ->
        socket
    end
  end

  defp validate(socket, %{"label" => params}) do
    changeset =
      %Label{color: :gray} |> Labels.change_label(params) |> Map.put(:action, :validate)

    assign(socket, :new_form, to_form(changeset))
  end

  defp validate(socket, _params), do: socket

  # Resolves the id against a fresh load, so a label deleted in another session
  # since this list rendered takes the not-found path instead of reaching the
  # database as a stale struct. The callback gets the reloaded socket, so the
  # fresh list is the one rendered on every path.
  defp with_label(socket, id, fun) do
    socket = reload_labels(socket)

    case find_label(socket, id) do
      %Label{} = label -> fun.(socket, label)
      nil -> {:noreply, label_gone(socket)}
    end
  end

  # A changeset error on :id means the label was deleted between the fresh load
  # and the write (Kanban.Labels passes stale_error_field: :id).
  defp edit_failed(socket, %Ecto.Changeset{errors: errors} = changeset) do
    if Keyword.has_key?(errors, :id),
      do: label_gone(socket),
      else: assign(socket, :edit_form, to_form(changeset))
  end

  defp label_gone(socket) do
    notify_parent({:flash, :error, gettext("That label no longer exists")})
    socket |> cancel_edit() |> reload_labels()
  end

  defp find_label(socket, id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> Enum.find(socket.assigns.labels, &(&1.id == int))
      _ -> nil
    end
  end

  defp find_label(socket, id) when is_integer(id), do: find_label(socket, Integer.to_string(id))
  defp find_label(_socket, _id), do: nil

  defp deny(socket) do
    notify_parent(
      {:flash, :error, gettext("You do not have permission to manage labels on this board")}
    )

    {:noreply, socket}
  end

  defp reload_labels(socket) do
    %{current_scope: scope, board: board} = socket.assigns
    assign(socket, :labels, Labels.list_viewable_labels(scope, board))
  end

  # Bumping the revision gives the form a new id, so the client drops the
  # values it kept for the focused inputs and the cleared form shows.
  defp reset_new_form(socket) do
    socket
    |> reload_labels()
    |> assign(:new_form, new_form())
    |> update(:new_form_rev, &(&1 + 1))
  end

  defp cancel_edit(socket), do: assign(socket, editing_id: nil, edit_form: nil)

  defp new_form, do: to_form(Labels.change_label(%Label{color: :gray}))

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={"board-labels-#{@board.id}"}
      data-labels-manager
      style={[
        "background: var(--surface); border: 1px solid var(--line);",
        "border-radius: 10px; padding: 14px 16px; margin-top: 14px;"
      ]}
    >
      <h3 style="margin: 0; font-size: 13px; font-weight: 600; color: var(--ink); letter-spacing: -0.015em;">
        {gettext("Labels")}
      </h3>
      <p style="margin: 4px 0 12px; font-size: 11.5px; color: var(--ink-3); line-height: 1.5;">
        {gettext("Labels tag and filter tasks. Changes save immediately.")}
      </p>

      <p
        :if={@labels == []}
        data-labels-empty
        style="margin: 0 0 12px; font-size: 12px; color: var(--ink-3);"
      >
        {if @can_modify,
          do: gettext("No labels yet. Add one below to start tagging tasks."),
          else: gettext("This board has no labels yet.")}
      </p>

      <div :if={@labels != []} style="display: flex; flex-direction: column; gap: 6px;">
        <div
          :for={label <- @labels}
          id={"label-row-#{label.id}"}
          style={[
            "display: flex; align-items: center; gap: 10px; min-width: 0;",
            "padding: 6px 10px; border-radius: 8px;",
            "background: var(--surface); border: 1px solid var(--line);"
          ]}
        >
          <%= if @editing_id == label.id do %>
            <.label_fields
              form={@edit_form}
              id={"label-edit-form-#{label.id}"}
              submit="update"
              myself={@myself}
              label_id={label.id}
              submit_text={gettext("Save")}
            />
            <button type="button" phx-click="cancel_edit" phx-target={@myself} style={link_button()}>
              {gettext("Cancel")}
            </button>
          <% else %>
            <div style="flex: 1; min-width: 0; display: flex;">
              <LabelChip.label_chip label={label} />
            </div>
            <button
              :if={@can_modify}
              type="button"
              id={"label-edit-#{label.id}"}
              phx-click="edit"
              phx-value-id={label.id}
              phx-target={@myself}
              aria-label={gettext("Rename or recolor %{name}", name: label.name)}
              style={link_button()}
            >
              {gettext("Edit")}
            </button>
            <button
              :if={@can_modify}
              type="button"
              id={"label-delete-#{label.id}"}
              phx-click="delete"
              phx-value-id={label.id}
              phx-target={@myself}
              data-confirm={
                gettext("Delete the label \"%{name}\"? It will be removed from every task.",
                  name: label.name
                )
              }
              aria-label={gettext("Delete label %{name}", name: label.name)}
              style={[link_button(), "color: var(--st-blocked);"]}
            >
              {gettext("Delete")}
            </button>
          <% end %>
        </div>
      </div>

      <div
        :if={@can_modify}
        style="margin-top: 12px; padding-top: 12px; border-top: 1px solid var(--line);"
      >
        <.label_fields
          form={@new_form}
          id={"label-new-form-#{@new_form_rev}"}
          submit="create"
          myself={@myself}
          submit_text={gettext("Add label")}
        />
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :submit, :string, required: true
  attr :myself, :any, required: true
  attr :submit_text, :string, required: true
  attr :label_id, :integer, default: nil

  defp label_fields(assigns) do
    ~H"""
    <.form
      for={@form}
      id={@id}
      phx-change="validate"
      phx-submit={@submit}
      phx-target={@myself}
      style="flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 6px;"
    >
      <input :if={@label_id} type="hidden" name="label_id" value={@label_id} />
      <div style="display: flex; flex-wrap: wrap; align-items: center; gap: 8px;">
        <input
          type="text"
          name={@form[:name].name}
          id={"#{@id}-name"}
          value={Phoenix.HTML.Form.normalize_value("text", @form[:name].value)}
          maxlength="40"
          placeholder={gettext("Label name")}
          aria-label={gettext("Label name")}
          style={[
            "flex: 1; min-width: 140px; height: 30px; padding: 0 10px; border-radius: 5px;",
            "background: var(--surface); color: var(--ink);",
            "border: 1px solid var(--line-strong); font-size: 12.5px;"
          ]}
        />
        <select
          name={@form[:color].name}
          id={"#{@id}-color"}
          aria-label={gettext("Color")}
          style={[
            "height: 30px; padding: 0 8px; border-radius: 5px;",
            "background: var(--surface); color: var(--ink);",
            "border: 1px solid var(--line-strong); font-size: 12.5px;"
          ]}
        >
          <option
            :for={color <- Label.colors()}
            value={color}
            selected={to_string(@form[:color].value) == to_string(color)}
          >
            {LabelChip.color_label(color)}
          </option>
        </select>
        <LabelChip.label_chip
          :if={present?(@form[:name].value)}
          name={@form[:name].value}
          color={@form[:color].value}
        />
        <button
          type="submit"
          style={[
            "height: 30px; padding: 0 12px; border-radius: 5px; border: none;",
            "background: var(--ink); color: var(--color-base-100);",
            "font-size: 12px; font-weight: 500; cursor: pointer;"
          ]}
        >
          {@submit_text}
        </button>
      </div>
      <.field_errors field={@form[:name]} />
      <.field_errors field={@form[:color]} />
    </.form>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp field_errors(assigns) do
    ~H"""
    <.error :for={msg <- errors_for(@field)}>{msg}</.error>
    """
  end

  defp errors_for(field) do
    if used_input?(field), do: Enum.map(field.errors, &translate_error/1), else: []
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp link_button do
    [
      "padding: 4px 8px; border-radius: 4px; background: transparent; border: none;",
      "cursor: pointer; font-size: 11.5px; font-weight: 500; color: var(--ink-2);"
    ]
  end
end
