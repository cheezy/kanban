defmodule Kanban.AuditStream.TestEventDocsTest do
  @moduledoc """
  Keeps what the docs say a test event reveals in step with the result classes
  of `Kanban.AuditStream.TestEvent` (W2737). The design doc and the moduledoc
  once said the coarse classes meant a test "cannot be used to probe another
  host's ports", which overstated them: `:certificate_invalid` shows a TLS
  server is listening and an HTTP answer shows an HTTP server. These tests fail
  if that claim comes back in the design doc, `Kanban.AuditStream` or any
  module under it, and if §10.3, §12.5 or the moduledoc stop naming what the
  classes reveal.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @design "docs/plans/AUDIT-LOG-STREAMING-DESIGN.md"

  # Wording that claims the classes hide which ports are open.
  @overstated [
    "cannot be used to probe",
    "which ports are open",
    "let them probe another host's ports",
    "coarse classes prevent",
    "test cannot tell an org-admin"
  ]

  describe "the overstated probing claim" do
    test "is in neither the design doc nor any audit stream module" do
      modules = [
        Path.join(@root, "lib/kanban/audit_stream.ex")
        | @root |> Path.join("lib/kanban/audit_stream/**/*.ex") |> Path.wildcard()
      ]

      sources = [@design | modules]

      assert length(modules) > 10

      for source <- sources, phrase <- @overstated do
        refute source |> read() |> String.contains?(phrase),
               "#{Path.relative_to(source, @root)} says #{inspect(phrase)}"
      end
    end
  end

  describe "what a test event reveals" do
    test "§10.3 names TLS, HTTP and the status" do
      text = @design |> read() |> section("### 10.3 ", "### 10.4 ")

      assert text =~ "whether it speaks TLS or HTTP"
      assert text =~ "for an HTTP error, its status"
    end

    test "§12.5 names what the classes reveal and the hour-boundary burst" do
      text = @design |> read() |> section("### 12.5 ", "## 13. ")

      assert text =~ "a TLS server is listening"
      assert text =~ "an HTTP server answered"
      assert text =~ "for an HTTP error, its status, and never"
      assert text =~ "never a transport reason or an address"
      assert text =~ "up to 20 tests can go out in a burst across an hour boundary"
    end

    test "the TestEvent moduledoc names what the classes reveal and the burst" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(Kanban.AuditStream.TestEvent)

      text = normalize(moduledoc)

      assert text =~ "`:certificate_invalid` shows that a TLS server is listening"
      assert text =~ "shows that an HTTP server answered"
      assert text =~ "for an HTTP error, its status:"
      assert text =~ "up to 20 can go out in a burst across an hour boundary"
    end
  end

  defp read(path), do: path |> Path.expand(@root) |> File.read!() |> normalize()

  # Joins wrapped lines, including indented `#` comment lines, into one line
  # of text. A markdown heading starts in column 0, so it keeps its `#`s.
  defp normalize(text) do
    text
    |> String.replace(~r/\n[ \t]+# /, " ")
    |> String.replace(~r/\s+/, " ")
  end

  defp section(text, from, to) do
    [_, rest] = String.split(text, from, parts: 2)
    [body, _] = String.split(rest, to, parts: 2)
    body
  end
end
