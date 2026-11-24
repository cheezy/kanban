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

  ## What the reason carries

  Both controllers write the reason to the log with `inspect/1`, so it must
  name Chrome's error and hold nothing from the report:

    * a `ChromicPDF.ChromeError` carries the print options it was raised for,
      with the whole HTML under `:html`. They are cleared, and its `:error`,
      which is what Chrome answered, is kept. Log it with `inspect/1` only:
      `Exception.message/1` reads the cleared options for an `{:evaluate, _}`
      error;
    * `ChromicPDF.Browser.ExecutionError` and
      `ChromicPDF.Connection.ConnectionLostError` carry only a message. The
      message of a print timeout prints the `ChromicPDF.Protocol` that was
      running, whose own `Inspect` implementation filters the HTML out of its
      state;
    * an exit can hold the call's arguments, and so the same protocol with the
      HTML in its state. `inspect/1` filters it in the same way, so the exit is
      returned as it is. Inspecting it with `structs: false` would bypass that
      filter.
  """

  @print_options [print_to_pdf: %{printBackground: true}]

  @doc """
  Prints `html` with `printer` (the controllers' `:export_pdf_printer` seam).

  Returns the printer's own result, or `{:error, exception}` or
  `{:error, {:exit, reason}}` for a failed print. The reason is for the log
  only, through `inspect/1`, which prints Chrome's error and none of `html`;
  callers never show it to the user.
  """
  @spec print(module(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def print(printer, html) do
    printer.print_to_pdf({:html, html}, @print_options)
  rescue
    error in ChromicPDF.ChromeError ->
      {:error, %{error | opts: nil}}

    error in [ChromicPDF.Browser.ExecutionError, ChromicPDF.Connection.ConnectionLostError] ->
      {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
