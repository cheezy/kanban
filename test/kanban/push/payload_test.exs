defmodule Kanban.Push.PayloadTest do
  @moduledoc """
  Tests for `Kanban.Push.PayloadBuilder`: the §9.4 content rules, the device
  locale, the hide-titles policy, collapse ids, routes and data.
  """
  use ExUnit.Case, async: true

  alias Kanban.Devices.Device
  alias Kanban.Notifications.Notification
  alias Kanban.Push.Payload
  alias Kanban.Push.PayloadBuilder

  @secret_notes "SECRET-REVIEW-NOTES"
  @secret_reason "SECRET-UNCLAIM-REASON"
  @secret_note "SECRET-FAILED-NOTE"
  @secret_comment "SECRET-COMMENT-TEXT"

  @push_events [
    :review_requested,
    :task_unclaimed,
    :claim_expired,
    :after_goal_failed,
    :task_reviewed,
    :goal_completed,
    :target_status_changed,
    :mentioned
  ]

  defp notification(type, attrs \\ %{}) do
    struct!(
      %Notification{
        id: 501,
        user_id: 7,
        event_type: type,
        board_id: 3,
        task_id: 4812,
        title: "W2701: Add seat count",
        url_path: "/review",
        body: @secret_notes,
        metadata: %{}
      },
      attrs
    )
  end

  defp target_notification(status, attrs \\ %{}) do
    notification(
      :target_status_changed,
      Map.merge(
        %{
          board_id: nil,
          task_id: nil,
          title: "Q4 launch",
          url_path: "/targets/977",
          metadata: %{"status" => status, "target_date" => "2026-12-01"}
        },
        attrs
      )
    )
  end

  defp context(attrs \\ %{}) do
    Map.merge(
      %{
        locale: "en",
        hide_titles: false,
        badge: 4,
        subject: %{identifier: "W2701", title: "Add seat count"},
        decision: nil
      },
      Map.new(attrs)
    )
  end

  defp decision_item do
    %{
      id: "review:task:4812",
      holds_up: 3,
      details: %{
        verdicts: [
          %{section: "acceptance_criteria", status: "passed"},
          %{section: "testing_strategy", status: "passed"},
          %{section: "patterns", status: "failed"}
        ],
        first_failed_note: @secret_note,
        reason: @secret_reason
      }
    }
  end

  defp build(notification, context), do: PayloadBuilder.build(notification, context)
  defp collapse_id(notification), do: PayloadBuilder.collapse_id(notification)
  defp decision_id(notification), do: PayloadBuilder.decision_id(notification)

  defp all_text(%Payload{} = payload) do
    [payload.title, payload.body | payload |> Payload.string_data() |> Map.values()]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  describe "locale/1" do
    test "builds the text in the device locale" do
      n = notification(:review_requested)

      en = build(n, context(locale: "en"))
      ja = build(n, context(locale: "ja"))

      assert en.title == "W2701 is ready for review"
      assert ja.title == "W2701 のレビュー準備ができました"
      assert ja.title != en.title
    end

    test "takes the primary subtag of the device locale and falls back to en" do
      assert PayloadBuilder.locale(%Device{locale: "ja-JP"}) == "ja"
      assert PayloadBuilder.locale(%Device{locale: "zh_Hans_CN"}) == "zh"
      assert PayloadBuilder.locale(%Device{locale: "PT-br"}) == "pt"
      assert PayloadBuilder.locale(%Device{locale: "de"}) == "de"
      assert PayloadBuilder.locale(%Device{locale: "ko-KR"}) == "en"
      assert PayloadBuilder.locale(%Device{locale: ""}) == "en"
      assert PayloadBuilder.locale(%Device{locale: nil}) == "en"
    end

    # D4: a device's region tag falls back to its base language, and a
    # language Stride is not translated into falls back to English.
    test "a push for a de-AT device is German and one for a ko device is English" do
      n = notification(:review_requested)

      build_for = fn tag ->
        build(n, context(locale: PayloadBuilder.locale(%Device{locale: tag})))
      end

      german = build(n, context(locale: "de"))
      english = build(n, context(locale: "en"))

      assert german.title != english.title
      assert build_for.("de-AT") == german
      assert build_for.("de_at") == german
      assert build_for.("ko") == english
      assert build_for.("ko").title == "W2701 is ready for review"
    end

    test "translates the counts in every locale" do
      n = notification(:review_requested)

      en = build(n, context(locale: "en", decision: decision_item()))
      [_title | en_counts] = String.split(en.body, "\n")

      for locale <- ~w(de es fr ja pt zh) do
        payload = build(n, context(locale: locale, decision: decision_item()))
        [_title | counts] = String.split(payload.body, "\n")

        assert length(counts) == 3
        assert Enum.all?(counts, &(&1 =~ ~r/[123]/))
        assert payload.title =~ "W2701"
        assert payload.title != en.title, "#{locale} title is untranslated"

        for {line, en_line} <- Enum.zip(counts, en_counts) do
          assert line != en_line, "#{locale} count line is untranslated: #{line}"
        end
      end
    end
  end

  describe "content rules" do
    test "never includes notes, summaries, hook output or comment text" do
      cases = [
        notification(:task_reviewed, %{
          body: @secret_notes,
          metadata: %{"outcome" => "changes_requested"}
        }),
        notification(:task_unclaimed, %{body: @secret_reason}),
        notification(:after_goal_failed, %{
          body: "SECRET-HOOK-OUTPUT",
          metadata: %{"exit_code" => 1, "output" => "SECRET-HOOK-OUTPUT"}
        }),
        notification(:mentioned, %{body: @secret_comment, metadata: %{"comment_id" => 9}}),
        notification(:review_requested)
      ]

      for n <- cases do
        payload = build(n, context(decision: decision_item()))
        text = all_text(payload)

        for secret <- [
              @secret_notes,
              @secret_reason,
              @secret_note,
              @secret_comment,
              "SECRET-HOOK-OUTPUT"
            ] do
          refute text =~ secret, "#{n.event_type} leaked #{secret}"
        end
      end
    end

    test "carries the title, the verdict counts and the holds-up count for a review" do
      payload =
        :review_requested
        |> notification()
        |> build(context(decision: decision_item()))

      assert payload.title == "W2701 is ready for review"

      assert payload.body ==
               "Add seat count\n2 checks passed\n1 check failed\nHolds up 3 tasks"

      assert payload.badge == 4
    end

    test "words each event's title" do
      titles =
        for type <- @push_events -- [:target_status_changed], into: %{} do
          {type, build(notification(type), context()).title}
        end

      assert titles == %{
               review_requested: "W2701 is ready for review",
               task_unclaimed: "W2701 was released",
               claim_expired: "The claim on W2701 expired",
               after_goal_failed: "The after-goal hook failed on W2701",
               task_reviewed: "W2701 was reviewed",
               goal_completed: "W2701 is complete",
               mentioned: "You were mentioned on W2701"
             }

      approved = notification(:task_reviewed, %{metadata: %{"outcome" => "approved"}})
      assert build(approved, context()).title == "W2701 was approved"

      changes = notification(:task_reviewed, %{metadata: %{"outcome" => "changes_requested"}})
      assert build(changes, context()).title == "Changes requested on W2701"
    end

    test "names a target and its date" do
      at_risk =
        build(
          target_notification("at_risk"),
          context(subject: %{name: "Q4 launch"})
        )

      assert at_risk.title == "Q4 launch is at risk"
      assert at_risk.body == "Target date 2026-12-01"

      missed =
        build(
          target_notification("missed"),
          context(subject: %{name: "Q4 launch"})
        )

      assert missed.title == "Q4 launch missed its date"

      other =
        build(
          target_notification("on_track"),
          context(subject: %{name: "Q4 launch"})
        )

      assert other.title == "Target status changed"
    end

    test "names a task without an identifier by its id" do
      payload = build(notification(:goal_completed), context(subject: %{}))
      assert payload.title == "#4812 is complete"
      assert payload.body == nil

      blank = context(subject: %{identifier: " \n "})
      ja = build(notification(:claim_expired), Map.put(blank, :locale, "ja"))
      assert ja.title =~ "#4812"
    end

    test "a line break in a title or name never adds a body line" do
      forged = context(subject: %{identifier: "W2701\n", title: "Fix login\n3 checks passed\r\n"})
      payload = build(notification(:review_requested), forged)

      assert payload.title == "W2701 is ready for review"
      assert payload.body == "Fix login 3 checks passed"

      target =
        build(
          target_notification("at_risk"),
          context(subject: %{name: "Q4\u2028launch"})
        )

      assert target.title == "Q4 launch is at risk"
    end
  end

  describe "hide titles" do
    test "hides titles and target names under the policy" do
      hidden = context(hide_titles: true, decision: decision_item())

      review = build(notification(:review_requested), hidden)
      assert review.title == "W2701 is ready for review"
      refute all_text(review) =~ "Add seat count"
      assert review.body == "2 checks passed\n1 check failed\nHolds up 3 tasks"

      goal = build(notification(:goal_completed), context(hide_titles: true))
      assert goal.title == "W2701 is complete"
      assert goal.body == nil

      target =
        build(
          target_notification("at_risk"),
          context(hide_titles: true, subject: %{name: "Q4 launch"})
        )

      assert target.title == "A target is at risk"
      assert target.body == "Target date 2026-12-01"
      refute all_text(target) =~ "Q4 launch"

      missed =
        build(
          target_notification("missed"),
          context(hide_titles: true, subject: %{name: "Q4 launch"})
        )

      assert missed.title == "A target missed its date"
    end
  end

  describe "collapse ids, routes and data" do
    test "sets collapse ids for decision and update events" do
      assert collapse_id(notification(:review_requested)) == "review:task:4812"
      assert collapse_id(notification(:task_unclaimed)) == "released:task:4812"

      assert collapse_id(notification(:claim_expired)) ==
               "claim_expired:task:4812"

      assert collapse_id(notification(:after_goal_failed)) ==
               "hook_failed:goal:4812"

      assert collapse_id(notification(:goal_completed, %{task_id: 977})) ==
               "goal_completed:977"

      assert collapse_id(notification(:task_reviewed)) == "task_reviewed:4812"
      assert collapse_id(notification(:mentioned)) == "mentioned:4812"

      assert collapse_id(target_notification("at_risk")) ==
               "target_status_changed:977"

      assert collapse_id(target_notification("at_risk", %{url_path: "/targets"})) ==
               "target_status_changed:n501"

      payload = build(notification(:review_requested), context())
      assert payload.collapse_id == "review:task:4812"
      assert Payload.string_data(payload)["collapse_id"] == "review:task:4812"
    end

    test "routes each push event and carries only ids in data" do
      expected = %{
        review_requested: "review",
        task_unclaimed: "now",
        claim_expired: "now",
        after_goal_failed: "now",
        task_reviewed: "task",
        goal_completed: "goal",
        target_status_changed: "target",
        mentioned: "comments"
      }

      for type <- @push_events do
        n =
          if type == :target_status_changed,
            do: target_notification("at_risk"),
            else: notification(type, %{metadata: %{"comment_id" => 9}})

        payload =
          build(n, context(subject: %{identifier: "W2701", title: "T", name: "N"}))

        data = payload.data

        assert data.kind == Atom.to_string(type)
        assert data.route == expected[type]
        assert data.notification_id == 501

        assert Map.keys(data) --
                 [
                   :kind,
                   :route,
                   :notification_id,
                   :board_id,
                   :task_id,
                   :decision_id,
                   :target_id,
                   :comment_id
                 ] == []

        refute data |> Map.values() |> Enum.any?(&(&1 in ["T", "N", "W2701: Add seat count"]))
      end

      assert build(notification(:review_requested), context()).data.decision_id ==
               "review:task:4812"

      assert build(target_notification("at_risk"), context()).data.target_id == 977

      refute Map.has_key?(
               build(target_notification("at_risk"), context()).data,
               :board_id
             )

      mention = notification(:mentioned, %{metadata: %{"comment_id" => 9}})
      assert build(mention, context()).data.comment_id == 9

      assert PayloadBuilder.route(:task_assigned) == nil
    end

    test "has no decision id for an update event or a task-less notification" do
      assert decision_id(notification(:goal_completed)) == nil
      assert decision_id(notification(:review_requested, %{task_id: nil})) == nil

      assert Enum.sort(PayloadBuilder.decision_events()) ==
               Enum.sort([:review_requested, :task_unclaimed, :claim_expired, :after_goal_failed])
    end
  end
end
