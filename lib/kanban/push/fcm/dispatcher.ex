defmodule Kanban.Push.FCM.Dispatcher do
  @moduledoc """
  The Pigeon dispatcher for the FCM HTTP v1 API. `Kanban.Push.Supervisor`
  starts it, after its `Goth` token server, only when FCM credentials are
  configured.
  """

  use Pigeon.Dispatcher, otp_app: :kanban
end
