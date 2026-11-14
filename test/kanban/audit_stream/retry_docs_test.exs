defmodule Kanban.AuditStream.RetryDocsTest do
  @moduledoc """
  Keeps the audit streaming docs honest about what a retry repeats (W2739).

  A retry of one `batch_id` keeps its events and Organization details, but
  reads the actor fields and the destination's settings outside the filters
  on every attempt (design §8.3, D18 and D19). So no paragraph of the design
  doc, the guide or an `audit_stream` module may call a retry identical, or
  say it builds the same body, without naming a field read per attempt.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @design Path.join(@root, "docs/plans/AUDIT-LOG-STREAMING-DESIGN.md")
  @guide Path.join(@root, "docs/audit-log-streaming.md")

  # A claim that a retry repeats the whole body.
  @identical ~r/identical|same\s+body/i

  # A field read per attempt, at least one of which such a claim must name.
  @live_field ~r/email|format/i

  test "no claim of an identical retry leaves out the fields read per attempt" do
    modules = @root |> Path.join("lib/kanban/audit_stream/**/*.ex") |> Path.wildcard()
    files = [@design, @guide | modules]

    unqualified =
      for file <- files,
          paragraph <- paragraphs(File.read!(file)),
          paragraph =~ @identical,
          not (paragraph =~ @live_field),
          do: {Path.relative_to(file, @root), String.slice(paragraph, 0, 120)}

    assert unqualified == []
  end

  test "the design doc's batch identity section names every field read per attempt" do
    section = section(File.read!(@design), "### 8.3 ", "### 8.4 ")

    for term <- ~w(email format tags service filter_version batch_id D18 D19) do
      assert section =~ term, "§8.3 does not mention #{term}"
    end
  end

  test "the guide names what a retry re-reads and what stays stable" do
    guide = File.read!(@guide)

    assert guide =~ "**`actor`** is read again on every attempt"
    assert guide =~ "Any other change, such as the HTTPS endpoint's **Format**"
    assert guide =~ "Only the events and the `batch_id` stay the same"
  end

  # Blank-line-separated paragraphs; each Markdown table row stands alone.
  defp paragraphs(text) do
    text
    |> String.split(~r/\n\s*\n/)
    |> Enum.flat_map(fn block ->
      if String.starts_with?(block, "|"), do: String.split(block, "\n"), else: [block]
    end)
  end

  defp section(text, from, to) do
    [_before, rest] = String.split(text, from, parts: 2)
    [section | _after] = String.split(rest, to, parts: 2)
    section
  end
end
