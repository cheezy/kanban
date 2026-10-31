defmodule KanbanWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use KanbanWeb, :html

  import KanbanWeb.HitMeComponents
  import KanbanWeb.MarketingClosing
  import KanbanWeb.MarketingComponents

  embed_templates "page_html/*"

  @changelog_body_path Path.expand("../../../priv/changelog/body.html", __DIR__)
  @external_resource @changelog_body_path
  @changelog_body File.read!(@changelog_body_path)

  @doc """
  Returns the rendered HTML body of the changelog page (the per-release
  `<section>` elements), stored verbatim in `priv/changelog/body.html`.

  The body is developer-facing release notes — kept out of HEEX so it does not
  generate hundreds of fragmented gettext msgids that would never be
  translated. Mirrors the data-as-content pattern used by `HowToData`.
  """
  def changelog_body, do: @changelog_body

  @mcp_snippet String.trim_trailing(~S"""
               export STRIDE_URL="https://your-stride-host"
               export STRIDE_API_TOKEN="paste-your-token-here"
               claude mcp add --transport http stride "${STRIDE_URL}/api/mcp" \
                 --header "Authorization: Bearer ${STRIDE_API_TOKEN}"
               """)

  @doc """
  Returns the shell commands the `/product` Operate theme shows for adding
  Stride's MCP server to Claude Code.

  The commands are kept out of HEEX because `{` starts an interpolation there,
  and they are not translated: they use a placeholder host and token, never a
  real address or a real token.
  """
  def mcp_snippet, do: @mcp_snippet

  @stride_md_snippet String.trim_trailing(~S"""
                     # Stride Configuration

                     ## before_doing
                     ```bash
                     git pull origin main
                     ```

                     ## after_doing
                     ```bash
                     mix test
                     mix credo --strict
                     ```

                     ## before_review
                     ```bash
                     gh pr create --fill
                     ```

                     ## after_review
                     ```bash
                     echo "Task $TASK_IDENTIFIER approved"
                     ```

                     ## after_goal
                     ```bash
                     git push origin main
                     ```
                     """)

  @doc """
  Returns the example `.stride.md` the `/workflows` page shows, with one
  section for each of the five hooks.

  It is adapted from the generic example in
  `docs/AGENT-HOOK-EXECUTION-GUIDE.md`, not copied from this repository's own
  hook file: it carries no host, token or deploy step. It is kept out of HEEX because `{`
  starts an interpolation there, and it is not translated.
  """
  def stride_md_snippet, do: @stride_md_snippet

  @hit_me_address "enterprise@letstango.ca"

  @doc """
  Returns the address the `/HitMe` page asks visitors to email.
  """
  def hit_me_address, do: @hit_me_address

  @doc """
  Returns the `mailto:` link for the `/HitMe` email button, with `subject`
  percent-encoded so a translated subject containing a space, `&`, `?` or `=`
  cannot break the link or add `cc=`, `bcc=` or `body=` fields. Spaces become
  `%20` rather than `+`, which mail clients would show literally.

  With no argument it uses the translated booking subject for the request's
  locale.
  """
  def hit_me_mailto do
    hit_me_mailto(gettext("Stride half-day proof-of-concept session"))
  end

  def hit_me_mailto(subject) when is_binary(subject) do
    "mailto:" <> @hit_me_address <> "?subject=" <> URI.encode(subject, &URI.char_unreserved?/1)
  end

  @doc """
  Returns the `/HitMe` "Before your session" checklist, in order, as
  `{title, explanation}` pairs translated for the request's locale.

  It tells a team what to have ready on their own machines and accounts; it
  never asks them to send credentials or repository access to anyone.
  """
  def hit_me_checklist do
    [
      {gettext("Your people"),
       gettext(
         "The person who owns the proof of concept, plus the developers who will build it, free for the whole half day."
       )},
      {gettext("Your idea"),
       gettext(
         "A short write-up of the proof of concept: the problem, who it is for, and what a first version must do."
       )},
      {gettext("Your code"),
       gettext(
         "A Git repository (new or existing) the team can push to, with a branch set aside for the session."
       )},
      {gettext("Your checks"),
       gettext(
         "A test runner and a linter that each run with one command, even if there is only one test so far."
       )},
      {gettext("Your agents"),
       gettext(
         "A coding agent such as Claude Code installed and signed in on each developer's machine, with your company's approval to use it on this code."
       )},
      {gettext("Your Stride accounts"),
       gettext("Everyone signed up at stridelikeaboss.com before the day.")},
      {gettext("Your machines"), gettext("Laptops that can build and run the project locally.")}
    ]
  end

  @doc """
  Returns the agent runtimes the `/workflows` page lists as having a Stride
  plugin, in the order of `KanbanWeb.OnboardingPlugins.agents/0`.

  Each entry carries the runtime's `key`, its product `name`, the plugin's
  public repository `url` (taken from the onboarding registry, so the page and
  onboarding cannot drift apart) and a translated line saying how it installs.
  It is a function rather than a module attribute so the copy is translated
  for each request's locale.
  """
  def workflow_runtimes do
    install = %{
      "claude_code" => gettext("Install from the Stride plugin marketplace."),
      "copilot" => gettext("Install straight from the plugin's repository."),
      "gemini" => gettext("Install as a Gemini CLI extension."),
      "codex" => gettext("Install with the setup script in the plugin's repository."),
      "opencode" => gettext("Add the plugin to your opencode.json."),
      "pi" => gettext("Install with the setup script in the plugin's repository.")
    }

    names = %{
      "claude_code" => "Claude Code",
      "copilot" => "GitHub Copilot CLI",
      "gemini" => "Gemini CLI",
      "codex" => "Codex CLI",
      "opencode" => "OpenCode",
      "pi" => "Pi"
    }

    Enum.map(KanbanWeb.OnboardingPlugins.agents(), fn agent ->
      %{
        key: agent.key,
        name: Map.fetch!(names, agent.key),
        url: agent.workflow_url,
        install: Map.fetch!(install, agent.key)
      }
    end)
  end

  @doc """
  Renders a hook, subagent or optional-plugin name as a small `<code>` pill in
  the colours the `/workflows` lifecycle legend uses: `:hook` in the Doing
  colour, `:subagent` in violet, and `:optional` in violet with a dashed
  border.
  """
  attr :kind, :atom, required: true, values: [:hook, :subagent, :optional]
  slot :inner_block, required: true

  def workflow_pill(assigns) do
    ~H"""
    <code
      class={[
        "px-2 py-0.5 rounded font-mono text-[11px] font-normal",
        @kind == :optional && "border border-dashed"
      ]}
      style={pill_style(@kind)}
    >{render_slot(@inner_block)}</code>
    """
  end

  @doc """
  Renders a translated sentence that contains `%{channel}`, with the channel
  name in a span that never wraps, so a name like `#stride-community` can't
  break at its hyphen. Translate the sentence with
  `gettext("... %{channel} ...", channel: "%{channel}")` so the placeholder
  survives and each locale keeps its own word order. Both halves stay
  HTML-escaped. A translation that drops the placeholder renders as written,
  with no channel name.
  """
  attr :text, :string, required: true
  attr :channel, :string, required: true

  def with_channel(assigns) do
    assigns = assign(assigns, :parts, String.split(assigns.text, "%{channel}", parts: 2))

    ~H"""
    <%= case @parts do %>
      <% [before, rest] -> %>
        {before}<span class="whitespace-nowrap">{@channel}</span>{rest}
      <% [text] -> %>
        {text}
    <% end %>
    """
  end

  defp pill_style(:hook), do: "background: var(--st-doing-soft); color: var(--st-doing);"

  defp pill_style(_kind),
    do:
      "background: var(--stride-violet-soft); color: var(--stride-violet-ink); border-color: var(--stride-violet-ink);"

  @doc """
  Returns the five hooks the `/workflows` page explains beside its
  `.stride.md` example, in the order they fire, as `{hook_name, purpose}`.

  The hook names are literal (they are what goes in `.stride.md`); the
  purposes are translated for the request's locale.
  """
  def workflow_hooks do
    [
      {"before_doing",
       gettext(
         "Runs when the agent claims a task. Pull the latest code and set up the workspace."
       )},
      {"after_doing",
       gettext(
         "Runs when the code is written. Run the tests, linters and build; the task cannot complete until they pass."
       )},
      {"before_review",
       gettext("Runs as the task is completed. Open a pull request or post the diff.")},
      {"after_review",
       gettext(
         "Runs once a human approves the task, or straight away when it needs no review. Merge, deploy or notify."
       )},
      {"after_goal",
       gettext(
         "Runs once, when the last task of a goal is done. Push the goal's work or cut a release, and the goal moves to Done."
       )}
    ]
  end

  @doc """
  Returns the chain the `/workflows` quality-gates diagram draws, in the order
  the steps run, as `{label, kind, last?}`.

  `kind` is `:hook`, `:subagent`, `:optional` (a gate that needs its own
  plugin) or `:step`. Hook, agent and plugin names are literal; the two plain
  steps are translated.
  """
  def workflow_gate_chain do
    chain = [
      {"before_doing", :hook},
      {"task-explorer", :subagent},
      {"planner", :subagent},
      {gettext("Implement"), :step},
      {"task-reviewer", :subagent},
      {"stride-security-review", :optional},
      {"stride-exploratory-testing", :optional},
      {"after_doing", :hook},
      {"before_review", :hook},
      {"after_review", :hook},
      {gettext("Done"), :step}
    ]

    last = length(chain) - 1

    chain
    |> Enum.with_index()
    |> Enum.map(fn {{label, kind}, index} -> {label, kind, index == last} end)
  end

  @doc """
  Returns the quality gates the `/workflows` page describes, in the order they
  run, as `{gate_id, pills, title, optional?, body}`.

  `pills` is a list of `{name, kind}` with `kind` `:hook`, `:subagent` or
  `:optional`; names are literal, titles and bodies are translated.
  """
  def workflow_quality_gates do
    [
      {"explore", [{"task-explorer", :subagent}, {"planner", :subagent}],
       gettext("Explore and plan"), false,
       gettext(
         "Before any code is written, a read-only subagent maps the files, tests and patterns the task touches. For medium and larger tasks, a planner turns that map into a step-by-step plan."
       )},
      {"review", [{"task-reviewer", :subagent}], gettext("Review the diff"), false,
       gettext(
         "Once the code is written, a reviewer subagent checks the diff against the task's acceptance criteria, pitfalls, patterns and testing strategy. The agent fixes what it finds before the validation hook runs."
       )},
      {"security-review", [{"stride-security-review", :optional}], gettext("Security review"),
       true,
       gettext(
         "When the stride-security-review plugin is installed and the task lists security considerations, a security reviewer checks the same diff alongside the task reviewer. A consideration it finds unmitigated is escalated rather than waved through."
       )},
      {"exploratory-testing", [{"stride-exploratory-testing", :optional}],
       gettext("Exploratory testing"), true,
       gettext(
         "When the stride-exploratory-testing plugin is installed and the task lists manual tests, an explorer runs a time-boxed session against a running app you have confirmed is safe to test and is not production, then reports what it found. Skipping it never blocks the task."
       )},
      {"dependencies", [{"after_goal", :hook}], gettext("Dependencies and goals"), false,
       gettext(
         "A task can be claimed only when every task it depends on is Done, so finishing one task is what unblocks the next. Goals are never claimed themselves: when a goal's last task is done, the after_goal hook runs and the goal moves to Done."
       )}
    ]
  end
end
