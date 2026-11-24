defmodule KanbanWeb.ExportPdf do
  @moduledoc """
  Prints a metrics export's HTML to a PDF for `KanbanWeb.MetricsPdfController`
  and `KanbanWeb.WorkspaceMetricsExportController`, and reports a failed print
  as `{:error, reason}`.

  ChromicPDF never returns an error tuple: its print result is `{:ok, base64}`,
  and its failures raise. So a Chrome failure or timeout would otherwise escape
  the controller's `{:error, _}` branch, end the `[:kanban, :export]` span with
  an `:exception` event and show the user a 500 page instead of the
  export-failed redirect. This module turns those failures into an error tuple,
  so both controllers handle a real failure and a stubbed one the same way.

  ## What counts as a failed print

  Only failures of the print call itself are caught:

    * the exceptions ChromicPDF raises for a failed print:
      `ChromicPDF.Browser.ExecutionError` (a session-pool checkout or print
      timeout, or a missing session pool), `ChromicPDF.ChromeError` (Chrome
      answered the print with an error) and
      `ChromicPDF.Connection.ConnectionLostError` (Chrome stopped);
    * an exit from the call, which is how a Chrome process that dies during
      the print reaches the caller of a `GenServer.call/3`.

  Any other exception or a throw is re-raised, because it is a bug rather than
  a failed print, and must still reach the error tracker. That includes the
  `RuntimeError` ChromicPDF raises when no ChromicPDF instance is running: a
  missing instance is a deployment fault, not a failed print. Nothing outside the
  print call is wrapped: building the HTML before it, and decoding and sending
  the file after it, still raise as before.
  """

  @print_options [print_to_pdf: %{printBackground: true}]

  @doc """
  Prints `html` with `printer` (the controllers' `:export_pdf_printer` seam).

  Returns the printer's own result, or `{:error, exception}` or
  `{:error, {:exit, reason}}` for a failed print. The reason is for the log
  only; callers never show it to the user.
  """
  @spec print(module(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def print(printer, html) do
    printer.print_to_pdf({:html, html}, @print_options)
  rescue
    error in [
      ChromicPDF.Browser.ExecutionError,
      ChromicPDF.ChromeError,
      ChromicPDF.Connection.ConnectionLostError
    ] ->
      {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
