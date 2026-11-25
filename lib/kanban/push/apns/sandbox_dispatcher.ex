defmodule Kanban.Push.APNs.SandboxDispatcher do
  @moduledoc """
  The Pigeon dispatcher for the APNs sandbox endpoint, used for devices whose
  `push_environment` is `:sandbox` (builds signed for development, such as one
  run from Xcode).
  `Kanban.Push.Supervisor` starts it only when APNs credentials are configured.
  """

  use Pigeon.Dispatcher, otp_app: :kanban
end
