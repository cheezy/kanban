defmodule Kanban.Push.APNs.SandboxDispatcher do
  @moduledoc """
  The Pigeon dispatcher for the APNs sandbox endpoint, used for devices whose
  `push_environment` is `:sandbox` (development and TestFlight builds).
  `Kanban.Push.Supervisor` starts it only when APNs credentials are configured.
  """

  use Pigeon.Dispatcher, otp_app: :kanban
end
