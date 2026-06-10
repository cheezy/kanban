defmodule KanbanWeb.BoardLive.FieldVisibility do
  @moduledoc """
  Shared field-visibility toggle flow — the W401 allow-list check plus the
  visibility update — used by `KanbanWeb.BoardLive.Form` and
  `KanbanWeb.BoardLive.SettingsFormComponent`.

  Takes the socket plus the current user as an explicit argument and
  requires the socket assigns `:board` and `:field_visibility`. The
  optional `on_success` callback receives the updated visibility map so a
  LiveComponent caller can notify its parent; the default is a no-op.
  """
  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kanban.Boards
  alias Kanban.Boards.Board

  @doc """
  Toggles the named field in the board's visibility map, rejecting any
  field name not on the canonical allow-list.
  """
  def toggle_field(socket, current_user, field_name, on_success \\ fn _visibility -> :ok end) do
    # W401: reject any client-supplied "field" name that is not on the
    # canonical allow-list before it lands in the JSONB map.
    if field_name in Board.toggleable_fields() do
      perform_toggle(socket, current_user, field_name, on_success)
    else
      {:noreply, put_flash(socket, :error, gettext("Invalid field name"))}
    end
  end

  defp perform_toggle(socket, current_user, field_name, on_success) do
    board = socket.assigns.board
    new_visibility = build_toggled_visibility(socket.assigns.field_visibility, field_name)

    case Boards.update_field_visibility(board, new_visibility, current_user) do
      {:ok, updated_board} ->
        on_success.(updated_board.field_visibility)
        {:noreply, assign(socket, :field_visibility, updated_board.field_visibility)}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only board owners can change field visibility"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update field visibility"))}
    end
  end

  defp build_toggled_visibility(current_visibility, field_name) do
    # Build a complete visibility map (all allow-listed keys present with their
    # current value or false default) so we always pass a fully-populated map
    # into the changeset, then flip the toggled field.
    default_visibility = Map.new(Board.toggleable_fields(), fn key -> {key, false} end)
    complete_visibility = Map.merge(default_visibility, current_visibility)

    Map.put(complete_visibility, field_name, !Map.get(complete_visibility, field_name, false))
  end
end
