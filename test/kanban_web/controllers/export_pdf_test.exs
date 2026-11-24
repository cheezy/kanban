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
end
