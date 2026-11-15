defmodule Kanban.AuditStream.RetryDocsTest do
  @moduledoc """
  Keeps the audit streaming docs honest about what a retry repeats (W2739).

  A retry of one `batch_id` keeps its events and Organization details, but
  reads the actor fields and the destination's settings outside the filters
  on every attempt (design §8.3, D18 and D19). So no paragraph of the design
  doc, the guide or an `audit_stream` module may call a retry identical, or
  say it builds the same body, without naming a field read per attempt.

  Every receiver drops duplicates by the event's `id` with its `instance`
  (W2740). Only HTTPS requests carry a `batch_id`, so no paragraph may tell a
  receiver to dedupe by it, or to drop a batch by the unsigned
  `x-stride-batch` header, and every paragraph that names `batch_id` beside
  dedupe wording must say it is HTTPS-only. Nor may a sentence call either one
  an idempotency or dedupe key, or tell a receiver to drop by "it" just after a
  sentence that names one.
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
    unqualified =
      for {file, paragraph} <- guarded_paragraphs(),
          paragraph =~ @identical,
          not (paragraph =~ @live_field),
          do: {file, String.slice(paragraph, 0, 120)}

    assert unqualified == []
  end

  test "the design doc's batch identity section names every field read per attempt" do
    section = section(File.read!(@design), "### 8.3 ", "### 8.4 ")

    for term <- ~w(email format tags service filter_version batch_id D18 D19) do
      assert section =~ term, "§8.3 does not mention #{term}"
    end
  end

  # An instruction to drop by batch rather than by event: "dedupe by
  # `batch_id`", "deduplicate using the batch id", "drop duplicates by
  # `batch_id`", "use `batch_id` to drop", "drops a `batch_id`", or dropping a
  # batch by its unsigned `x-stride-batch` header (unless "never" or "not").
  @drop_by_batch ~r/(?:dedup\w*|duplicates)\s+(?:by|using|with|on)\s+(?:the\s+|its\s+)?(?:`batch_id`|batch\s+id)|use\s+(?:the\s+|its\s+)?(?:`batch_id`|batch\s+id)\s+to\s+(?:drop|dedup|skip)|drops?\s+an?\s+`batch_id`|(?<!never\s)(?<!not\s)drops?\s+(?:a|the)\s+batch\s+by\s+(?:its\s+|the\s+)?`?x-stride-batch/i

  # Dedupe wording, and the scope a batch_id mention beside it must state.
  @dedupe ~r/dedup|duplicates/i
  @https_scope ~r/only\s+HTTPS|carry\s+(?:no\s+`batch_id`|none)/i

  test "no paragraph tells a receiver to dedupe by batch_id instead of the event id" do
    offending =
      for {file, paragraph} <- guarded_paragraphs(),
          paragraph =~ @drop_by_batch,
          do: {file, String.slice(paragraph, 0, 120)}

    assert offending == []
  end

  # Checked per sentence, so a paragraph's scope elsewhere cannot cover a
  # sentence that names `batch_id` beside dedupe wording without it.
  test "every batch_id dedupe mention says only HTTPS requests carry it" do
    unscoped =
      for {file, paragraph} <- guarded_paragraphs(),
          sentence <- sentences(paragraph),
          sentence =~ ~r/batch(?:_|\s+)id/i,
          sentence =~ @dedupe,
          not (sentence =~ @https_scope),
          do: {file, String.slice(sentence, 0, 120)}

    assert unscoped == []
  end

  # The batch's identifiers, a synonym for using one to drop duplicates, an
  # instruction to drop by a pronoun, and the words that negate either.
  @batch_ref ~r/batch(?:_|\s+)id|x-stride-batch/i
  @dedupe_key ~r/idempotency\s+key|dedup\w*\s+key/i
  @pronoun_drop ~r/use\s+(?:it|this|that|them)\s+(?:as\s+\w+\s+\w+\s+)?to\s+(?:drop|dedup|skip)|(?:dedup\w*|duplicates)\s+(?:by|using|with|on)\s+(?:it|this|that|them)\b/i
  @negated ~r/\b(?:never|not|no)\b/i

  test "no sentence calls batch_id or the x-stride-batch header an idempotency key" do
    offending =
      for {file, sentence} <- guarded_sentences(),
          sentence =~ @batch_ref,
          sentence =~ @dedupe_key,
          not (sentence =~ @negated),
          do: {file, String.slice(sentence, 0, 120)}

    assert offending == []
  end

  # A pronoun is resolved only as far back as the previous sentence of the
  # same paragraph, which is where a reader resolves it.
  test "no sentence drops duplicates by a pronoun that stands for batch_id" do
    offending =
      for {file, paragraph} <- guarded_paragraphs(),
          {previous, sentence} <- sentence_pairs(paragraph),
          sentence =~ @pronoun_drop,
          previous =~ @batch_ref or sentence =~ @batch_ref,
          not (sentence =~ @negated),
          do: {file, String.slice(sentence, 0, 120)}

    assert offending == []
  end

  test "the pronoun and synonym patterns catch the old wording and pass the fixed" do
    for old <- [
          "Use it to drop duplicates.",
          "Receivers dedupe by it.",
          "so use it as a key to skip events seen before.",
          "Drop duplicates on it."
        ] do
      assert old =~ @pronoun_drop, "not caught: #{old}"
    end

    for old <- [
          "Treat `batch_id` as an idempotency key.",
          "The `X-Stride-Batch` header is the dedupe key.",
          "The batch id is a deduplication key."
        ] do
      assert old =~ @batch_ref and old =~ @dedupe_key and not (old =~ @negated),
             "not caught: #{old}"
    end

    assert "Receivers dedupe on `batch_id`." =~ @drop_by_batch

    for fixed <- [
          "The `batch_id` is not an idempotency key.",
          "Never use it to drop duplicates.",
          "A receiver uses it only to correlate attempts."
        ] do
      refute (fixed =~ @dedupe_key or fixed =~ @pronoun_drop) and not (fixed =~ @negated),
             "wrongly caught: #{fixed}"
    end
  end

  test "the guard patterns tell a scoped batch_id mention from an instruction to drop by it" do
    for old <- [
          "A receiver should dedupe by `batch_id` and event `id`.",
          "and drops a `batch_id` it has already accepted.",
          "It drops a batch by its `x-stride-batch` header.",
          "Receivers deduplicate by `batch_id`.",
          "Receivers dedupe using the batch id.",
          "Use `batch_id` to drop duplicates.",
          "It drops the batch by its `x-stride-batch` header."
        ] do
      assert old =~ @drop_by_batch, "not caught: #{old}"
    end

    for fixed <- [
          "drop duplicates by the event's `id`, never by `batch_id`.",
          "It never drops a batch by its `x-stride-batch` header.",
          "should never\ndrop a batch by its `X-Stride-Batch` header.",
          "drop duplicates by event `id` with its `instance`, never by `batch_id`."
        ] do
      refute fixed =~ @drop_by_batch, "wrongly caught: #{fixed}"
    end

    assert "Only HTTPS requests carry `batch_id`; drop duplicates by `id`." =~ @https_scope
    refute "Every batch its `batch_id`, so the receiver can drop duplicates." =~ @https_scope

    refute "The HTTPS endpoint's Format changes; drop duplicates with `batch_id`." =~
             @https_scope
  end

  test "the guide names what a retry re-reads and what stays stable" do
    guide = File.read!(@guide)

    assert guide =~ "**`actor`** is read again on every attempt"
    assert guide =~ "Any other change, such as the HTTPS endpoint's **Format**"
    assert guide =~ "Only the events and the `batch_id` stay the same"
  end

  # Every paragraph of the design doc, the guide and the audit_stream modules,
  # with its file relative to the project root. Runs of whitespace, such as a
  # hard wrap and a list item's indent, become one space, so "never" just
  # before a wrapped "drops" is still seen.
  defp guarded_paragraphs do
    modules = @root |> Path.join("lib/kanban/audit_stream/**/*.ex") |> Path.wildcard()

    for file <- [@design, @guide | modules], paragraph <- paragraphs(File.read!(file)) do
      {Path.relative_to(file, @root), String.replace(paragraph, ~r/\s+/u, " ")}
    end
  end

  defp guarded_sentences do
    for {file, paragraph} <- guarded_paragraphs(), sentence <- sentences(paragraph) do
      {file, sentence}
    end
  end

  defp sentences(paragraph), do: String.split(paragraph, ~r/(?<=[.;!?])\s+/u)

  # Each sentence with the one before it, the first with "".
  defp sentence_pairs(paragraph) do
    sentences = sentences(paragraph)
    Enum.zip(["" | sentences], sentences)
  end

  # Blank-line-separated paragraphs; each Markdown table row stands alone,
  # even indented or right after prose with no blank line between.
  defp paragraphs(text) do
    text
    |> String.split(~r/\n\s*\n/)
    |> Enum.flat_map(&split_table_rows/1)
  end

  defp split_table_rows(block) do
    block
    |> String.split("\n")
    |> Enum.chunk_by(&table_row?/1)
    |> Enum.flat_map(fn [line | _] = lines ->
      if table_row?(line), do: lines, else: [Enum.join(lines, "\n")]
    end)
  end

  defp table_row?(line), do: line =~ ~r/^\s*\|/

  defp section(text, from, to) do
    [_before, rest] = String.split(text, from, parts: 2)
    [section | _after] = String.split(rest, to, parts: 2)
    section
  end
end
