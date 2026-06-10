defmodule KanbanWeb.FormHelpers do
  @moduledoc """
  Small shared form-field helpers for user-facing LiveView forms.

  Extracted from the identical private copies that previously lived in
  `KanbanWeb.UserLive.Registration`, `KanbanWeb.UserLive.ResetPassword`,
  and `KanbanWeb.UserLive.Settings` (W1078). Import explicitly where
  needed, following the `KanbanWeb.AuthFrame` precedent.
  """
  use Phoenix.Component

  import KanbanWeb.CoreComponents, only: [translate_error: 1]

  @doc """
  Renders the translated error messages for a single form field.

  ## Examples

      <.field_errors errors={@form[:email].errors} />
  """
  attr :errors, :list, default: []

  def field_errors(assigns) do
    ~H"""
    <span :for={msg <- @errors} style="font-size: 11.5px; color: var(--st-blocked);">
      {translate_error(msg)}
    </span>
    """
  end
end
