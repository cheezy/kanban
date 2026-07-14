defmodule KanbanWeb.ReviewDiffPanelHostConfigTest do
  @moduledoc """
  W1682: the diff_url host allow-list is configurable via the
  :diff_url_allowed_hosts app env. async: false because it mutates that global
  config; the default-host behavior is covered by the async ReviewDiffPanelTest.
  """
  use KanbanWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.ReviewDiffPanel

  defp render_panel(diff_url) do
    assigns = %{
      selected_file: %{
        "path" => "lib/foo.ex",
        "diff" => "+ a\n[diff truncated at 500 lines]",
        "diff_url" => diff_url
      }
    }

    rendered_to_string(~H"""
    <ReviewDiffPanel.review_diff_panel
      files={["lib/foo.ex"]}
      failing_tests_count={nil}
      selected_file={@selected_file}
    />
    """)
  end

  test "an overridden allow-list admits its host and rejects the default github.com" do
    # The key is unset in test config, so restore must DELETE it — putting the
    # captured nil back would store an explicit nil, and Application.get_env/3
    # returns that stored nil instead of the default host list, crashing every
    # later-seeded test that renders a diff link (`host in nil`).
    original = Application.fetch_env(:kanban, :diff_url_allowed_hosts)
    Application.put_env(:kanban, :diff_url_allowed_hosts, ["git.internal.example"])

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:kanban, :diff_url_allowed_hosts, value)
        :error -> Application.delete_env(:kanban, :diff_url_allowed_hosts)
      end
    end)

    assert render_panel("https://git.internal.example/x/y") =~
             "data-review-diff-panel-diff-link"

    refute render_panel("https://github.com/x/y") =~
             "data-review-diff-panel-diff-link"
  end
end
