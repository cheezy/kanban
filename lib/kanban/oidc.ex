defmodule Kanban.OIDC do
  @moduledoc """
  Runtime configuration and Assent adapter for Stride's single OIDC provider.
  """

  @session_key :oidc_session_params
  @default_strategy Assent.Strategy.OIDC

  def session_key, do: @session_key

  def enabled? do
    oidc_config() |> Keyword.get(:enabled, false)
  end

  def display_name do
    oidc_config() |> Keyword.get(:display_name, "SSO")
  end

  def provider_config do
    oidc_config()
  end

  def authorize_url(redirect_uri) do
    config = strategy_config(redirect_uri)
    strategy_module().authorize_url(config)
  end

  def callback(params, session_params, redirect_uri) do
    redirect_uri
    |> strategy_config()
    |> Keyword.put(:session_params, session_params)
    |> strategy_module().callback(params)
  end

  def provisioning_attrs(claims) do
    config = provider_config()

    %{
      issuer: Keyword.fetch!(config, :issuer),
      claims: claims,
      require_verified_email: Keyword.get(config, :require_verified_email, true),
      admin_group_claim: Keyword.get(config, :admin_group_claim, "groups"),
      admin_groups: Keyword.get(config, :admin_groups, [])
    }
  end

  defp strategy_config(redirect_uri) do
    config = provider_config()

    [
      client_id: Keyword.fetch!(config, :client_id),
      client_secret: Keyword.fetch!(config, :client_secret),
      base_url: Keyword.fetch!(config, :issuer),
      redirect_uri: redirect_uri,
      nonce: true,
      authorization_params: [
        scope: Keyword.get(config, :scopes, "openid email profile")
      ]
    ]
  end

  defp strategy_module do
    oidc_config() |> Keyword.get(:strategy_module, @default_strategy)
  end

  defp oidc_config do
    Application.get_env(:kanban, :oidc, [])
  end
end
