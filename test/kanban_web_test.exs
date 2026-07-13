defmodule KanbanWebTest do
  @moduledoc """
  Pins the `use KanbanWeb, :context` contracts. Each context function returns
  the quoted block a caller module compiles in, so these assert the wiring
  (Phoenix use/imports) each context is expected to provide — a removed import
  here breaks every module built on that context.
  """
  use ExUnit.Case, async: true

  describe "__using__ context definitions" do
    test "router/0 wires Phoenix.Router with LiveView routing" do
      code = Macro.to_string(KanbanWeb.router())

      assert code =~ "use Phoenix.Router"
      assert code =~ "import Plug.Conn"
      assert code =~ "import Phoenix.LiveView.Router"
    end

    test "channel/0 wires Phoenix.Channel" do
      assert Macro.to_string(KanbanWeb.channel()) =~ "use Phoenix.Channel"
    end

    test "controller/0 wires Phoenix.Controller with html/json formats, gettext, and ~p routes" do
      code = Macro.to_string(KanbanWeb.controller())

      assert code =~ "use Phoenix.Controller"
      assert code =~ "formats: [:html, :json]"
      assert code =~ "use Gettext"
      assert code =~ "use Phoenix.VerifiedRoutes"
    end

    test "live_component/0 wires Phoenix.LiveComponent with the shared html helpers" do
      code = Macro.to_string(KanbanWeb.live_component())

      assert code =~ "use Phoenix.LiveComponent"
      assert code =~ "import KanbanWeb.CoreComponents"
    end

    test "html/0 wires Phoenix.Component with controller conveniences and html helpers" do
      code = Macro.to_string(KanbanWeb.html())

      assert code =~ "use Phoenix.Component"
      assert code =~ "get_csrf_token: 0"
      assert code =~ "import KanbanWeb.CoreComponents"
    end
  end
end
