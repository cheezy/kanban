defmodule Kanban.AuditStream.BatchSizeDocsTest do
  @moduledoc """
  Keeps the audit streaming docs honest about what the 900,000-byte batch
  limit and a batch's recorded bytes measure (D439).

  The cut counts the request body each adapter writes, before gzip, so the
  guide's batch bullet and Limits row and design §8.2 must say so. A batch's
  `bytes` stay the events' JSON size, which is rebuilt on every attempt from
  the live actor fields (D18), so no paragraph may call them the same on
  every retry or attempt.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @design Path.join(@root, "docs/plans/AUDIT-LOG-STREAMING-DESIGN.md")
  @guide Path.join(@root, "docs/audit-log-streaming.md")
  @telemetry Path.join(@root, "docs/telemetry.md")

  # A claim that the recorded bytes never change between attempts.
  @fixed_bytes ~r/bytes[^|]*?the same (figure )?on every (retry|attempt)/is

  test "the guide's batch bullet says the limit counts the request body as each type writes it" do
    # The bullet runs from its bold label to the next bullet of the list.
    [_before, rest] = @guide |> File.read!() |> String.split("- **In batches**", parts: 2)
    [bullet | _after] = String.split(rest, "\n- **", parts: 2)

    assert bullet =~ "900,000 bytes, the size of the\n  request body before compression"
    assert bullet =~ "Datadog's entry"
    assert bullet =~ "Splunk's HEC fields"
    assert bullet =~ "HTTPS JSON envelope or NDJSON newlines"
  end

  test "the guide's Limits row says the limit counts the request body" do
    assert File.read!(@guide) =~
             "| Events per batch | 500, and at most 900,000 bytes of request body before compression, as each type writes it |"
  end

  test "design §8.2 says what the 900,000 bytes measure and what bytes records" do
    section = section(File.read!(@design), "### 8.2 ", "### 8.3 ")

    for term <-
          ~w(entry_size/3 envelope_size/2 ddtags sourcetype redacted D439 batch_delivered D18) do
      assert section =~ term, "§8.2 does not mention #{term}"
    end

    assert section =~ "count the body as the destination's adapter writes it, before\ngzip"
  end

  test "no paragraph calls a batch's bytes the same on every retry" do
    modules = @root |> Path.join("lib/kanban/audit_stream/**/*.ex") |> Path.wildcard()

    claims =
      for file <- [@design, @guide, @telemetry | modules],
          paragraph <- paragraphs(File.read!(file)),
          paragraph =~ @fixed_bytes,
          do: {Path.relative_to(file, @root), String.slice(paragraph, 0, 120)}

    assert claims == []
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
