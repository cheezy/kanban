defmodule KanbanWeb.ExportPdfTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ExportPdf

  # Printer stubs: each answers or fails the way ChromicPDF can, and the
  # succeeding one hands back the content and options it was called with.
  defmodule OkPrinter do
    def print_to_pdf(content, opts), do: {:ok, {content, opts}}
  end

  defmodule ErrorPrinter do
    def print_to_pdf(_content, _opts), do: {:error, :forced}
  end

  defmodule ExecutionErrorPrinter do
    def print_to_pdf(_content, _opts), do: raise(ChromicPDF.Browser.ExecutionError, "timeout")
  end

  defmodule ChromeErrorPrinter do
    def print_to_pdf(_content, _opts) do
      raise ChromicPDF.ChromeError, error: "printToPDF failed", opts: []
    end
  end

  # Raises through ChromicPDF's own code, with the options it raises with: the
  # HTML beside the print options.
  defmodule HtmlChromeErrorPrinter do
    def print_to_pdf({:html, html}, opts) do
      ChromicPDF.ExportOptions.feed_chrome_data_into_output(
        {:error, "printToPDF failed"},
        [source_type: :html, html: html] ++ opts
      )
    end
  end

  # Chrome's error can be a tuple, and then message/1 may read the options.
  defmodule TupleChromeErrorPrinter do
    def print_to_pdf({:html, html}, _opts) do
      raise ChromicPDF.ChromeError,
        error: {:exception_thrown, "Error: script failed"},
        opts: [html: html]
    end
  end

  defmodule EvaluateChromeErrorPrinter do
    def print_to_pdf({:html, html}, _opts) do
      raise ChromicPDF.ChromeError,
        error: {:evaluate, %{"lineNumber" => 1}},
        opts: [html: html, evaluate: %{expression: "1"}]
    end
  end

  defmodule NilOptsChromeErrorPrinter do
    def print_to_pdf(_content, _opts), do: raise(ChromicPDF.ChromeError, error: "no opts")
  end

  # A channel whose print never finishes, so the caller's call times out, and
  # which hands the running protocol back when it is cancelled.
  defmodule StuckChannel do
    use GenServer

    def init(nil), do: {:ok, nil}

    def handle_call({:run_protocol, protocol, _ref}, _from, _state), do: {:noreply, protocol}
    def handle_call({:cancel_protocol, _ref}, _from, protocol), do: {:reply, protocol, protocol}
  end

  # Both print through ChromicPDF's own channel call, which sends the channel a
  # ChromicPDF.Protocol with the HTML in its state: one times out, and the other
  # exits because the channel is dead.
  defmodule TimedOutChannelPrinter do
    def print_to_pdf({:html, html}, _opts) do
      {:ok, channel} = GenServer.start_link(StuckChannel, nil)

      ChromicPDF.Browser.Channel.run_protocol(channel, KanbanWeb.ExportPdfTest.protocol(html), 1)
    end
  end

  defmodule DeadChannelPrinter do
    def print_to_pdf({:html, html}, _opts) do
      {channel, monitor} = spawn_monitor(fn -> :ok end)

      receive do
        {:DOWN, ^monitor, :process, ^channel, _reason} -> :ok
      end

      ChromicPDF.Browser.Channel.run_protocol(
        channel,
        KanbanWeb.ExportPdfTest.protocol(html),
        1_000
      )
    end
  end

  defmodule ConnectionLostPrinter do
    def print_to_pdf(_content, _opts) do
      raise ChromicPDF.Connection.ConnectionLostError, "Chrome has stopped"
    end
  end

  defmodule ExitingPrinter do
    def print_to_pdf(_content, _opts), do: exit({:noproc, {GenServer, :call, []}})
  end

  defmodule BuggyPrinter do
    def print_to_pdf(_content, _opts), do: raise(ArgumentError, "bug")
  end

  defmodule ThrowingPrinter do
    def print_to_pdf(_content, _opts), do: throw(:bug)
  end

  def protocol(html) do
    ChromicPDF.PrintToPDF.new("session",
      source_type: :html,
      html: html,
      print_to_pdf: %{"printBackground" => true}
    )
  end

  describe "print/2" do
    test "prints the HTML with a printed background and returns the printer's result" do
      assert ExportPdf.print(OkPrinter, "<p>report</p>") ==
               {:ok, {{:html, "<p>report</p>"}, [print_to_pdf: %{printBackground: true}]}}
    end

    test "passes a printer's own error tuple through unchanged" do
      assert ExportPdf.print(ErrorPrinter, "<p></p>") == {:error, :forced}
    end

    test "returns a ChromicPDF.Browser.ExecutionError as an error" do
      assert {:error, %ChromicPDF.Browser.ExecutionError{message: "timeout"}} =
               ExportPdf.print(ExecutionErrorPrinter, "<p></p>")
    end

    test "returns a ChromicPDF.ChromeError as an error" do
      assert {:error, %ChromicPDF.ChromeError{error: "printToPDF failed"}} =
               ExportPdf.print(ChromeErrorPrinter, "<p></p>")
    end

    test "returns a ChromicPDF.Connection.ConnectionLostError as an error" do
      assert {:error, %ChromicPDF.Connection.ConnectionLostError{}} =
               ExportPdf.print(ConnectionLostPrinter, "<p></p>")
    end

    test "returns an exit from the print call as an error" do
      assert {:error, {:exit, {:noproc, _}}} = ExportPdf.print(ExitingPrinter, "<p></p>")
    end

    test "re-raises an exception that is not a failed print" do
      assert_raise ArgumentError, "bug", fn -> ExportPdf.print(BuggyPrinter, "<p></p>") end
    end

    test "does not catch a throw" do
      assert catch_throw(ExportPdf.print(ThrowingPrinter, "<p></p>")) == :bug
    end
  end

  describe "print/2 - the report HTML stays out of the reason (D477)" do
    @marker "Acme private board"
    @html "<!DOCTYPE html><title>#{@marker}</title>"

    test "returns a ChromeError without its print options" do
      assert {:error, %ChromicPDF.ChromeError{opts: nil} = error} =
               ExportPdf.print(HtmlChromeErrorPrinter, @html)

      assert inspect(error) =~ "printToPDF failed"
      refute inspect(error, limit: :infinity, printable_limit: :infinity) =~ @marker
    end

    test "drops a long html from a ChromeError" do
      html = @html <> String.duplicate("a", 10_000)

      assert {:error, error} = ExportPdf.print(HtmlChromeErrorPrinter, html)
      logged = inspect(error)
      refute logged =~ @marker
      assert String.length(logged) < 200
    end

    test "keeps a ChromeError's tuple error" do
      assert {:error, %ChromicPDF.ChromeError{opts: nil, error: error}} =
               ExportPdf.print(TupleChromeErrorPrinter, @html)

      assert error == {:exception_thrown, "Error: script failed"}
    end

    test "returns an :evaluate ChromeError that inspects without its options" do
      assert {:error, %ChromicPDF.ChromeError{opts: nil} = error} =
               ExportPdf.print(EvaluateChromeErrorPrinter, @html)

      assert inspect(error) =~ "evaluate"
      refute inspect(error) =~ @marker
    end

    test "handles a ChromeError with no opts" do
      assert {:error, %ChromicPDF.ChromeError{opts: nil, error: "no opts"}} =
               ExportPdf.print(NilOptsChromeErrorPrinter, @html)
    end

    test "an exit whose call arguments hold the protocol does not print the HTML" do
      assert {:error, reason} = ExportPdf.print(DeadChannelPrinter, @html)

      assert {:exit, {:noproc, {GenServer, :call, [_pid, request, _timeout]}}} = reason
      assert {:run_protocol, %ChromicPDF.Protocol{state: %{html: @html}}, _ref} = request
      refute inspect(reason, limit: :infinity, printable_limit: :infinity) =~ @marker
    end

    test "a print timeout, whose message prints the protocol, does not print the HTML" do
      assert {:error, %ChromicPDF.Browser.ExecutionError{message: message}} =
               ExportPdf.print(TimedOutChannelPrinter, @html)

      assert message =~ "ChromicPDF.Protocol"
      refute message =~ @marker
    end
  end
end
