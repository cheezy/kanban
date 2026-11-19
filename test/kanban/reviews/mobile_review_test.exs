defmodule Kanban.Reviews.MobileReviewTest do
  use ExUnit.Case, async: true

  alias Kanban.ChangedFiles.Backfill
  alias Kanban.Reviews.MobileReview
  alias Kanban.Tasks.Task
  alias KanbanWeb.ReviewAcceptance
  alias KanbanWeb.ReviewReportHelpers

  defp added(n), do: Enum.map_join(1..n//1, "\n", &"+line #{&1}")

  defp entry(path, diff), do: %{"path" => path, "diff" => diff, "diff_url" => nil}

  defp task(attrs) do
    struct!(%Task{id: 1, changed_files: [], actual_files_changed: nil}, attrs)
  end

  defp build(task, device_class \\ :phone, dependents \\ []),
    do: MobileReview.build(task, dependents, device_class)

  defp paths(review), do: Enum.map(review.files, & &1.path)

  describe "files and flags" do
    test "flags files named by an issue or the security section and lists them first" do
      review =
        task(%{
          security_considerations: ["Scope the query"],
          changed_files: [
            entry("lib/a.ex", "+a"),
            entry("lib/b.ex", "+b"),
            entry("lib/c.ex", "+c"),
            entry("lib/d.ex", "+d")
          ],
          reviewer_result: %{
            "issues" => [
              %{"severity" => "minor", "category" => "pattern", "file" => "./lib/b.ex:12"}
            ],
            "security_considerations" => %{
              "status" => "passed",
              "considerations" => [
                %{
                  "consideration" => "Scope the query",
                  "status" => "partial",
                  "evidence" => "lib/c.ex reads every board"
                },
                %{
                  "consideration" => "Mitigated one",
                  "status" => "mitigated",
                  "evidence" => "lib/d.ex is scoped"
                }
              ]
            }
          }
        })
        |> build()

      assert paths(review) == ["lib/b.ex", "lib/c.ex", "lib/a.ex", "lib/d.ex"]

      assert [
               %{path: "lib/b.ex", flagged: true, flag_reason: :issue, index: 1},
               %{path: "lib/c.ex", flagged: true, flag_reason: :security, index: 2},
               %{path: "lib/a.ex", flagged: false, flag_reason: nil, index: 0},
               %{path: "lib/d.ex", flagged: false, flag_reason: nil}
             ] = review.files
    end

    test "a security issue's file is flagged for security, and security outranks an issue" do
      review =
        task(%{
          changed_files: [entry("lib/a.ex", "+a"), entry("lib/b.ex", "+b")],
          reviewer_result: %{
            "issues" => [
              %{"category" => "security", "severity" => "important", "file" => "lib/a.ex"},
              %{"category" => "testing", "severity" => "minor", "file" => "lib/a.ex:3:1"}
            ]
          }
        })
        |> build()

      assert [%{path: "lib/a.ex", flag_reason: :security}, %{path: "lib/b.ex", flagged: false}] =
               review.files
    end

    test "the failed security note names a file; a passing note or a longer path does not" do
      result = fn status ->
        %{
          "security_considerations" => %{
            "status" => status,
            "note" => "lib/a.ex skips the board check; see lib/a.ex.bak too"
          }
        }
      end

      files = [entry("lib/a.ex", "+a"), entry("lib/a.e", "+b")]

      failed = task(%{changed_files: files, reviewer_result: result.("failed")}) |> build()
      assert [%{path: "lib/a.ex", flag_reason: :security}, %{flagged: false}] = failed.files

      passed = task(%{changed_files: files, reviewer_result: result.("passed")}) |> build()
      assert Enum.all?(passed.files, &(not &1.flagged))
    end

    test "an issue whose file is not in changed_files flags nothing and adds no file" do
      review =
        task(%{
          changed_files: [entry("lib/a.ex", "+a")],
          reviewer_result: %{"issues" => [%{"category" => "pattern", "file" => "lib/other.ex"}]}
        })
        |> build()

      assert [%{path: "lib/a.ex", flagged: false}] = review.files
    end

    test "issues from an older schema without file fields leave files in diff order" do
      review =
        task(%{
          changed_files: [entry("lib/z.ex", "+z"), entry("lib/a.ex", "+a")],
          reviewer_result: %{
            "issues" => [
              %{"category" => "pattern", "severity" => "minor", "description" => "x"},
              %{"category" => "pattern", "file" => 12},
              "not a map"
            ]
          }
        })
        |> build()

      assert paths(review) == ["lib/z.ex", "lib/a.ex"]
      assert Enum.all?(review.files, &(not &1.flagged))
    end

    test "counts additions and deletions per file and marks a capped diff" do
      capped = added(3) <> "\n" <> Backfill.truncation_marker()

      review =
        task(%{
          changed_files: [
            entry("lib/a.ex", "@@ -1,2 +1,3 @@\n ctx\n-old\n+new\n+more"),
            entry("lib/b.ex", capped),
            entry("lib/a.ex", "+again"),
            %{"path" => "lib/c.ex", "diff" => nil},
            %{"path" => "  "},
            :junk
          ]
        })
        |> build()

      assert [
               %{path: "lib/a.ex", index: 0, additions: 3, deletions: 1, truncated: false},
               %{path: "lib/b.ex", index: 1, additions: 3, deletions: 0, truncated: true},
               %{path: "lib/c.ex", index: 3, additions: nil, deletions: nil, truncated: false}
             ] = review.files

      assert review.size == %{files: 3, changed_lines: 7, truncated: true, large_change: true}

      file_lines =
        review.files
        |> Enum.map(&((&1.additions || 0) + (&1.deletions || 0)))
        |> Enum.sum()

      assert file_lines == review.size.changed_lines
    end

    test "with no stored diffs the files come from actual_files_changed" do
      review = task(%{actual_files_changed: "lib/a.ex, lib/b.ex,lib/a.ex,"}) |> build()

      assert [
               %{path: "lib/a.ex", index: nil, additions: nil, flagged: false},
               %{path: "lib/b.ex", index: nil, deletions: nil}
             ] = review.files

      assert review.size.files == 2
    end

    test "an issue file written with a diff prefix, an absolute path or a location suffix flags the file" do
      for file <- [
            "b/lib/a.ex",
            "a/lib/a.ex",
            "/home/dev/project/lib/a.ex",
            "lib\\a.ex",
            "lib//a.ex",
            "lib/./a.ex",
            ".//lib/a.ex",
            "././lib/a.ex",
            "lib/a.ex:12-15",
            "lib/a.ex#L12",
            "lib/a.ex:",
            "lib/a.ex:12:3:4"
          ] do
        review =
          task(%{
            changed_files: [entry("lib/c.ex", "+c"), entry("lib/a.ex", "+a")],
            reviewer_result: %{
              "issues" => [%{"severity" => "critical", "category" => "security", "file" => file}]
            }
          })
          |> build()

        assert [%{path: "lib/a.ex", flagged: true, flag_reason: :security}, %{flagged: false}] =
                 review.files,
               "expected #{inspect(file)} to flag lib/a.ex"
      end
    end

    test "an issue path that only shares a file name does not flag a longer listed path" do
      review =
        task(%{
          changed_files: [entry("lib/kanban/a.ex", "+a")],
          reviewer_result: %{"issues" => [%{"severity" => "minor", "file" => "a.ex"}]}
        })
        |> build()

      assert [%{path: "lib/kanban/a.ex", flagged: false}] = review.files
    end

    test "security text naming a file as ./path flags it" do
      review =
        task(%{
          security_considerations: ["Validate input"],
          changed_files: [entry("lib/c.ex", "+c"), entry("lib/a.ex", "+a")],
          reviewer_result: %{
            "security_considerations" => %{
              "considerations" => [
                %{
                  "consideration" => "Validate input",
                  "status" => "partial",
                  "evidence" => "Check ./lib/a.ex for input"
                }
              ]
            }
          }
        })
        |> build()

      assert ["lib/a.ex", "lib/c.ex"] = paths(review)
      assert [%{flag_reason: :security}, %{flagged: false}] = review.files
    end

    test "two stored spellings of one path are one file with summed counts" do
      review =
        task(%{
          changed_files: [
            entry("./lib/a.ex", "+a"),
            entry("lib/a.ex", "+b\n-c"),
            entry("lib/c.ex", "+c")
          ],
          reviewer_result: %{"issues" => [%{"severity" => "minor", "file" => "lib/a.ex"}]}
        })
        |> build()

      assert [
               %{index: 0, path: "lib/a.ex", additions: 2, deletions: 1, flag_reason: :issue},
               %{index: 2, path: "lib/c.ex", flagged: false}
             ] = review.files
    end

    test "an entry with no usable path is left out of files but counted in size" do
      review =
        task(%{changed_files: [%{"path" => 7, "diff" => added(600)}, entry("lib/a.ex", "+a")]})
        |> build()

      assert [%{index: 1, path: "lib/a.ex", additions: 1}] = review.files
      assert %{changed_lines: 601, large_change: true} = review.size
      refute review.approvable_here
    end
  end

  describe "approvable_here" do
    test "approvable_here is false with too_large_for_phone on a phone and true on a tablet" do
      many_files = task(%{changed_files: Enum.map(1..11, &entry("lib/f#{&1}.ex", "+x"))})
      many_lines = task(%{changed_files: [entry("lib/a.ex", added(501))]})
      capped = task(%{changed_files: [entry("lib/a.ex", "+x\n" <> Backfill.truncation_marker())]})

      for large <- [many_files, many_lines, capped] do
        assert %{approvable_here: false, approvable_here_reason: :too_large_for_phone} =
                 build(large, :phone)

        assert %{approvable_here: true, approvable_here_reason: nil} = build(large, :tablet)
        assert %{approvable_here: true, approvable_here_reason: nil} = build(large, nil)
        assert build(large, :phone).size.large_change
      end

      small = task(%{changed_files: [entry("lib/a.ex", added(500))]})
      assert %{approvable_here: true, approvable_here_reason: nil} = build(small, :phone)
    end
  end

  describe "verdicts and details" do
    test "a task with no reviewer_result returns empty verdicts, not an error" do
      for result <- [nil, %{"dispatched" => false}] do
        review = task(%{reviewer_result: result, acceptance_criteria: nil}) |> build()

        assert review.verdicts == []
        assert review.acceptance_criteria == []
        assert review.security_considerations == []
        assert review.behaviour_matrix == []
        assert review.files == []
        assert review.holds_up == []
        assert review.security_findings == %{"critical" => 0, "important" => 0, "minor" => 0}
        assert review.project_checks == %{"met" => 0, "not_met" => 0, "not_applicable" => 0}
        assert review.exploratory == %{count: nil, note: "see_notes_on_web"}
        assert review.summary == nil
        assert review.approvable_here
      end
    end

    test "the verdicts match the ones /review shows for the same task" do
      task =
        task(%{
          acceptance_criteria: "One\nTwo",
          pitfalls: ["Don't"],
          patterns_to_follow: "Follow",
          security_considerations: ["Scope"],
          reviewer_result: %{
            "status" => "changes_requested",
            "testing_strategy" => %{"status" => "passed", "note" => "  Good tests  "},
            "patterns" => %{"status" => "failed", "note" => "Query in the LiveView"},
            "issues" => [%{"category" => "security", "severity" => "critical"}]
          }
        })

      review = build(task)

      assert [
               %{section: :acceptance_criteria, status: "failed", note: nil},
               %{section: :testing_strategy, status: "passed", note: "Good tests"},
               %{section: :patterns, status: "failed", note: "Query in the LiveView"},
               %{section: :pitfalls, status: "passed", note: nil},
               %{section: :security_considerations, status: "failed", note: nil}
             ] = review.verdicts

      assert ReviewAcceptance.acceptance_passed(task) == false

      for %{section: section, status: status} <- tl(review.verdicts) do
        assert status == ReviewReportHelpers.section_status(task, section)
      end

      assert review.security_findings == %{"critical" => 1, "important" => 0, "minor" => 0}
    end

    test "acceptance criteria prefer the structured list, else the task's lines" do
      structured =
        task(%{
          acceptance_criteria: "One\nTwo",
          reviewer_result: %{
            "acceptance_criteria" => [
              %{"criterion" => "One", "status" => "met", "evidence" => "test/a_test.exs"},
              %{"criterion" => "  ", "status" => "met"},
              %{"criterion" => "Two", "status" => 3, "note" => "Partly"}
            ]
          }
        })
        |> build()

      assert structured.acceptance_criteria == [
               %{criterion: "One", status: "met", evidence: "test/a_test.exs"},
               %{criterion: nil, status: "met", evidence: nil},
               %{criterion: "Two", status: nil, evidence: "Partly"}
             ]

      lines = task(%{acceptance_criteria: "One\n\n  Two  \n", reviewer_result: nil}) |> build()

      assert lines.acceptance_criteria == [
               %{criterion: "One", status: nil, evidence: nil},
               %{criterion: "Two", status: nil, evidence: nil}
             ]
    end

    test "a not_met criterion with non-string or blank text keeps its status" do
      review =
        task(%{
          acceptance_criteria: "A\nB",
          reviewer_result: %{
            "acceptance_criteria" => [
              %{"criterion" => "A", "status" => "met"},
              %{"criterion" => 42, "status" => "not_met"},
              %{"criterion" => %{"text" => "B"}, "status" => "not_met"}
            ]
          }
        })
        |> build()

      assert review.acceptance_criteria == [
               %{criterion: "A", status: "met", evidence: nil},
               %{criterion: "42", status: "not_met", evidence: nil},
               %{criterion: nil, status: "not_met", evidence: nil}
             ]

      blank =
        task(%{
          acceptance_criteria: "A",
          reviewer_result: %{
            "acceptance_criteria" => [%{"criterion" => "  ", "status" => "not_met"}]
          }
        })
        |> build()

      assert blank.acceptance_criteria == [%{criterion: nil, status: "not_met", evidence: nil}]
    end

    test "a security issue with an unknown severity counts as minor, as /review groups it" do
      review =
        task(%{
          reviewer_result: %{
            "issues" => [
              %{"category" => "security", "severity" => 3},
              %{"category" => "security", "severity" => "high"},
              %{"category" => "security", "severity" => "critical"},
              %{"category" => "pattern", "severity" => "important"}
            ]
          }
        })
        |> build()

      assert review.security_findings == %{"critical" => 1, "important" => 0, "minor" => 2}
    end

    test "security considerations prefer the reviewer's breakdown, else the task's list" do
      breakdown =
        task(%{
          security_considerations: ["Scope"],
          reviewer_result: %{
            "security_considerations" => %{
              "considerations" => [
                %{"consideration" => "Scope", "status" => "mitigated", "evidence" => "Scoped"}
              ]
            }
          }
        })
        |> build()

      assert breakdown.security_considerations == [
               %{consideration: "Scope", status: "mitigated", detail: "Scoped"}
             ]

      listed = task(%{security_considerations: ["Scope"], reviewer_result: nil}) |> build()

      assert listed.security_considerations == [
               %{consideration: "Scope", status: nil, detail: nil}
             ]
    end

    test "counts project checks by status and reads the summary and behaviour matrix" do
      review =
        task(%{
          completion_summary: "  Did the thing  ",
          reviewer_result: %{
            "project_checks" => [
              %{"status" => "met"},
              %{"status" => "met"},
              %{"status" => "not_met"},
              %{"status" => "not_applicable"},
              %{"status" => "odd"},
              "junk"
            ],
            "behaviour_test_matrix" => %{
              "rows" => [
                %{"category" => "Happy path", "behaviour" => "Works", "status" => "passing"}
              ]
            }
          }
        })
        |> build()

      assert review.summary == "Did the thing"
      assert review.project_checks == %{"met" => 2, "not_met" => 1, "not_applicable" => 1}

      assert [%{category: "Happy path", behaviour: "Works", status: "passing"}] =
               review.behaviour_matrix
    end
  end

  describe "holds_up and timestamps" do
    test "holds_up lists the unfinished dependents by id" do
      dependents = [
        %Task{id: 9, identifier: "W9", status: :open},
        %Task{id: 3, identifier: "W3", status: :completed},
        %Task{id: 4, identifier: "W4", status: :in_progress}
      ]

      review = build(task(%{}), :phone, dependents)

      assert Enum.map(review.holds_up, & &1.identifier) == ["W4", "W9"]
    end

    test "review_requested_at is the raw stamp and waiting_since falls back to updated_at" do
      at = ~U[2026-11-18 10:00:00Z]
      stamped = task(%{review_requested_at: at, updated_at: ~N[2026-11-17 09:00:00]}) |> build()

      assert stamped.review_requested_at == at
      assert stamped.waiting_since == at

      unstamped =
        task(%{review_requested_at: nil, updated_at: ~N[2026-11-17 09:00:00]}) |> build()

      assert unstamped.review_requested_at == nil
      assert unstamped.waiting_since == ~U[2026-11-17 09:00:00Z]
    end
  end
end
