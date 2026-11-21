defmodule KanbanWeb.IntegrationsTest do
  @moduledoc """
  The agent runtime catalog behind /integrations (W2899), and the check that
  every install command on those pages is the one its plugin README gives.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.Integrations
  alias KanbanWeb.Integrations.Runtime
  alias KanbanWeb.PluginReadme

  @locales ~w(de en es fr ja pt zh)

  @own_repos %{
    "claude-code" => ["stride"],
    "codex" => ["stride-codex", "stride-codex-marketplace"],
    "gemini-cli" => ["stride-gemini"],
    "github-copilot" => ["stride-copilot"],
    "opencode" => ["stride-opencode"],
    "pi" => ["stride-pi"]
  }

  defp steps, do: Enum.flat_map(Integrations.all(), & &1.install)

  describe "the catalog" do
    test "lists the six runtimes Stride ships a plugin for, in index order" do
      assert Enum.map(Integrations.all(), & &1.name) ==
               ["Claude Code", "Codex CLI", "Gemini CLI", "GitHub Copilot", "OpenCode", "Pi"]

      assert Enum.map(Integrations.all(), & &1.slug) == Integrations.slugs()
      assert Integrations.slugs() == Enum.uniq(Integrations.slugs())
    end

    test "every runtime has its install steps, capabilities and links" do
      for %Runtime{} = runtime <- Integrations.all() do
        assert runtime.install != [], runtime.slug
        assert runtime.capabilities != [], runtime.slug
        assert runtime.listing_kind in [:marketplace, :extension_index, :repository]
        assert is_boolean(runtime.preview)
        assert runtime.tagline =~ ~r/\S/
      end
    end

    test "links only to the official Stride repositories and marketplaces" do
      for runtime <- Integrations.all(),
          url <- [runtime.listing_url, runtime.docs_url, runtime.install_note_url],
          url != nil do
        assert String.starts_with?(url, "https://github.com/cheezy/stride"), url
      end

      for step <- steps(), url <- Regex.scan(~r{https?://\S+}, step.command) |> List.flatten() do
        assert url =~ ~r{\Ahttps://(github\.com|raw\.githubusercontent\.com)/cheezy/stride}, url
      end
    end

    test "fetch/1 finds a runtime by slug and refuses anything else" do
      for slug <- Integrations.slugs() do
        assert {:ok, %Runtime{slug: ^slug}} = Integrations.fetch(slug)
      end

      for slug <- ["", "CODEX", "codex.md", "stride", "../codex", "claude"] do
        assert Integrations.fetch(slug) == :error, slug
      end
    end

    test "sitemap_paths/0 lists the index and one page per runtime" do
      assert Integrations.sitemap_paths() ==
               ["/integrations" | Enum.map(Integrations.slugs(), &("/integrations/" <> &1))]
    end

    test "every page has a distinct title and a description of the right length in every locale" do
      for locale <- @locales do
        Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
          titles = Enum.map(Integrations.all(), &Integrations.page_title/1)
          descriptions = Enum.map(Integrations.all(), &Integrations.meta_description/1)

          assert titles == Enum.uniq(titles), locale
          assert descriptions == Enum.uniq(descriptions), locale

          for description <- descriptions do
            assert String.length(description) <= 160, "#{locale}: #{description}"
            if locale == "en", do: assert(String.length(description) >= 70, description)
          end
        end)
      end
    end
  end

  describe "install commands" do
    test "every install command on the pages matches the one in that runtime's README" do
      for step <- steps() do
        blocks = step.source |> PluginReadme.fixture() |> PluginReadme.code_blocks()

        assert step.command in blocks,
               "#{inspect(step.command)} is not a code block in the #{step.source} README's " <>
                 "install section (#{Path.relative_to_cwd(PluginReadme.fixture_path(step.source))})"
      end
    end

    test "every command comes from a README whose install section is committed" do
      for step <- steps() do
        assert step.source in PluginReadme.repos(), step.source
      end
    end

    test "every step comes from its own runtime's plugin README" do
      for runtime <- Integrations.all(), step <- runtime.install do
        assert step.source in Map.fetch!(@own_repos, runtime.slug),
               "#{runtime.slug}: #{step.source}"
      end
    end

    # The install sections also hold uninstall, clean-up and not-yet-available
    # commands; matching a code block alone would accept those.
    test "no step is an uninstall, clean-up or not-yet-available command" do
      for step <- steps() do
        refute step.command =~ ~r/uninstall|claude-community|rm -rf|\bremove\b/i, step.command
      end
    end

    test "no install command is a translatable string" do
      pot = File.read!("priv/gettext/default.pot")

      for step <- steps(), line <- String.split(step.command, "\n"), line != "" do
        refute pot =~ ~s(msgid "#{line}"), line
      end
    end

    # The plugin checkouts are gitignored and absent in CI, so this only bites
    # where a checkout sits beside the app.
    test "each committed install section still matches its plugin README" do
      for repo <- PluginReadme.repos(), repo |> PluginReadme.live_path() |> File.exists?() do
        live = repo |> PluginReadme.live_path() |> File.read!()

        assert PluginReadme.section(live, PluginReadme.heading(repo)) ==
                 PluginReadme.fixture(repo),
               "#{repo}/README.md changed its \"#{PluginReadme.heading(repo)}\" section. Copy it to " <>
                 "#{Path.relative_to_cwd(PluginReadme.fixture_path(repo))} and update the " <>
                 "commands in KanbanWeb.Integrations (docs/integrations-pages.md)."
      end
    end
  end

  describe "KanbanWeb.PluginReadme" do
    @markdown """
    # Title

    ## Installation

    ```bash
    one
    ```

    ```markdown
    ## before_doing
    two
    ```

    ## Next

    ```bash
    three
    ```
    """

    test "section/2 stops at the next heading outside a fence" do
      section = PluginReadme.section(@markdown, "Installation")

      assert section =~ "## before_doing"
      refute section =~ "three"
      assert String.starts_with?(section, "## Installation")
    end

    test "section/2 is empty for a heading the document does not have" do
      assert PluginReadme.section(@markdown, "Missing") == ""
    end

    test "code_blocks/1 returns each fence body" do
      assert PluginReadme.code_blocks(@markdown) == ["one", "## before_doing\ntwo", "three"]
    end

    @nested """
    ```markdown
    ## Installation
    ```

    ## Installation

    ~~~markdown
    ```bash
    x
    ~~~

    ````markdown
    ## not a heading
    ```
    ````

    ## Setup

    ```bash
    rm -rf ~/.pi
    ```
    """

    test "section/2 reads tilde and longer fences, and skips a heading inside a fence" do
      section = PluginReadme.section(@nested, "Installation")

      assert String.starts_with?(section, "## Installation\n\n~~~markdown")
      assert section =~ "## not a heading"
      refute section =~ "rm -rf"
    end

    test "code_blocks/1 closes a fence only on the same character, at least as long" do
      assert PluginReadme.code_blocks(@nested) ==
               ["## Installation", "```bash\nx", "## not a heading\n```", "rm -rf ~/.pi"]
    end
  end
end
