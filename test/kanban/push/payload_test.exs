defmodule Kanban.Push.PayloadTest do
  @moduledoc """
  Tests for `Kanban.Push.PayloadBuilder`: the §9.4 content rules, the device
  locale, the hide-titles policy, collapse ids, routes and data.
  """
  use ExUnit.Case, async: true

  alias Kanban.Devices.Device
  alias Kanban.Notifications.Notification
  alias Kanban.Push.APNs
  alias Kanban.Push.FCM
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

  defp review_body(title) do
    build(
      notification(:review_requested),
      context(subject: %{identifier: "W2701", title: title})
    ).body
  end

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

    # D464: a bidi override, isolate, zero-width space or direction mark in a
    # title would otherwise reach the lock screen, where "Pay" + U+202E +
    # "invoice" reads as something other than the title.
    @format_chars [
      {"U+202E", "\u202E"},
      {"U+2066", "\u2066"},
      {"U+200B", "\u200B"},
      {"U+200F", "\u200F"}
    ]

    test "a title containing U+202E, U+2066, U+200B or U+200F reaches the push text without it" do
      for {name, char} <- @format_chars do
        subject = %{identifier: "W2701#{char}", title: "Pay#{char}invoice"}

        for type <- @push_events -- [:target_status_changed] do
          payload = build(notification(type), context(subject: subject))
          text = all_text(payload)

          refute String.contains?(text, char), "#{type} kept #{name}"
          assert payload.title =~ "W2701"
          assert payload.body == "Payinvoice", "#{type} body with #{name}"
        end

        target =
          build(
            target_notification("at_risk"),
            context(subject: %{name: "Q4#{char} launch"})
          )

        refute target |> all_text() |> String.contains?(char), "target name kept #{name}"
        assert target.title == "Q4 launch is at risk"
      end
    end

    test "a title that is only format characters falls back as an empty title does" do
      only_format = Enum.map_join(@format_chars, fn {_name, char} -> char end)

      for invisible <- [
            only_format,
            "\u200D",
            " \u200C\u200B\n",
            "\u2066\u2069",
            "\uFE0F",
            "\u{E0101}",
            "\u3164\u034F",
            "\u{E0067}\u{E007F}"
          ] do
        review =
          build(
            notification(:review_requested),
            context(subject: %{identifier: invisible, title: invisible})
          )

        assert review.title == "#4812 is ready for review"
        assert review.body == nil

        target =
          build(target_notification("at_risk"), context(subject: %{name: invisible}))

        assert target.title == "A target is at risk"
      end
    end

    test "ordinary accented, CJK and emoji titles are unchanged" do
      titles = [
        "Réviser la façade",
        "Überprüfung der Größe",
        "レビュー準備を追加",
        "添加座位数",
        "Ship it 🚀",
        "Family 👨\u200D👩\u200D👧 emoji",
        "Flag 🏳️\u200D🌈 emoji",
        "می\u200Cخواهم",
        "مرحبا بالعالم"
      ]

      for title <- titles do
        payload =
          build(
            notification(:review_requested),
            context(subject: %{identifier: "W2701", title: title})
          )

        assert payload.title == "W2701 is ready for review"
        assert payload.body == title

        target = build(target_notification("at_risk"), context(subject: %{name: title}))
        assert target.title == "#{title} is at risk"
      end
    end

    # D464: what one_line/1 keeps of the format characters, and why each.
    test "England, Scotland and Wales flags keep their tag sequence" do
      england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
      scotland = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
      wales = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}"

      for flag <- [england, scotland, wales] do
        assert review_body("Go #{flag} team") == "Go #{flag} team"

        target = build(target_notification("at_risk"), context(subject: %{name: flag}))
        assert target.title == "#{flag} is at risk"
      end

      assert review_body("Pay\u{E0041}invoice") == "Payinvoice"
      assert review_body("\u{1F3F4}\u{E0067}\u{E0062} unterminated") == "\u{1F3F4} unterminated"
    end

    test "visible prepended marks and hieroglyph controls are kept" do
      for title <- [
            "\u0600\u0661\u0662\u0663",
            "\u06DD\u0661",
            "\u070F\u0710\u0712",
            "\u0890\u0661",
            "\u08E2\u0661",
            "\u{11083}\u{110BD}\u{11083}",
            "\u{13000}\u{13430}\u{13001}"
          ] do
        assert review_body(title) == title
      end
    end

    test "a removed character never fuses its neighbours into one" do
      assert review_body("Up \u{1F44D}\u200B\u{1F3FD} done") == "Up \u{1F44D} \u{1F3FD} done"
      assert review_body("\u{1F1FA}\u2060\u{1F1F8} team") == "\u{1F1FA} \u{1F1F8} team"
      assert review_body("e\u202E\u0301") == "e \u0301"

      # A lone indicator must not re-pair the flag after it: A + US would
      # otherwise show as the Australian flag and a lone S.
      assert review_body("\u{1F1E6}\u2060\u{1F1FA}\u{1F1F8}") == "\u{1F1E6} \u{1F1FA}\u{1F1F8}"
      assert review_body("\u{1F1FA}\u2060\u{1F1F8}\u{1F1EA}") == "\u{1F1FA} \u{1F1F8}\u{1F1EA}"

      assert review_body("\u{1F1FA}\u{1F1F8} \u{1F1E6}\u200B\u{1F1FA}\u{1F1F8}") ==
               "\u{1F1FA}\u{1F1F8} \u{1F1E6} \u{1F1FA}\u{1F1F8}"

      assert review_body("Pay\u200Binvoice") == "Payinvoice"
    end

    test "a title cut at the length cap never ends in a space or shows nothing" do
      assert review_body(String.duplicate("a", 159) <> " tail") == String.duplicate("a", 159)
      assert review_body(String.duplicate("\u3164", 160) <> "tail") == nil
    end
  end

  # D468: a grapheme has no byte bound, so each free-text piece is also
  # capped by bytes (512 for a title or name, 128 for an identifier) to keep
  # the APNs and FCM payload under their 4 KB limit.
  describe "byte bound" do
    @family "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}"
    @flood "e" <> String.duplicate("\u0301", 5_000)

    defp target_title(name),
      do: build(target_notification("at_risk"), context(subject: %{name: name})).title

    defp review_title(identifier) do
      build(
        notification(:review_requested),
        context(subject: %{identifier: identifier, title: "Add seat count"})
      ).title
    end

    defp encoded_sizes(%Payload{} = payload) do
      apns = APNs.build_notification(%Device{push_token: "t"}, payload, "com.example.app")
      fcm = FCM.build_notification(%Device{push_token: "t"}, payload)

      fcm_message = %{
        message: %{
          token: "t",
          notification: fcm.notification,
          data: fcm.data,
          android: fcm.android
        }
      }

      {byte_size(Jason.encode!(apns.payload)), byte_size(Jason.encode!(fcm_message))}
    end

    defp prefix_of_graphemes?(cut, original) do
      kept = String.graphemes(cut)
      kept == original |> String.graphemes() |> Enum.take(length(kept))
    end

    test "keeps a normal title" do
      ascii = String.duplicate("a", 160)
      emoji = String.duplicate("\u{1F680}", 128)

      assert review_body(ascii) == ascii
      assert review_body(emoji) == emoji
      assert byte_size(emoji) == 512
      assert review_body("Add seat count") == "Add seat count"
      assert target_title("Q4 launch") == "Q4 launch is at risk"
      assert review_title("W2701") == "W2701 is ready for review"
    end

    test "bounds a combining-mark flood by bytes" do
      # One letter with 5,000 marks is one grapheme of 10,001 bytes: bigger
      # than the cap, so it is dropped whole rather than split.
      assert review_body("Fix " <> @flood) == "Fix"
      assert target_title("Q4 " <> @flood) == "Q4 is at risk"

      # 160 graphemes of 7 bytes each: the grapheme cap alone keeps 1,120.
      marked = String.duplicate("e\u0301\u0301\u0301", 160)
      body = review_body(marked)

      assert byte_size(body) <= 512
      assert byte_size(body) > 512 - 7
      assert prefix_of_graphemes?(body, marked)

      name = marked |> target_title() |> String.replace_suffix(" is at risk", "")
      assert byte_size(name) <= 512
      assert prefix_of_graphemes?(name, marked)
    end

    test "bounds the identifier by graphemes and bytes" do
      assert review_title(String.duplicate("W", 200)) ==
               String.duplicate("W", 64) <> " is ready for review"

      emoji = String.duplicate("\u{1F680}", 64)
      assert review_title(emoji) == String.duplicate("\u{1F680}", 32) <> " is ready for review"

      # An identifier cut to nothing falls back to the task id.
      assert review_title(@flood) == "#4812 is ready for review"
    end

    test "the cut never splits a grapheme or a multi-byte codepoint" do
      # 18 bytes each, so 28 whole families (504 bytes) fit and a 29th would not.
      families = String.duplicate(@family, 160)
      body = review_body(families)

      assert body == String.duplicate(@family, 28)
      assert String.valid?(body)

      for title <- [String.duplicate("\u3042", 300), String.duplicate("\u{1F1FA}\u{1F1F8}", 160)] do
        cut = review_body(title)
        assert String.valid?(cut)
        assert byte_size(cut) <= 512
        assert prefix_of_graphemes?(cut, title)
      end
    end

    test "format characters are stripped before the cut" do
      title = String.duplicate("\u200B", 1_000) <> "Visible title"
      assert review_body(title) == "Visible title"

      assert review_body(String.duplicate("a\u202E", 600)) == String.duplicate("a", 160)
    end

    test "never emits invalid UTF-8" do
      broken = <<"Fix ", 0xFF, "bug">>

      assert review_body(broken) == "Fix \uFFFDbug"
      assert target_title(broken) == "Fix \uFFFDbug is at risk"
      assert review_title(<<"W27", 0xC3>>) == "W27\uFFFD is ready for review"

      payload =
        build(
          notification(:review_requested),
          context(subject: %{identifier: <<0xFE>>, title: String.duplicate(<<0xFF>>, 1_000)})
        )

      assert String.valid?(payload.title)
      assert String.valid?(payload.body)
      assert byte_size(payload.body) <= 512
    end

    test "treats a cut-to-empty title as empty" do
      assert review_body(@flood) == nil

      with_counts =
        build(
          notification(:review_requested),
          context(subject: %{identifier: "W2701", title: @flood}, decision: decision_item())
        )

      assert with_counts.body == "2 checks passed\n1 check failed\nHolds up 3 tasks"
      assert target_title(@flood) == "A target is at risk"
    end

    test "hide_titles still leaves no title or name" do
      # Long enough to be cut, but with a visible prefix that would survive it.
      long = String.duplicate("e\u0301\u0301\u0301", 160)
      assert review_body(long) != nil

      hidden = context(hide_titles: true, subject: %{identifier: "W2701", title: long})
      assert build(notification(:goal_completed), hidden).body == nil

      target =
        build(
          target_notification("at_risk"),
          context(hide_titles: true, subject: %{name: long})
        )

      assert target.title == "A target is at risk"
    end

    test "encoded payload stays under 4 KB" do
      floods = [
        @flood,
        String.duplicate("e\u0301\u0301\u0301", 2_000),
        String.duplicate("\"", 5_000),
        String.duplicate("\\", 5_000),
        String.duplicate("\u{1F680}", 5_000),
        String.duplicate(@family, 1_000)
      ]

      # The test bites: unbounded, one flood alone is over the limit.
      assert byte_size(@flood) > 4_096

      for locale <- ["en", "de"], identifier <- floods, title <- floods, type <- @push_events do
        n =
          if type == :target_status_changed,
            do: target_notification("at_risk"),
            else: notification(type)

        subject = %{identifier: identifier, title: title, name: title}

        payload =
          build(n, context(locale: locale, subject: subject, decision: decision_item()))

        {apns, fcm} = encoded_sizes(payload)
        assert apns < 4_096, "APNs #{type} #{locale}: #{apns} bytes"
        assert fcm < 4_096, "FCM #{type} #{locale}: #{fcm} bytes"
      end
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
