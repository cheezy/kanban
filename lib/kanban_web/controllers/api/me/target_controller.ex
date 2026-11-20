defmodule KanbanWeb.API.Me.TargetController do
  @moduledoc """
  The app's Targets list and Target screen (W2763,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.16, §6.17, §7.10):

    * `GET /api/me/targets` returns every active target the web lists, with
      its status, target date, estimate, member-goal count, `completed` and
      `total` task counts and `owner` (`Kanban.Targets.AppTargets.list/2`);
    * `GET /api/me/targets/:id` returns a target the person owns, with its
      goal rows and its structured `risk` (`Kanban.Targets.AppTargets.detail/3`).

  It runs behind the `:device_api` pipeline, so `:current_scope` and
  `:current_device` come from `KanbanWeb.Plugs.AuthenticateDeviceToken`. Both
  reads derive status in the device's time zone, else UTC. Both routes are
  plan-gated with `:mobile_app` (design §10): the person's plan first. The
  list then leaves out goals on boards outside the plan. The target read is
  owner only and answers 404, never 403, to anyone else, as `/targets/:id`
  shows its not-found page, so it never reveals that a target exists.

  A read that answers 200 emits `[:kanban, :status, :viewed]` with its
  `surface` (`:targets` or `:target`) and `via`, the device's platform.

  Every refusal is rendered by `KanbanWeb.API.Me.FallbackController`.
  """
  use KanbanWeb, :controller

  alias Kanban.Plans
  alias Kanban.Targets.AppTargets
  alias KanbanWeb.IdParams

  action_fallback KanbanWeb.API.Me.FallbackController

  def index(conn, _params) do
    %{current_scope: scope, current_device: device} = conn.assigns

    with :ok <- check_user(scope) do
      targets = AppTargets.list(scope, timezone: time_zone(device))
      viewed(:targets, device)
      render(conn, :index, targets: targets)
    end
  end

  def show(conn, %{"id" => id}) do
    %{current_scope: scope, current_device: device} = conn.assigns

    with :ok <- check_user(scope),
         {:ok, target_id} <- parse_id(id),
         {:ok, detail} <- AppTargets.detail(scope, target_id, timezone: time_zone(device)) do
      viewed(:target, device)
      render(conn, :show, detail: detail)
    end
  end

  defp check_user(scope), do: Plans.check_user(scope, :mobile_app, surface: :controller)

  defp viewed(surface, device) do
    Kanban.Telemetry.emit([:kanban, :status, :viewed], %{count: 1}, %{
      surface: surface,
      via: device.platform
    })
  end

  defp time_zone(%{time_zone: zone}) when is_binary(zone), do: zone
  defp time_zone(_device), do: nil

  defp parse_id(id) do
    case IdParams.parse(id) do
      {:ok, target_id} -> {:ok, target_id}
      :error -> {:error, :not_found}
    end
  end
end
