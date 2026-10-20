defmodule KanbanWeb.WorkspaceLive.Tokens do
  @moduledoc """
  The Tokens section of `KanbanWeb.WorkspaceLive.Settings` (W2220): creating,
  listing and revoking workspace-scoped API tokens, kept out of the LiveView
  to hold it under the size limit. Socket-free: each function returns a result
  the LiveView turns into assigns and a flash.

  The context re-checks the org-admin role on every create and revoke
  (`Kanban.ApiTokens.WorkspaceTokens`), so these never authorize anything
  themselves. The plain-text token is returned once by `create/3` and never
  read back from the database.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Component, only: [to_form: 2]

  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken

  @doc "An empty token form."
  def form(changeset \\ ApiToken.workspace_changeset(%ApiToken{}, %{})),
    do: to_form(changeset, as: :token)

  @doc """
  The workspace's tokens for an org-admin `actor`, and none for anyone else.
  The context checks the role itself.
  """
  def list(actor, workspace), do: ApiTokens.list_workspace_api_tokens(actor, workspace)

  @doc """
  Creates a token for `workspace` as `actor` from the form `params`.

  Returns `{:ok, plain_text_token}`, `{:error, :unauthorized}`,
  `{:error, %Phoenix.HTML.Form{}}` with the form's errors, or
  `{:error, message}` with a flash message.
  """
  def create(actor, workspace, params) when is_map(params) do
    attrs = %{
      "name" => params["name"],
      "agent_capabilities" => parse_capabilities(params["agent_capabilities"])
    }

    case ApiTokens.create_workspace_api_token(actor, workspace, attrs) do
      {:ok, {_api_token, plain_text}} -> {:ok, plain_text}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, :archived} -> {:error, gettext("This workspace is archived.")}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, form(%{changeset | action: :insert})}
    end
  end

  @doc """
  Revokes the workspace token with `id` as `actor`. Returns `:ok`,
  `{:error, :unauthorized}` or `{:error, message}` with a flash message.
  """
  def revoke(actor, workspace, id) do
    case ApiTokens.revoke_workspace_api_token(actor, workspace, id) do
      {:ok, _api_token} ->
        :ok

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, :not_found} ->
        {:error, gettext("Token not found.")}

      {:error, _changeset} ->
        {:error, gettext("The token could not be revoked. Please try again.")}
    end
  end

  @doc """
  Splits a comma-separated capability list into trimmed, unique, non-blank
  names. Anything that is not a string gives an empty list.
  """
  def parse_capabilities(capabilities) when is_binary(capabilities) do
    capabilities
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_capabilities(_capabilities), do: []

  @doc "`:active`, `:revoked` or `:expired`."
  def status(%ApiToken{revoked_at: revoked_at}) when not is_nil(revoked_at), do: :revoked

  def status(%ApiToken{} = api_token) do
    if ApiToken.expired?(api_token), do: :expired, else: :active
  end
end
