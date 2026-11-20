defmodule KanbanWeb.API.Me.DecisionController do
  @moduledoc """
  The decisions waiting on the person, for the app's Now screen (W2758,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.4):
  `GET /api/me/decisions`.

  It runs behind the `:device_api` pipeline, so `:current_scope` comes from
  `KanbanWeb.Plugs.AuthenticateDeviceToken`, which refuses an agent API
  token. The route is plan-gated with `:mobile_app` (design §10) through
  `Kanban.Plans.check_user/3`. There is no board check here: only boards
  the person can access and the plan unlocks contribute items in
  `Kanban.Decisions`, so a board outside the plan never appears as an item.
  (The summary's `agents_working` count and the idle-agent check read every
  accessible board, as `Kanban.Decisions` documents.)

  The items and the summary come from `Kanban.Decisions.build_with_summary/2`
  for the requesting device's class, so a phone is never offered an approval
  the approve route would refuse as too large for a phone. It emits
  `[:kanban, :decisions, :built]` with source `:api`. Every
  refusal is rendered by `KanbanWeb.API.Me.FallbackController`.
  """
  use KanbanWeb, :controller

  alias Kanban.Decisions
  alias Kanban.Plans

  action_fallback KanbanWeb.API.Me.FallbackController

  def index(conn, _params) do
    %{current_scope: scope, current_device: device} = conn.assigns

    with :ok <- Plans.check_user(scope, :mobile_app, surface: :controller) do
      decisions =
        Decisions.build_with_summary(scope, source: :api, device_class: device.device_class)

      render(conn, :index, decisions: decisions)
    end
  end
end
