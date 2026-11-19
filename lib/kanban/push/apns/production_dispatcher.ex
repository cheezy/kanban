defmodule Kanban.Push.APNs.ProductionDispatcher do
  @moduledoc """
  The Pigeon dispatcher for the APNs production endpoint, used for devices
  whose `push_environment` is `:production` (App Store builds).
  `Kanban.Push.Supervisor` starts it only when APNs credentials are configured.
  """

  use Pigeon.Dispatcher, otp_app: :kanban
end
