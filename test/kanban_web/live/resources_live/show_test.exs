defmodule KanbanWeb.ResourcesLive.ShowTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest

  alias KanbanWeb.ResourcesLive.Show

  describe "GET /resources/:id" do
    test "renders how-to page for valid id", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "Creating Your First Board"
      assert html =~ "Learn how to create and configure"
      assert html =~ "Back to Resources"
    end

    test "renders 404 state for invalid id", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/nonexistent-guide")

      assert html =~ "Guide not found"
      assert html =~ "doesn&#39;t exist or may have been moved"
      assert html =~ "Browse all guides"
    end

    test "is accessible without authentication", %{conn: conn} do
      conn = get(conn, ~p"/resources/creating-your-first-board")
      assert conn.status == 200
    end
  end

  describe "guide pages with numbered lists" do
    test "renders the claim-complete lifecycle as an ordered list", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/claim-complete-workflow")

      assert html =~ ~s(<ol class="list-decimal list-inside space-y-1 my-2">)

      assert html =~
               "<li><strong>Backlog</strong> → planned work, not offered to agents (status <code"

      assert html =~ "<p>Agents automatically discover, claim, and complete tasks"
      refute html =~ "1. <strong>Backlog</strong>"
      # A list wrapped in <p> comes back with <br/> between its items.
      assert html =~ ~r{<ol class="list-decimal[^"]*">\s*<li><strong>Backlog</strong>}
      refute html =~ "<br/><li>"
    end

    test "renders the review steps as ordered lists", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/reviewing-completed-work")

      assert html =~ ~r{<ol class="list-decimal[^"]*">\s*<li>Click <strong>Approve</strong>}
      assert html =~ "<li>Click <strong>Request changes</strong></li>"
      refute html =~ "Request Changes"
    end

    test "renders hook output as a code block", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/debugging-hooks")

      assert html =~ ~s(<pre class="p-4 rounded-lg bg-base-200 overflow-x-auto">)
      refute html =~ "``"
    end

    test "names the add-task button in plain words", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/adding-your-first-task")

      assert html =~ "<strong>Add Task</strong>"
      refute html =~ "&lt;span"
      refute html =~ "hero-plus-circle-solid"
    end

    test "renders each getting-started guide without raw markup", %{conn: conn} do
      for id <- [
            "creating-your-first-board",
            "understanding-columns",
            "adding-your-first-task",
            "inviting-team-members",
            "using-stride-with-a-team"
          ] do
        {:ok, _view, html} = live(conn, ~p"/resources/#{id}")

        refute html =~ "&lt;", "#{id} renders escaped HTML"
        refute html =~ "**", "#{id} renders a literal **"
        assert html =~ "<strong>", "#{id} renders no bold UI label"
      end
    end

    test "renders each working-with-tasks guide without raw markup", %{conn: conn} do
      for id <- [
            "writing-tasks-for-ai",
            "monitoring-task-progress",
            "reviewing-completed-work",
            "organizing-with-dependencies",
            "using-complexity-priority"
          ] do
        {:ok, _view, html} = live(conn, ~p"/resources/#{id}")

        refute html =~ "&lt;", "#{id} renders escaped HTML"
        refute html =~ "**", "#{id} renders a literal **"
        assert html =~ "<strong>", "#{id} renders no bold UI label"
      end
    end

    test "renders each developer guide without raw markup", %{conn: conn} do
      for id <- [
            "setting-up-hooks",
            "api-authentication",
            "claim-complete-workflow",
            "debugging-hooks"
          ] do
        {:ok, _view, html} = live(conn, ~p"/resources/#{id}")

        refute html =~ "&lt;", "#{id} renders escaped HTML"
        refute html =~ "**", "#{id} renders a literal **"
        assert html =~ "<strong>", "#{id} renders no bold UI label"
      end
    end

    test "the developer guides show the recaptured hook and token images", %{conn: conn} do
      {:ok, _view, hooks} = live(conn, ~p"/resources/setting-up-hooks")
      assert hooks =~ ~s(src="/images/resources/guides/hooks-step-2.png")

      {:ok, _view, auth} = live(conn, ~p"/resources/api-authentication")

      for step <- 1..3 do
        assert auth =~ ~s(src="/images/resources/guides/api-auth-step-#{step}.png")
      end
    end

    test "renders each metrics guide without raw markup", %{conn: conn} do
      for id <- [
            "metrics-dashboard",
            "throughput-metrics",
            "cycle-time-metrics",
            "lead-time-metrics",
            "wait-time-metrics",
            "workspace-and-compliance-metrics"
          ] do
        {:ok, _view, html} = live(conn, ~p"/resources/#{id}")

        refute html =~ "&lt;", "#{id} renders escaped HTML"
        refute html =~ "**", "#{id} renders a literal **"
        assert html =~ "<strong>", "#{id} renders no bold UI label"
      end
    end

    test "the metrics guides show the new workspace, compliance and wait-time images",
         %{conn: conn} do
      {:ok, _view, wait} = live(conn, ~p"/resources/wait-time-metrics")
      assert wait =~ ~s(src="/images/resources/guides/wait-time-metrics-step-2.png")

      {:ok, _view, html} = live(conn, ~p"/resources/workspace-and-compliance-metrics")

      for step <- [2, 4, 8, 9] do
        assert html =~
                 ~s(src="/images/resources/guides/workspace-and-compliance-metrics-step-#{step}.png")
      end
    end

    test "renders each account guide without raw markup", %{conn: conn} do
      for id <- ["managing-your-account", "two-factor-authentication"] do
        {:ok, _view, html} = live(conn, ~p"/resources/#{id}")

        refute html =~ "&lt;", "#{id} renders escaped HTML"
        refute html =~ "**", "#{id} renders a literal **"
        assert html =~ "<strong>", "#{id} renders no bold UI label"
      end
    end

    test "the account guides show the settings and two-factor screenshots", %{conn: conn} do
      {:ok, _view, account} = live(conn, ~p"/resources/managing-your-account")

      for step <- [1, 2, 4, 6, 7] do
        assert account =~
                 ~s(src="/images/resources/guides/managing-your-account-step-#{step}.png")
      end

      assert account =~ ~s(href="/users/notifications")
      assert account =~ ~s(href="/resources/two-factor-authentication")
      assert account =~ ~r{<code[^>]*>delete my account</code>}

      {:ok, _view, two_factor} = live(conn, ~p"/resources/two-factor-authentication")

      for step <- [3, 5] do
        assert two_factor =~
                 ~s(src="/images/resources/guides/two-factor-authentication-step-#{step}.png")
      end
    end

    test "renders each organizations guide with its links and screenshots", %{conn: conn} do
      images = %{
        "free-and-paid-boards" => [3, 4, 5],
        "working-in-a-workspace" => [2, 3, 5, 6, 8],
        "accepting-an-invitation" => [2, 4]
      }

      for {id, steps} <- images do
        {:ok, _view, html} = live(conn, ~p"/resources/#{id}")

        refute html =~ "&lt;", "#{id} renders escaped HTML"
        refute html =~ "**", "#{id} renders a literal **"
        assert html =~ "<strong>", "#{id} renders no bold UI label"

        for step <- steps do
          assert html =~ ~s(src="/images/resources/guides/#{id}-step-#{step}.png")
        end
      end

      {:ok, _view, free} = live(conn, ~p"/resources/free-and-paid-boards")
      assert free =~ ~s(href="/pricing")
      assert free =~ ~s(href="/resources/working-in-a-workspace")

      {:ok, _view, workspace} = live(conn, ~p"/resources/working-in-a-workspace")
      assert workspace =~ ~s(href="/resources/api-authentication")
      assert workspace =~ ~s(href="/resources/accepting-an-invitation")
    end

    test "the reviewing guide shows the Review queue screenshots", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/reviewing-completed-work")

      for step <- 2..5 do
        assert html =~
                 ~s(src="/images/resources/guides/reviewing-completed-work-step-#{step}.png")
      end

      assert html =~ "<strong>Review queue</strong>"
      assert html =~ "<strong>Notes for the agent</strong>"
    end

    test "the members guide renders the invitation and free-board steps", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/inviting-team-members")

      assert html =~ "<strong>Invite with Edit Access</strong>"
      assert html =~ "holds up to 3 people"
      assert html =~ "When Stride&#39;s plans are switched on"
    end
  end

  describe "mount/3 with valid how-to" do
    test "assigns how_to data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources/creating-your-first-board")

      html = render(view)
      assert html =~ "Creating Your First Board"
      assert html =~ "Access Your Boards Dashboard"
    end

    test "assigns page_title from how_to title", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources/setting-up-hooks")

      # The page title should reflect the how-to
      assert page_title(view) =~ "Setting Up Hook Execution"
    end

    test "assigns navigation for previous/next guides", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/understanding-columns")

      # This guide should have navigation
      assert html =~ "Previous" or html =~ "Next"
    end
  end

  describe "mount/3 with invalid how-to" do
    test "assigns nil how_to", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/invalid-id")

      assert html =~ "Guide not found"
      refute html =~ "You're all set"
    end

    test "sets page_title to Not Found", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources/invalid-id")

      assert page_title(view) =~ "Not Found"
    end
  end

  describe "hero section" do
    test "displays title", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/api-authentication")

      assert html =~ "Configuring API Authentication"
    end

    test "displays description", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/api-authentication")

      assert html =~ "Set up API tokens for secure access"
    end

    test "displays content type badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/setting-up-hooks")

      # "tutorial" type
      assert html =~ "Tutorial"
      assert html =~ "hero-academic-cap"
    end

    test "displays reading time", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "3 min read"
    end

    test "displays tags", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "Getting Started"
      assert html =~ "Beginner"
      assert html =~ "Boards"
    end
  end

  describe "steps content" do
    test "displays all steps with numbers", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      # Should have 4 steps (verify by checking step titles which are numbered)
      # The numbers are in div elements with the rounded-full class
      assert html =~ "rounded-full"
      assert html =~ "Access Your Boards Dashboard"
      assert html =~ "Choose a Board Type"
      assert html =~ "Enter Board Details"
      assert html =~ "Start Using Your Board"
    end

    test "displays step titles", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "Access Your Boards Dashboard"
      assert html =~ "Choose a Board Type"
      assert html =~ "Enter Board Details"
      assert html =~ "Start Using Your Board"
    end

    test "displays step content", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "<strong>Boards</strong>"
      assert html =~ "in the sidebar"
      refute html =~ "My Boards"
    end

    test "displays completion message after steps", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      # Note: apostrophe is HTML-encoded
      assert html =~ "You&#39;re all set!" or html =~ "You're all set!"
      assert html =~ "completed all the steps"
    end
  end

  describe "navigation" do
    test "shows back to resources link in hero", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "Back to Resources"
      assert html =~ ~s(href="/resources")
    end

    test "shows back to all resources button at bottom", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      assert html =~ "Back to all resources"
    end

    test "shows next guide when available", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/creating-your-first-board")

      # First guide in getting-started should have next
      assert html =~ "Next"
    end

    test "shows previous guide when available", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resources/adding-your-first-task")

      # Should have previous (not first guide)
      assert html =~ "Previous"
    end

    test "previous/next links navigate correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resources/creating-your-first-board")

      # Should be able to navigate
      html = render(view)
      assert html =~ ~r/href="\/resources\/[a-z-]+"/
    end
  end

  describe "render_markdown/1" do
    test "converts bold text" do
      result = Show.render_markdown("This is **bold** text")
      assert result =~ "<strong>bold</strong>"
    end

    test "converts inline code" do
      result = Show.render_markdown("Use `mix test` command")
      assert result =~ "<code"
      assert result =~ "mix test"
    end

    test "handles nil input" do
      assert Show.render_markdown(nil) == ""
    end

    test "converts list items" do
      result = Show.render_markdown("Items:\n- First\n- Second")
      assert result =~ "<ul"
      assert result =~ "<li>First</li>"
      assert result =~ "<li>Second</li>"
    end

    test "converts double newlines to paragraphs" do
      result = Show.render_markdown("First paragraph.\n\nSecond paragraph.")
      assert result =~ "<p>First paragraph.</p>"
      assert result =~ "<p>Second paragraph.</p>"
    end

    test "converts links" do
      result = Show.render_markdown("[Stride](https://example.com)")
      assert result =~ ~s(href="https://example.com")
      assert result =~ ">Stride</a>"
    end

    test "renders a numbered list as an ordered list" do
      result =
        Show.render_markdown(
          "Steps:\n\n1. **Open** the `form`\n2. Read [docs](https://example.com)\n3. Save"
        )

      assert result =~
               ~s(<ol class="list-decimal list-inside space-y-1 my-2">\n<li><strong>Open</strong> the <code)

      assert result =~ ~s(<li>Read <a href="https://example.com")
      assert result =~ "<li>Save</li>\n</ol>"
      assert result =~ "<p>Steps:</p>"
      refute result =~ "<p><ol"
      refute result =~ "1. "
    end

    test "keeps numbers inside a paragraph as plain text" do
      result = Show.render_markdown("Upgrade to version 2. Then restart.\nPage 3.5 explains why.")

      assert result == "<p>Upgrade to version 2. Then restart.<br/>Page 3.5 explains why.</p>"

      assert Show.render_markdown("Looking back:\n2026. was a year") ==
               "<p>Looking back:<br/>2026. was a year</p>"
    end

    test "renders an empty numbered item without crashing" do
      result = Show.render_markdown("1. First\n2.\n3. ")

      assert result ==
               ~s(<ol class="list-decimal list-inside space-y-1 my-2">\n<li>First</li>\n<li></li>\n<li></li>\n</ol>)
    end

    test "mixes bullet and numbered lists in one step" do
      result = Show.render_markdown("- Bullet\n1. Numbered\n- Bullet again")

      assert result ==
               Enum.join(
                 [
                   ~s(<ul class="list-disc list-inside space-y-1 my-2">\n<li>Bullet</li>\n</ul>),
                   ~s(<ol class="list-decimal list-inside space-y-1 my-2">\n<li>Numbered</li>\n</ol>),
                   ~s(<ul class="list-disc list-inside space-y-1 my-2">\n<li>Bullet again</li>\n</ul>)
                 ],
                 "\n"
               )
    end

    test "wraps the text after a list in its own paragraph" do
      result = Show.render_markdown("Lead:\n- a\n- b\nTrailing line.\n\n1. one\n\nAfter.")

      assert result ==
               Enum.join(
                 [
                   "<p>Lead:</p>",
                   ~s(<ul class="list-disc list-inside space-y-1 my-2">\n<li>a</li>\n<li>b</li>\n</ul>),
                   "<p>Trailing line.</p>",
                   ~s(<ol class="list-decimal list-inside space-y-1 my-2">\n<li>one</li>\n</ol>),
                   "<p>After.</p>"
                 ],
                 "\n"
               )
    end

    test "renders a list followed by a fenced code block" do
      result =
        Show.render_markdown(
          "1. Run this:\n\n```bash\n- not a list\n2. not a list\n**not bold** `x`\n```\n\nDone."
        )

      assert result =~ "<li>Run this:</li>\n</ol>"

      assert result =~
               ~s(<pre class="p-4 rounded-lg bg-base-200 overflow-x-auto"><code class="text-sm font-mono">- not a list\n2. not a list\n**not bold** `x`</code></pre>)

      assert result =~ "<p>Done.</p>"
      refute result =~ "<p><pre"
    end

    test "leaves an unclosed fence as plain text" do
      assert Show.render_markdown("```\nno closing fence") == "<p>```<br/>no closing fence</p>"
    end
  end

  describe "render_markdown/1 XSS prevention" do
    test "escapes script tags in plain text" do
      result = Show.render_markdown("<script>alert('xss')</script>")
      refute result =~ "<script>"
      assert result =~ "&lt;script&gt;"
    end

    test "escapes script tags inside bold" do
      result = Show.render_markdown("**<script>alert(1)</script>**")
      refute result =~ "<script>"
      assert result =~ "<strong>&lt;script&gt;"
    end

    test "escapes HTML inside inline code" do
      result = Show.render_markdown("`<img onerror=alert(1)>`")
      refute result =~ "<img"
      assert result =~ "&lt;img"
    end

    test "escapes HTML inside code blocks" do
      result = Show.render_markdown("```\n<script>alert(1)</script>\n```")
      refute result =~ "<script>alert"
      assert result =~ "&lt;script&gt;"
    end

    test "escapes HTML inside list items" do
      result = Show.render_markdown("- <img src=x onerror=alert(1)>")
      refute result =~ "<img"
      assert result =~ "&lt;img"
    end

    test "escapes HTML inside numbered list items" do
      result =
        Show.render_markdown("1. <script>alert(1)</script>\n2. <img src=x onerror=alert(1)>")

      refute result =~ "<script>"
      refute result =~ "<img"
      assert result =~ "<li>&lt;script&gt;alert(1)&lt;/script&gt;</li>"
      assert result =~ "&lt;img"
    end

    test "escapes event handler attributes" do
      result = Show.render_markdown("<div onmouseover=\"alert(1)\">hover</div>")
      refute result =~ "<div"
      assert result =~ "&lt;div"
    end

    test "blocks javascript: protocol in links" do
      result = Show.render_markdown("[click](javascript:alert(1))")
      refute result =~ "javascript:"
      refute result =~ "<a"
    end

    test "blocks data: protocol in links" do
      result = Show.render_markdown("[click](data:text/html,<script>alert(1)</script>)")
      refute result =~ ~s(href="data:)
      refute result =~ "<a"
    end

    test "blocks vbscript: protocol in links" do
      result = Show.render_markdown("[click](vbscript:msgbox(1))")
      refute result =~ "vbscript:"
      refute result =~ "<a"
    end

    test "blocks case-insensitive javascript: protocol" do
      result = Show.render_markdown("[click](JaVaScRiPt:alert(1))")
      refute result =~ "<a"
    end

    test "allows safe URL protocols" do
      result = Show.render_markdown("[link](https://example.com)")
      assert result =~ ~s(href="https://example.com")
    end

    test "escapes ampersands" do
      result = Show.render_markdown("AT&T")
      assert result =~ "&amp;T"
    end

    test "escapes quotes in text" do
      result = Show.render_markdown("He said \"hello\"")
      assert result =~ "&quot;hello&quot;"
    end
  end

  describe "type_icon/1" do
    test "returns correct icon for guide type" do
      assert Show.type_icon("guide") == "hero-book-open"
    end

    test "returns correct icon for tutorial type" do
      assert Show.type_icon("tutorial") == "hero-academic-cap"
    end

    test "returns default icon for unknown type" do
      assert Show.type_icon("unknown") == "hero-document"
    end
  end

  describe "format_tag/1" do
    test "formats hyphenated tag" do
      assert Show.format_tag("getting-started") == "Getting Started"
    end

    test "formats single word tag" do
      assert Show.format_tag("developer") == "Developer"
    end
  end
end
