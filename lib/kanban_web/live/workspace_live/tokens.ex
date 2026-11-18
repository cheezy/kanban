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
    case ApiTokens.create_workspace_api_token(actor, workspace, token_attrs(params)) do
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
    |> clean_names()
  end

  def parse_capabilities(_capabilities), do: []

  @doc """
  Normalises agent capabilities from the form or a crafted event, the same way
  on the board and workspace token pages (D449). A comma-separated string or a
  list of strings gives trimmed, unique, non-blank names and a missing value
  gives none. Anything else gives `:invalid`, which the token changeset refuses
  with "is invalid", so a malformed value never creates an unrestricted token.
  """
  def normalize_capabilities(nil), do: []
  def normalize_capabilities(value) when is_binary(value), do: parse_capabilities(value)

  def normalize_capabilities(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: clean_names(value), else: :invalid
  end

  def normalize_capabilities(_value), do: :invalid

  defp clean_names(names) do
    names
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp token_attrs(params) do
    %{
      "name" => text(params["name"]),
      "agent_capabilities" => normalize_capabilities(params["agent_capabilities"])
    }
  end

  # Only a string name reaches the changeset: a crafted map or list would be
  # echoed into the failed form and crash its render (D449).
  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  @doc "`:active`, `:revoked` or `:expired`."
  def status(%ApiToken{revoked_at: revoked_at}) when not is_nil(revoked_at), do: :revoked

  def status(%ApiToken{} = api_token) do
    if ApiToken.expired?(api_token), do: :expired, else: :active
  end
end
