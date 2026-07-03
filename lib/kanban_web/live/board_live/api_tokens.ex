defmodule KanbanWeb.BoardLive.ApiTokens do
  @moduledoc """
  API-token lifecycle handlers for `KanbanWeb.BoardLive.Show`, extracted from
  the LiveView (W1447). Covers the tokens view resolution and the create /
  revoke / delete event handlers, all socket-in / `{:noreply, socket}`-out
  (following the `KanbanWeb.BoardLive.Membership` style).

  Two behaviors are load-bearing and moved byte-identical: the plaintext token
  is assigned to `:new_token` exactly once at creation (`assign_created_token/3`)
  and never re-derived from persisted state, and the per-token `board_id ==
  board.id` checks in revoke/delete are cross-board IDOR guards. Flash strings
  are asserted in tests and shown to users — do not reword. `assign_api_tokens_state/3`
  calls back into `KanbanWeb.BoardLive.Show.assign_common_board_state/4`, which
  stays in the LiveView.
  """

  use Gettext, backend: KanbanWeb.Gettext
  use KanbanWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3, to_form: 1, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias KanbanWeb.BoardLive.Show

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
  def do_create_token(socket, params) do
    user = socket.assigns.current_scope.user
    board = socket.assigns.board
    token_params = build_token_params(params)

    case ApiTokens.create_api_token(user, board, token_params) do
      {:ok, {_api_token, plain_text_token}} ->
        assign_created_token(socket, board, plain_text_token)

      {:error, changeset} ->
        {:noreply, assign(socket, :token_form, to_form(changeset, action: :insert))}
    end
  end

  defp build_token_params(params) do
    params["api_token"]
    |> Map.merge(params["token"] || %{})
    |> parse_agent_capabilities()
  end

  defp assign_created_token(socket, board, plain_text_token) do
    api_tokens = ApiTokens.list_api_tokens(board)
    token_changeset = ApiTokens.change_api_token(%ApiTokens.ApiToken{}, %{})

    {:noreply,
     socket
     |> assign(:api_tokens, api_tokens)
     |> assign(:new_token, plain_text_token)
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
     |> Show.assign_common_board_state(board, user_access, columns)
     |> assign(:page_title, "Stride")
     |> assign(:api_tokens, api_tokens)
     |> assign(:token_form, to_form(token_changeset))
     |> assign(:new_token, new_token)
     |> assign(:viewing_task_id, nil)
     |> assign(:show_task_modal, false)}
  end

  defp parse_agent_capabilities(params) do
    case params do
      %{"agent_capabilities" => capabilities} when is_binary(capabilities) ->
        parsed_capabilities =
          capabilities
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        Map.put(params, "agent_capabilities", parsed_capabilities)

      _ ->
        params
    end
  end
end
