defmodule KanbanWeb.BoardLive.ApiTokens do
  @moduledoc """
  API-token lifecycle handlers for `KanbanWeb.BoardLive.Show`, extracted from
  the LiveView (W1447). Covers the tokens view resolution and the create /
  revoke / delete event handlers, all socket-in / `{:noreply, socket}`-out
  (following the `KanbanWeb.BoardLive.Membership` style).

  Two behaviors are load-bearing and moved byte-identical: the plaintext token
  is assigned to `:new_token` exactly once at creation (`assign_created_token/3`),
  wrapped in `KanbanWeb.ShownSecret` so inspecting the state hides it (D442),
  and never re-derived from persisted state, and the per-token `board_id ==
  board.id` checks in revoke/delete are cross-board IDOR guards. Flash strings
  are asserted in tests and shown to users — do not reword. `assign_api_tokens_state/3`
  calls `KanbanWeb.BoardLive.BoardState.assign_common_board_state/4`.
  """

  use Gettext, backend: KanbanWeb.Gettext
  use KanbanWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3, to_form: 1, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias KanbanWeb.BoardLive.BoardState
  alias KanbanWeb.ShownSecret
  alias KanbanWeb.WorkspaceLive.Tokens

  @doc "Resolves the API-tokens view: gates by AI-optimized board + role, else assigns token state."
  def resolve_api_tokens_view(socket, board, user_access) do
    cond do
      not board.ai_optimized_board ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("API tokens are only available for AI Optimized boards"))
         |> push_patch(to: ~p"/boards/#{board}")}

      user_access in [:owner, :modify] ->
        assign_api_tokens_state(socket, board, user_access)

      true ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You don't have permission to manage API tokens"))
         |> push_patch(to: ~p"/boards/#{board}")}
    end
  end

  @doc "Creates a token; on success assigns the plaintext once, else re-renders the form with errors."
  def do_create_token(socket, %{"api_token" => api_token} = params) when is_map(api_token) do
    board = socket.assigns.board
    token_params = build_token_params(api_token, params["token"])

    socket.assigns.current_scope.user
    |> ApiTokens.create_api_token_for_member(board, token_params)
    |> respond_to_create(socket, board)
  end

  # A crafted create_token without an api_token map is ignored rather than
  # crashing the view (D442): the socket comes back unchanged, so a token being
  # shown stays shown. The caller has already checked can_modify.
  def do_create_token(socket, _params), do: {:noreply, socket}

  defp respond_to_create({:ok, {_api_token, plain_text_token}}, socket, board),
    do: assign_created_token(socket, board, plain_text_token)

  defp respond_to_create({:error, :unauthorized}, socket, _board) do
    {:noreply,
     put_flash(socket, :error, gettext("You do not have permission to manage API tokens"))}
  end

  defp respond_to_create({:error, changeset}, socket, _board),
    do: {:noreply, assign(socket, :token_form, to_form(changeset, action: :insert))}

  @doc """
  Clears a revealed token when the board leaves the API tokens view, so the
  token is shown once rather than again on the way back (D449).
  """
  def forget_shown_token(socket), do: assign(socket, :new_token, nil)

  defp build_token_params(api_token, extra) do
    api_token
    |> merge_extra(extra)
    |> Enum.flat_map(&clean_param/1)
    |> Map.new()
  end

  defp merge_extra(params, extra) when is_map(extra), do: Map.merge(params, extra)
  defp merge_extra(params, _extra), do: params

  # A crafted map or list as a field value would be echoed into the failed
  # form and crash its render (D449), and silently dropping it would create a
  # token other than the one asked for. A non-string name is dropped, so it
  # fails with "can't be blank" as on workspace settings; capabilities are
  # normalised the way workspace settings does it; any other map or list
  # becomes :invalid, which the changeset refuses with "is invalid".
  defp clean_param({"name", value}) when is_binary(value), do: [{"name", value}]
  defp clean_param({"name", _value}), do: []

  defp clean_param({"agent_capabilities", value}),
    do: [{"agent_capabilities", Tokens.normalize_capabilities(value)}]

  defp clean_param({key, value}) when is_map(value) or is_list(value), do: [{key, :invalid}]
  defp clean_param(param), do: [param]

  defp assign_created_token(socket, board, plain_text_token) do
    api_tokens = ApiTokens.list_api_tokens(board)
    token_changeset = ApiTokens.change_api_token(%ApiTokens.ApiToken{}, %{})

    {:noreply,
     socket
     |> assign(:api_tokens, api_tokens)
     |> assign(:new_token, %ShownSecret{value: plain_text_token})
     |> assign(:token_form, to_form(token_changeset))}
  end

  @doc "Revokes a token, guarding that it belongs to the current board."
  def do_revoke_token(socket, id) do
    api_token = ApiTokens.get_api_token!(id)
    board = socket.assigns.board

    if api_token.board_id == board.id do
      case ApiTokens.revoke_api_token(api_token) do
        {:ok, _api_token} ->
          api_tokens = ApiTokens.list_api_tokens(board)

          {:noreply,
           socket
           |> assign(:api_tokens, api_tokens)
           |> put_flash(:info, gettext("API token revoked successfully"))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to revoke token"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Unauthorized"))}
    end
  end

  @doc "Deletes a token, guarding that it belongs to the current board."
  def do_delete_token(socket, id) do
    api_token = ApiTokens.get_api_token!(id)
    board = socket.assigns.board

    if api_token.board_id == board.id do
      case ApiTokens.delete_api_token(api_token) do
        {:ok, _api_token} ->
          api_tokens = ApiTokens.list_api_tokens(board)

          {:noreply,
           socket
           |> assign(:api_tokens, api_tokens)
           |> put_flash(:info, gettext("API token deleted successfully"))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to delete token"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Unauthorized"))}
    end
  end

  defp assign_api_tokens_state(socket, board, user_access) do
    columns = Columns.list_columns(board)
    api_tokens = ApiTokens.list_api_tokens(board)
    token_changeset = ApiTokens.change_api_token(%ApiTokens.ApiToken{}, %{})

    new_token = Map.get(socket.assigns, :new_token, nil)

    {:noreply,
     socket
     |> BoardState.assign_common_board_state(board, user_access, columns)
     |> assign(:page_title, "Stride")
     |> assign(:api_tokens, api_tokens)
     |> assign(:token_form, to_form(token_changeset))
     |> assign(:new_token, new_token)
     |> assign(:viewing_task_id, nil)
     |> assign(:show_task_modal, false)}
  end
end
