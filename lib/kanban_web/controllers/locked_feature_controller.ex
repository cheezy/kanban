defmodule KanbanWeb.LockedFeatureController do
  @moduledoc """
  Counts a click on a locked feature's Available to organizations prompt, then
  sends the user to the pricing page.

  `KanbanWeb.LockedFeature` links every prompt here, so LiveView and controller
  pages share one code path. The feature name from the URL is matched against
  the fixed allow-list in `Kanban.Plans.parse_feature/1`, so it never creates
  an atom. A known feature emits `[:kanban, :plan, :locked_feature_clicked]`
  with only the feature and redirects to `/pricing#contact`; an unknown one
  redirects to `/pricing` and emits nothing. Both redirect targets are fixed
  in-app paths, never taken from the request.

  The redirect always happens, but the click is counted only when it can be
  demand:

    * the browser marks the request as same-origin or user-initiated
      (`Sec-Fetch-Site` of `same-origin` or `none`, or no header at all), so a
      third-party page cannot record clicks through a visitor's session, and
    * the `:locked_feature_click` rate limit allows it, which counts each user
      at most once per feature a week.
  """
  use KanbanWeb, :controller

  alias Kanban.Plans
  alias Kanban.RateLimit

  def show(conn, %{"feature" => name}) do
    case Plans.parse_feature(name) do
      :error ->
        redirect(conn, to: ~p"/pricing")

      feature ->
        if same_origin?(conn), do: record_click(conn.assigns.current_scope.user, feature)
        redirect(conn, to: ~p"/pricing" <> "#contact")
    end
  end

  # Browsers send Sec-Fetch-Site on every navigation; a request without it
  # comes from an older browser or a client outside one, which still needs the
  # visitor's own session cookie.
  defp same_origin?(conn) do
    get_req_header(conn, "sec-fetch-site") in [[], ["same-origin"], ["none"]]
  end

  defp record_click(user, feature) do
    case RateLimit.check(:locked_feature_click, identity: "user:#{user.id}:#{feature}") do
      :ok ->
        Kanban.Telemetry.emit([:kanban, :plan, :locked_feature_clicked], %{count: 1}, %{
          feature: feature
        })

      {:error, {:rate_limited, _retry_after_ms}} ->
        :ok
    end
  end
end
