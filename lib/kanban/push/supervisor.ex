defmodule Kanban.Push.Supervisor do
  @moduledoc """
  Starts the Pigeon dispatchers for the platforms whose credentials are
  configured, and nothing else.

  With no `config :kanban, Kanban.Push.APNs` or `Kanban.Push.FCM`
  credentials, which is always the case in dev and test, it starts no
  children, so nothing connects to Apple or Google. In production
  config/runtime.exs sets the credentials from the environment (see
  docs/push-notifications.md):

    * APNs: `Kanban.Push.APNs.SandboxDispatcher` and
      `Kanban.Push.APNs.ProductionDispatcher`, one per APNs endpoint.
    * FCM: a `Goth` token server for the service account, then
      `Kanban.Push.FCM.Dispatcher`.

  No credential sits in this supervisor's child specs: each child starts
  through a function here that reads the credentials from config when it
  starts, so a supervisor report about a child names only the dispatcher.
  Pigeon and Goth still hold the keys in their own processes, which is why
  `Kanban.Push.LogRedaction` filters the log.
  """

  use Supervisor

  alias Kanban.Push.APNs
  alias Kanban.Push.FCM

  @goth Kanban.Push.Goth

  @doc false
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    APNs.config()
    |> children(FCM.config())
    |> Supervisor.init(strategy: :one_for_one)
  end

  @doc """
  The child specs for the given `APNs.config/0` and `FCM.config/0` results:
  none for a platform that is `{:error, :not_configured}`. The specs carry no
  credential, only which dispatcher to start.
  """
  @spec children(APNs.config_result(), FCM.config_result()) :: [Supervisor.child_spec()]
  def children(apns_config, fcm_config),
    do: apns_children(apns_config) ++ fcm_children(fcm_config)

  defp apns_children({:ok, _config}) do
    for {dispatcher, mode} <- [{APNs.SandboxDispatcher, :dev}, {APNs.ProductionDispatcher, :prod}] do
      %{id: dispatcher, start: {__MODULE__, :start_apns, [dispatcher, mode]}}
    end
  end

  defp apns_children({:error, :not_configured}), do: []

  defp fcm_children({:ok, _config}) do
    [
      %{id: @goth, start: {__MODULE__, :start_goth, []}},
      %{id: FCM.Dispatcher, start: {__MODULE__, :start_fcm, []}}
    ]
  end

  defp fcm_children({:error, :not_configured}), do: []

  @doc false
  # Starts one APNs dispatcher; `mode` (:dev or :prod) picks its endpoint.
  def start_apns(dispatcher, mode) do
    with {:ok, config} <- APNs.config() do
      Pigeon.Dispatcher.start_link(
        name: dispatcher,
        pool_size: Pigeon.default_pool_size(),
        adapter: Pigeon.APNS,
        key: config[:key],
        key_identifier: config[:key_identifier],
        team_id: config[:team_id],
        mode: mode
      )
    end
  end

  @doc false
  def start_goth do
    with {:ok, config} <- FCM.config() do
      Goth.start_link(name: @goth, source: {:service_account, config[:service_account]})
    end
  end

  @doc false
  def start_fcm do
    with {:ok, config} <- FCM.config() do
      Pigeon.Dispatcher.start_link(
        name: FCM.Dispatcher,
        pool_size: Pigeon.default_pool_size(),
        adapter: Pigeon.FCM,
        auth: @goth,
        project_id: config[:project_id]
      )
    end
  end
end
