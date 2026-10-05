defmodule Kanban.DocsRelativeLinksTest do
  @moduledoc """
  Guards the relative links inside the repository's markdown (D355).

  `docs/AI-WORKFLOW.md` once linked every API page as `../api/...`. From
  `docs/` that climbs to a top-level `api/` directory that does not exist, so
  all 29 links were dead on GitHub and in any markdown viewer, and nothing
  noticed. These tests walk every `docs/**/*.md` file plus `README.md` and fail
  on any relative link whose file or `#fragment` does not resolve, and on any
  file left inside an open code fence. The rules are in
  `docs/doc-link-contract.md`; the helpers are `Kanban.DocLinks`.
  """
  use ExUnit.Case, async: true

  alias Kanban.DocLinks
  alias KanbanWeb.DocAnchors

  @root Path.expand("../..", __DIR__)

  describe "the repository's docs" do
    test "all relative links in docs and README resolve" do
      files = DocLinks.markdown_files(@root)

      assert "README.md" in files
      assert "docs/AI-WORKFLOW.md" in files
      assert "docs/api/README.md" in files

      link_count =
        files
        |> Enum.map(&(@root |> Path.join(&1) |> File.read!() |> DocLinks.links() |> length()))
        |> Enum.sum()

      # Guards against a parser regression that finds nothing and passes.
      assert link_count > 200

      assert DocLinks.broken_links(@root) == []
    end

    test "AI-WORKFLOW.md links stay inside docs" do
      markdown = @root |> Path.join("docs/AI-WORKFLOW.md") |> File.read!()
      docs_dir = Path.join(@root, "docs")

      refute markdown =~ "](../api/"

      links = DocLinks.links(markdown)

      api_links =
        Enum.filter(links, fn {_line, target} -> String.starts_with?(target, "api/") end)

      # 29 links were repaired plus the incremental-sync link that was already
      # right; the four at the end of the file were hidden inside an unclosed
      # fence until D355 closed it.
      assert length(api_links) >= 30
      assert Enum.any?(api_links, fn {_line, target} -> target == "api/" end)

      for {_line, target} <- links, not String.starts_with?(target, "#") do
        [path | _] = String.split(target, "#", parts: 2)
        resolved = Path.expand(path, docs_dir)
        assert String.starts_with?(resolved, docs_dir <> "/"), "#{target} resolves outside docs/"
      end

      assert DocLinks.check_file("docs/AI-WORKFLOW.md", @root) == []
    end
  end

  describe "link resolution" do
    test "anchor and directory links resolve" do
      assert DocLinks.check_link("docs/AI-WORKFLOW.md", 1, "api/", @root) == :ok
      assert DocLinks.check_link("docs/AI-WORKFLOW.md", 1, "api/README.md", @root) == :ok

      assert DocLinks.check_link(
               "docs/AI-WORKFLOW.md",
               1,
               "api/patch_tasks_id_complete.md#completion-validation-format-g65",
               @root
             ) == :ok

      assert DocAnchors.slug("Completion Validation Format (G65)") ==
               "completion-validation-format-g65"

      # An emoji is dropped but its U+FE0F variation selector is a mark and
      # stays, so this heading's anchor starts with an invisible character.
      emoji_slug = DocAnchors.slug("⚠️ CRITICAL: mark_done Endpoint Limitations")
      assert emoji_slug == "\u{FE0F}-critical-mark_done-endpoint-limitations"

      assert DocLinks.check_link(
               "docs/api/README.md",
               1,
               "../AI-WORKFLOW.md#" <> emoji_slug,
               @root
             ) == :ok

      # A file in a nested folder resolves against its own directory.
      assert DocLinks.check_link("docs/api/get_tasks.md", 1, "../AI-WORKFLOW.md", @root) == :ok

      assert DocLinks.check_link(
               "docs/multi-agent-instructions/skills/x.md",
               1,
               "../../AI-WORKFLOW.md#completion-validation",
               @root
             ) == :ok

      # A leading slash is relative to the repository root, as on GitHub.
      assert DocLinks.check_link("docs/api/get_tasks.md", 1, "/docs/AI-WORKFLOW.md", @root) ==
               :ok

      # A same-file fragment is checked against the file's own headings.
      assert DocLinks.check_markdown("docs/x.md", "# Top\n\n[up](#top)\n", @root) == []

      assert [message] = DocLinks.check_markdown("docs/x.md", "# Top\n\n[up](#gone)\n", @root)
      assert message =~ "docs/x.md:3: #gone"
      assert message =~ "matches no heading"
    end

    test "reports a link that resolves outside docs" do
      assert {:error, message} =
               DocLinks.check_link("docs/AI-WORKFLOW.md", 53, "../api/get_tasks.md", @root)

      assert message =~ "docs/AI-WORKFLOW.md:53: ../api/get_tasks.md"
      assert message =~ "api/get_tasks.md, which does not exist"

      # The original defect, as text placed at docs/ level.
      markdown = "# Guide\n\nSee [GET /api/tasks](../api/get_tasks.md) for details.\n"

      assert [message] = DocLinks.check_markdown("docs/GUIDE.md", markdown, @root)
      assert message =~ "docs/GUIDE.md:3: ../api/get_tasks.md"

      # A link that climbs out of the repository is reported without being read.
      assert {:error, message} =
               DocLinks.check_link("docs/AI-WORKFLOW.md", 7, "../../../etc/passwd", @root)

      assert message =~
               "docs/AI-WORKFLOW.md:7: ../../../etc/passwd resolves outside the repository"

      assert {:error, message} =
               DocLinks.check_link(
                 "docs/AI-WORKFLOW.md",
                 9,
                 "api/README.md#no-such-heading",
                 @root
               )

      assert message =~ "names anchor #no-such-heading, which matches no heading"

      assert {:error, message} = DocLinks.check_link("docs/AI-WORKFLOW.md", 9, "api/#x", @root)
      assert message =~ "its target is not a markdown file"
    end

    test "ignores external links, code spans and fenced blocks" do
      markdown = """
      # Title

      [site](https://example.com/missing.md) [mail](mailto:a@example.com)
      [proto](//example.com/x.md) [top](#) ![image](missing.png)
      `[span](missing.md)` and ``[double `span`](missing.md)``

      ```markdown
      [fenced](missing.md)
      ```bash
      [still fenced](missing.md)
      ```

      ````markdown
      [outer](missing.md)
      ```
      [nested](missing.md)
      ```
      ````

      [`code text`](real.md) [angle](<other doc.md> "Title")
      """

      assert DocLinks.links(markdown) == [{20, "real.md"}, {20, "other doc.md"}]
      assert DocLinks.links("No links at all.\n") == []
      assert DocLinks.check_markdown("docs/x.md", "Plain prose, no links.\n", @root) == []
    end

    test "reports a fence that never closes" do
      markdown = "# Hooks\n\n```markdown\n## before_doing\n```bash\ngit pull\n```\n```\n"

      assert DocAnchors.prose_lines(markdown) ==
               {[{1, "# Hooks"}, {2, ""}], 8}

      assert [message] = DocLinks.check_markdown("docs/x.md", markdown, @root)
      assert message =~ "docs/x.md:8: code fence never closes"

      closed = "````markdown\n## before_doing\n```bash\ngit pull\n```\n````\n"
      assert {[{7, ""}], nil} = DocAnchors.prose_lines(closed)
    end
  end
end
