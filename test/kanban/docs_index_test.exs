defmodule Kanban.DocsIndexTest do
  @moduledoc """
  Guards the docs index, `docs/README.md` (W2423).

  The index lists every markdown file under `docs/`, grouped by audience, so a
  reader can find the guide written for them and tell a current guide from a
  historical record. These tests fail when a doc under `docs/` is not linked
  from the index, and the failure names every missing file, so a new doc
  cannot land without an entry.

  Files are enumerated from disk with `Kanban.DocLinks.markdown_files/1`, the
  same walk the relative-link check uses, so an untracked `.md` file left under
  `docs/` fails this test locally too. Folders that `.gitignore` excludes under
  `docs/` (today `docs/blog/`, local drafts) are not required: a link to a file
  that is never committed would be dead on GitHub and in CI. Links in the index
  follow `docs/doc-link-contract.md`, which the relative-link test enforces.

  `@unindexed_docs` names committed docs that are deliberately left out of the
  index for now, such as a design still under discussion. Each entry must exist
  and must not be linked, so the list cannot go stale: delete an entry when its
  doc is added to the index or removed.
  """
  use ExUnit.Case, async: true

  alias Kanban.DocLinks

  @root Path.expand("../..", __DIR__)
  @index "docs/README.md"
  @unindexed_docs ["docs/plans/TIMELINE-VIEW-DESIGN.md"]

  describe "the docs index" do
    test "every markdown file under docs/ is linked from docs/README.md" do
      required = required_docs(@root, real_ignored_prefixes())

      # Guards against an enumeration that finds nothing and passes.
      assert length(required) > 80

      # Nested folders are enumerated and required, not just top-level docs.
      assert "docs/multi-agent-instructions/skills/stride-workflow/SKILL.md" in required
      assert "docs/api/get_tasks.md" in required
      assert "docs/security-findings/W1592-auth-and-sessions.md" in required

      # The index is not required to list itself, and the root README is not a doc.
      refute @index in required
      refute "README.md" in required

      assert_indexed(required, read(@index), @root)
    end

    test "each deliberately unindexed doc exists and is not linked" do
      linked = DocLinks.linked_paths(@index, read(@index), @root)

      for doc <- @unindexed_docs do
        assert @root |> Path.join(doc) |> File.regular?(),
               "#{doc} is in @unindexed_docs but does not exist; remove the entry"

        refute doc in linked,
               "#{doc} is now linked from docs/README.md; remove it from @unindexed_docs"
      end
    end

    test "each doc is listed once" do
      linked = DocLinks.linked_paths(@index, read(@index), @root)
      duplicates = linked |> Enum.frequencies() |> Enum.filter(fn {_, n} -> n > 1 end)

      assert duplicates == [],
             "docs/README.md lists these docs more than once; keep each under one group:\n" <>
               Enum.map_join(duplicates, "\n", fn {path, _} -> "  #{path}" end)
    end

    test "a missing entry fails with a message naming that file" do
      nested = "docs/multi-agent-instructions/skills/stride-workflow/SKILL.md"
      required = ["docs/AI-WORKFLOW.md", "docs/api/get_tasks.md", nested]
      index = "# Index\n\n- [Workflow](AI-WORKFLOW.md)\n- [Tasks](api/get_tasks.md)\n"

      error = assert_raise ExUnit.AssertionError, fn -> assert_indexed(required, index, @root) end

      assert error.message =~ "docs/README.md does not link these docs"
      assert error.message =~ nested
      refute error.message =~ "docs/AI-WORKFLOW.md"
      refute error.message =~ "docs/api/get_tasks.md"
    end

    test "docs/README.md is not required to list itself" do
      refute @index in required_docs(@root, [])

      index = "# Index\n\n- [Workflow](AI-WORKFLOW.md)\n"
      assert assert_indexed(["docs/AI-WORKFLOW.md"], index, @root)
    end

    test "docs paths ignored by .gitignore are not required" do
      gitignore = """
      # Local drafts
      docs/blog/
      /docs/drafts
      *.log
      assets/docs/
      """

      assert ignored_doc_prefixes(gitignore) == ["docs/blog/", "docs/drafts"]

      assert ignored?("docs/blog/x.md", ["docs/blog/"])
      assert ignored?("docs/drafts/y.md", ["docs/drafts"])
      refute ignored?("docs/blogging.md", ["docs/blog/"])

      assert_raise ArgumentError, ~r/ignored_doc_prefixes/, fn ->
        ignored_doc_prefixes("docs/*.tmp\n")
      end

      assert_raise ArgumentError, ~r/ignored_doc_prefixes/, fn ->
        ignored_doc_prefixes("!docs/blog/keep.md\n")
      end

      prefixes = real_ignored_prefixes()
      assert "docs/blog/" in prefixes
      required = required_docs(@root, prefixes)
      refute Enum.any?(required, &ignored?(&1, prefixes))
    end
  end

  describe "Kanban.DocLinks.linked_paths/3" do
    test "resolves links the way the link check resolves them" do
      markdown = """
      # Index

      [a](AI-WORKFLOW.md) [b](api/get_tasks.md#get-apitasks)
      [c](<multi-agent-instructions/skills/stride-workflow/SKILL.md>)
      [d](/docs/MCP.md) [e](./webhooks.md) [f](plans/A%20B.md)
      [g](#local) [h](api/) [i](../README.md) [j](../../outside.md)
      `[span](span.md)` [site](https://example.com/x.md)

      ```markdown
      [fenced](fenced.md)
      ```
      """

      assert DocLinks.linked_paths(@index, markdown, @root) == [
               "docs/AI-WORKFLOW.md",
               "docs/api/get_tasks.md",
               "docs/multi-agent-instructions/skills/stride-workflow/SKILL.md",
               "docs/MCP.md",
               "docs/webhooks.md",
               "docs/plans/A B.md",
               "docs/api",
               "README.md"
             ]

      assert DocLinks.linked_paths(@index, "No links.\n", @root) == []
      assert DocLinks.linked_paths("README.md", "[root](.)\n", @root) == []
    end
  end

  defp real_ignored_prefixes,
    do: @root |> Path.join(".gitignore") |> File.read!() |> ignored_doc_prefixes()

  defp read(path), do: @root |> Path.join(path) |> File.read!()

  # The `docs/` entries of a .gitignore, as plain path prefixes. Only literal
  # paths are understood; anything else raises so a new kind of entry is never
  # silently mis-handled.
  defp ignored_doc_prefixes(gitignore) do
    gitignore
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(&doc_prefix/1)
  end

  defp doc_prefix("!" <> rest = line) do
    if rest |> String.trim_leading("/") |> String.starts_with?("docs/"),
      do: unsupported!(line),
      else: []
  end

  defp doc_prefix(line) do
    path = String.replace_prefix(line, "/", "")

    cond do
      not String.starts_with?(path, "docs/") -> []
      String.contains?(path, ["*", "?", "[", "\\"]) -> unsupported!(line)
      true -> [path]
    end
  end

  defp unsupported!(line) do
    raise ArgumentError,
          ".gitignore entry #{inspect(line)} is not a literal docs/ path; " <>
            "extend ignored_doc_prefixes/1 in #{Path.relative_to(__ENV__.file, @root)} to handle it"
  end

  defp ignored?(path, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      dir = String.trim_trailing(prefix, "/")
      path == dir or String.starts_with?(path, dir <> "/")
    end)
  end

  defp required_docs(root, prefixes) do
    root
    |> DocLinks.markdown_files()
    |> Enum.filter(&String.starts_with?(&1, "docs/"))
    |> Enum.reject(&(&1 == @index or &1 in @unindexed_docs or ignored?(&1, prefixes)))
  end

  defp assert_indexed(required, markdown, root) do
    linked = DocLinks.linked_paths(@index, markdown, root)
    missing = Enum.sort(required -- linked)

    assert missing == [],
           "docs/README.md does not link these docs. Add each under exactly one " <>
             "audience group with a one-line purpose:\n" <>
             Enum.map_join(missing, "\n", &"  #{&1}")
  end
end
