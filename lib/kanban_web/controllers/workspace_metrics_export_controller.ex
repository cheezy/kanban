defmodule KanbanWeb.WorkspaceMetricsExportController do
  @moduledoc """
  Serves the workspace metrics export (`/metrics/export`) in both formats.

  The workspace counterpart to `KanbanWeb.MetricsPdfController`. It owns
  routing, authorization, parameter parsing, format dispatch and the download
  response; the report bodies live in `KanbanWeb.WorkspaceMetricsPdfHTML` and
  `KanbanWeb.WorkspaceMetricsExcelExport`.

  ## Authorization: scope-derived, never identifier-derived

  This is the important difference from the board export. That controller has a
  board id in the path, so it authorizes by looking the board up for the current
  user. There is no board in this path — the export covers the whole workspace —
  so there is nothing to look up and no lookup to get wrong.

  Instead the controller hands `Kanban.Metrics.Workspace` the caller's scope and
  lets the context derive the visible board set on every read. A requested board
  subset travels as an untrusted *hint*: the context intersects it against the
  visible set, so a forged identifier is silently dropped rather than exported,
  and the response is indistinguishable from one for an id that does not exist.

  Consequently this module deliberately does not alias or call `Kanban.Boards`,
  and must not start: resolving board identifiers here would duplicate the
  intersection the context already performs, and a divergence between the two
  copies is precisely how an authorization bypass gets introduced. The scope
  itself comes from `conn.assigns.current_scope`, which the
  `:require_authenticated_user` pipeline guarantees.

  ## Parameters

  Every parameter is parsed by a total function that falls back to a safe
  default, so no request shape can reach a query as raw input:

    * `window_days` — `Helpers.parse_window_days/1`, allow-listed to 7/14/30/90
      (default 14). The context re-validates independently, so this parse only
      supplies a resolved value to render with; it is not the security boundary.
    * `board_ids` — parsed to integers, unparseable entries dropped. Absent means
      `nil` (every visible board). Present-but-all-forged means `[]`, which the
      context reads as an empty selection and answers with a zero report — it
      must NOT collapse back to `nil`, which would silently widen the export to
      every board the user can see.
    * `timezone` — `KanbanWeb.Timezone.validate_timezone/1`, falling back to
      `"Etc/UTC"` only when absent or unknown. The page reads this from the
      browser via socket connect params; a controller has no socket, so the
      export link carries it. Without it the export's day boundaries would
      silently disagree with the on-screen charts.
    * `exclude_weekends` — `Helpers.parse_exclude_weekends/1`.
    * `format` — `"excel"` selects the workbook; anything else (including
      absent) yields PDF, mirroring the board export. One action serves both.
  """

  use KanbanWeb, :controller

  alias Kanban.Metrics.Workspace
  alias KanbanWeb.MetricsLive.Helpers
  alias KanbanWeb.WorkspaceMetricsExcelExport
  alias KanbanWeb.WorkspaceMetricsPdfHTML

  require Logger

  @excel_content_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  def export(conn, params) do
    opts = build_export_opts(conn.assigns.current_scope, params)
    assigns = build_report_assigns(opts)

    dispatch_format(conn, params, assigns)
  end

  # Public so the parameter contract — criteria 2, 3, 5 and 6 — is unit-testable
  # without driving a real renderer. Mirrors the reference controller's
  # `@doc false`-but-public error handler.
  @doc false
  def build_export_opts(scope, params) do
    [
      scope: scope,
      board_ids: parse_board_ids(params),
      window_days: Helpers.parse_window_days(params["window_days"]),
      exclude_weekends: Helpers.parse_exclude_weekends(params["exclude_weekends"]),
      timezone: KanbanWeb.Timezone.validate_timezone(params)
    ]
  end

  defp build_report_assigns(opts) do
    %{
      overview: Workspace.overview(opts),
      window_days: opts[:window_days],
      timezone: opts[:timezone],
      exclude_weekends: opts[:exclude_weekends],
      generated_at: DateTime.utc_now()
    }
  end

  # A list param (`?board_ids[]=1&board_ids[]=2`) and the scalar form
  # (`?board_ids=1`) both parse; anything else means "no subset" and yields nil.
  #
  # An empty result from a non-empty request is preserved as `[]` on purpose:
  # every requested id was forged or unparseable, and the correct answer is an
  # empty report, not every visible board. Deduplication is the context's job.
  defp parse_board_ids(%{"board_ids" => ids}) when is_list(ids),
    do: Enum.flat_map(ids, &parse_board_id/1)

  defp parse_board_ids(%{"board_ids" => id}) when is_binary(id), do: parse_board_id(id)

  # Present but in a shape we do not recognize (a map, as `?board_ids[a]=1`
  # produces) resolves to an empty selection, NOT to nil. The caller asked for
  # a subset; failing to understand it must never widen the export to every
  # visible board.
  defp parse_board_ids(%{"board_ids" => _unrecognized}), do: []

  defp parse_board_ids(_params), do: nil

  defp parse_board_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> [id]
      _ -> []
    end
  end

  defp parse_board_id(value) when is_integer(value), do: [value]
  defp parse_board_id(_value), do: []

  defp dispatch_format(conn, %{"format" => "excel"}, assigns), do: send_excel(conn, assigns)
  defp dispatch_format(conn, _params, assigns), do: send_pdf(conn, assigns)

  defp send_pdf(conn, assigns) do
    html =
      assigns
      |> WorkspaceMetricsPdfHTML.report()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    case ChromicPDF.print_to_pdf({:html, html}, print_to_pdf: %{printBackground: true}) do
      {:ok, pdf_base64} ->
        send_download_response(
          conn,
          "application/pdf",
          export_filename(assigns, ".pdf"),
          Base.decode64!(pdf_base64)
        )

      {:error, reason} ->
        handle_export_error(conn, reason)
    end
  end

  defp send_excel(conn, assigns) do
    case WorkspaceMetricsExcelExport.generate(assigns) do
      {:ok, excel_binary} ->
        send_download_response(
          conn,
          @excel_content_type,
          export_filename(assigns, ".xlsx"),
          excel_binary
        )

      {:error, reason} ->
        handle_export_error(conn, reason)
    end
  end

  defp send_download_response(conn, content_type, filename, binary) do
    conn
    |> put_resp_content_type(content_type)
    |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
    |> send_resp(200, binary)
  end

  # Every component is trusted by construction, which is why — unlike the board
  # export — no sanitization regex is needed here and no board name appears:
  #
  #   * the prefix and extension are literals;
  #   * `window_days` is the RESOLVED value, so it can only be 7, 14, 30 or 90
  #     — never `params["window_days"]`;
  #   * the date renders from a `Date` struct, so it is always `YYYY-MM-DD`.
  #
  # Do not add the board name or any other user-controlled value back into this:
  # it is interpolated straight into the content-disposition header.
  defp export_filename(assigns, extension) do
    date = assigns.timezone |> Kanban.Timezone.local_today() |> Date.to_string()

    "stride_workspace_metrics_#{assigns.window_days}d_#{date}#{extension}"
  end

  # Log the real reason for operators (renderer port output, internal tuples,
  # paths) but show the user a generic localized message — never interpolate
  # inspect/1 into a flash or response body. The redirect target is the literal
  # page path, not a param-derived one, so nothing from the request is reflected
  # back. Exposed for testing.
  @doc false
  def handle_export_error(conn, reason) do
    Logger.error("Workspace metrics export generation failed (reason=#{inspect(reason)})")

    conn
    |> put_flash(:error, export_error_flash_message())
    |> redirect(to: ~p"/metrics")
  end

  @doc false
  def export_error_flash_message do
    gettext("Failed to generate the export. Please try again or contact support.")
  end
end
