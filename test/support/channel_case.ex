defmodule KanbanWeb.ChannelCase do
  @moduledoc """
  The test case for sockets and channels.

  It imports `Phoenix.ChannelTest`, sets `@endpoint` to `KanbanWeb.Endpoint`
  and checks out the SQL sandbox as `KanbanWeb.ConnCase` does, so a test can
  `connect/2` a socket and `subscribe_and_join/3` a channel against the
  database. Run with `async: true` only when nothing in the test shares the
  sandbox connection with another process.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import KanbanWeb.ChannelCase

      # The default endpoint for testing
      @endpoint KanbanWeb.Endpoint
    end
  end

  setup tags do
    Kanban.DataCase.setup_sandbox(tags)
    :ok
  end
end
