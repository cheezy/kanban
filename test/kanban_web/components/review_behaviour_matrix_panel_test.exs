defmodule KanbanWeb.ReviewBehaviourMatrixPanelTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.ReviewBehaviourMatrixPanel

  describe "review_behaviour_matrix/1 (W1921)" do
    test "renders one row per matrix row with category, behaviour, test name and type" do
      html =
        render_matrix([
          row(%{"behaviour" => "rejects an expired claim", "test_name" => "expired claim test"}),
          row(%{"category" => "Null / empty", "behaviour" => "tolerates a nil verdict"})
        ])

      assert html =~ "data-review-behaviour-matrix"
      assert row_count(html) == 2
      assert html =~ "Boundary"
      assert html =~ "Null / empty"
      assert html =~ "rejects an expired claim"
      assert html =~ "tolerates a nil verdict"
      assert html =~ "expired claim test"
      assert html =~ "data-review-behaviour-type"
      assert html =~ "unit"
    end

    test "renders a green pill for a passing row" do
      html = render_matrix([row(%{"status" => "passing"})])

      assert html =~ ~s(data-review-behaviour-status="passing")
      assert html =~ "data-review-behaviour-pill"
      assert html =~ "background: var(--st-done-soft"
      assert html =~ ~r/Passing\s*<\/span>/
    end

    test "renders a red pill for a failing row" do
      html = render_matrix([row(%{"status" => "failing"})])

      assert html =~ ~s(data-review-behaviour-status="failing")
      assert html =~ "background: var(--st-blocked-soft"
      assert html =~ ~r/Failing\s*<\/span>/
    end

    test "renders a neutral outlined pill for a planned row" do
      html = render_matrix([row(%{"status" => "planned"})])

      assert html =~ ~s(data-review-behaviour-status="planned")

      assert html =~
               "background: var(--surface-sunken); color: var(--ink-2); border: 1px solid var(--line);"

      assert html =~ ~r/Planned\s*<\/span>/
    end

    test "renders a muted pill for a not_applicable row" do
      html = render_matrix([row(%{"status" => "not_applicable"})])

      assert html =~ ~s(data-review-behaviour-status="not_applicable")

      assert html =~
               "background: var(--surface-sunken); color: var(--ink-3); border: 1px solid var(--line);"

      assert html =~ ~r/Not applicable\s*<\/span>/
    end

    # A soft status fill is only ~1.05:1 against the card in either theme, so a
    # tinted pill without a border reads as bare coloured text rather than a
    # capsule — the exact inversion the manual exploratory pass surfaced.
    test "every pill carries a border, tinted ones included" do
      for status <- ["passing", "failing", "planned", "not_applicable", "bogus"] do
        html = render_matrix([row(%{"status" => status})])

        refute html =~ "border: 1px solid transparent;",
               "pill for #{status} must not rely on a transparent border"

        assert html =~ "border: 1px solid var(--line);",
               "pill for #{status} must be outlined"
      end
    end

    test "every text column can wrap an unbroken token" do
      long = String.duplicate("x", 300)

      for key <- ~w(behaviour test_name type category) do
        html = render_matrix([row(%{key => long})])

        assert html =~ "overflow-wrap: anywhere",
               "#{key} column must be able to wrap an unbroken token"

        assert html =~ long
      end
    end

    test "every neutral pill carries a border so it stays visible in light mode" do
      for status <- ["planned", "not_applicable", "bogus"] do
        html = render_matrix([row(%{"status" => status})])

        assert html =~ "border: 1px solid var(--line);",
               "neutral pill for #{status} must be outlined"
      end
    end

    test "renders every row when all rows are not_applicable" do
      html =
        render_matrix([
          row(%{"behaviour" => "a", "status" => "not_applicable"}),
          row(%{"behaviour" => "b", "status" => "not_applicable"}),
          row(%{"behaviour" => "c", "status" => "not_applicable"})
        ])

      assert row_count(html) == 3
      assert length(Regex.scan(~r/color: var\(--ink-3\);/, html)) >= 3
    end

    test "renders an unknown status verbatim with a neutral pill" do
      html = render_matrix([row(%{"status" => "bogus"})])

      assert html =~ ~s(data-review-behaviour-status="bogus")
      assert html =~ ~r/bogus\s*<\/span>/

      assert html =~
               "background: var(--surface-sunken); color: var(--ink-2); border: 1px solid var(--line);"

      refute html =~ "background: var(--st-done-soft"
    end

    test "labels a row with no status as Unknown" do
      html = render_matrix([Map.delete(row(), "status")])

      assert html =~ ~s(data-review-behaviour-status="unknown")
      assert html =~ ~r/Unknown\s*<\/span>/
    end

    test "drops malformed rows" do
      html =
        render_matrix([
          row(%{"behaviour" => "kept behaviour"}),
          %{"behaviour" => "orphan with no category"},
          %{"category" => "Boundary"},
          "not a map"
        ])

      assert row_count(html) == 1
      assert html =~ "kept behaviour"
      refute html =~ "orphan with no category"
    end

    test "omits the test name and type when the reviewer supplied neither" do
      html =
        render_matrix([
          %{"category" => "Concurrency", "behaviour" => "waived", "status" => "not_applicable"}
        ])

      assert row_count(html) == 1
      refute html =~ "data-review-behaviour-test-name"
      refute html =~ "data-review-behaviour-type"
      assert html =~ "data-review-behaviour-pill"
    end

    test "renders a single row" do
      html = render_matrix([row()])

      assert row_count(html) == 1
    end

    test "wraps long behaviour and test-name text" do
      long_behaviour = String.duplicate("behaviour ", 40)
      long_test_name = String.duplicate("test_name_segment_", 25)

      html =
        render_matrix([
          row(%{"behaviour" => long_behaviour, "test_name" => long_test_name})
        ])

      assert html =~ "overflow-wrap: anywhere"
      assert html =~ "behaviour behaviour"
      assert html =~ "test_name_segment_test_name_segment_"
    end

    test "renders nothing when the matrix verdict is absent" do
      html =
        render_task(%{reviewer_result: %{"security_considerations" => %{"status" => "passed"}}})

      refute html =~ "data-review-behaviour-matrix"
      refute html =~ "data-review-behaviour-row"
    end

    test "renders nothing when rows is empty" do
      html = render_matrix([])

      refute html =~ "data-review-behaviour-matrix"
      refute html =~ "data-review-behaviour-row"
    end

    test "renders nothing when every row is malformed" do
      html = render_matrix(["nope", %{"behaviour" => "no category"}])

      refute html =~ "data-review-behaviour-matrix"
      refute html =~ "data-review-behaviour-row"
    end

    test "renders nothing when reviewer_result is nil" do
      html = render_task(%{reviewer_result: nil})

      refute html =~ "data-review-behaviour-matrix"
    end

    test "escapes agent-supplied row strings (no XSS)" do
      html =
        render_matrix([
          row(%{
            "behaviour" => "<script>alert('xss')</script>",
            "test_name" => "<img src=x onerror=alert(1)>",
            "type" => "<b>unit</b>"
          })
        ])

      refute html =~ "<script>alert('xss')</script>"
      refute html =~ "<img src=x onerror=alert(1)>"
      assert html =~ "&lt;script&gt;"
      assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
      assert html =~ "&lt;b&gt;unit&lt;/b&gt;"
    end

    test "escapes an unrecognized category (W1947)" do
      # `category` is NOT enum-checked on the completion-echo path (only
      # non-blank), and an unknown value falls through BehaviourTestLabels'
      # catch-all clause unchanged — so the render site is the only thing
      # escaping it. (`na_reason` is not rendered by this panel; its escaping is
      # covered on the persisted path in view_component_test.exs.)
      html = render_matrix([row(%{"category" => "<script>alert('cat')</script>"})])

      refute html =~ "<script>alert('cat')</script>"
      assert html =~ "&lt;script&gt;alert(&#39;cat&#39;)&lt;/script&gt;"
    end

    test "escapes a row value interpolated into an attribute (W1947)" do
      # `status` is the one row value that reaches an attribute
      # (data-review-behaviour-status), so a quote-breaking payload must not be
      # able to close the attribute and open a new one.
      html = render_matrix([row(%{"status" => ~s|" onmouseover="alert(1)|})])

      refute html =~ ~s|onmouseover="alert(1)"|
      assert html =~ "&quot;"
    end

    test "uses only theme-aware tokens (no hardcoded grays or whites)" do
      html =
        render_matrix([
          row(%{"status" => "passing"}),
          row(%{"status" => "failing"}),
          row(%{"status" => "planned"}),
          row(%{"status" => "not_applicable"}),
          row(%{"status" => "bogus"})
        ])

      refute html =~ "text-gray-"
      refute html =~ "bg-gray-"
      refute html =~ "bg-white"
      refute html =~ ~r/border-gray-\d+/
    end
  end

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        "category" => "Boundary",
        "behaviour" => "keeps the row",
        "test_name" => "keeps the row test",
        "type" => "unit",
        "status" => "passing"
      },
      overrides
    )
  end

  defp render_matrix(rows) do
    render_task(%{
      reviewer_result: %{"behaviour_test_matrix" => %{"status" => "passed", "rows" => rows}}
    })
  end

  defp render_task(task) do
    assigns = %{task: task}

    rendered_to_string(~H"""
    <ReviewBehaviourMatrixPanel.review_behaviour_matrix task={@task} />
    """)
  end

  defp row_count(html) do
    ~r/data-review-behaviour-row/ |> Regex.scan(html) |> length()
  end
end
