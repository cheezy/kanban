defmodule Kanban.FailingMailerAdapter do
  @moduledoc """
  A Swoosh adapter whose `deliver/2` always fails, used to exercise the
  confirmation-email delivery error path in tests. The returned reason mimics
  the shape `:gen_smtp_client` produces on a TLS/socket failure so tests reflect
  what the production `Swoosh.Adapters.SMTP` adapter actually returns.
  """
  use Swoosh.Adapter

  @impl true
  def deliver(_email, _config) do
    {:error,
     {:retries_exceeded, {:network_failure, {~c"smtp.gmail.com", 465}, {:error, :timeout}}}}
  end
end
