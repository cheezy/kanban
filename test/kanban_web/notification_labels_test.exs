defmodule KanbanWeb.NotificationLabelsTest do
  use ExUnit.Case, async: true

  alias Kanban.Notifications.Notification
  alias KanbanWeb.NotificationLabels

  test "every notification event type has a distinct, non-empty category label" do
    labels = Enum.map(Kanban.Notifications.event_types(), &NotificationLabels.category/1)

    assert Enum.all?(labels, &(is_binary(&1) and &1 != ""))
    assert length(Enum.uniq(labels)) == length(labels)
  end

  test "labels are translated" do
    english = NotificationLabels.category(:review_requested)

    for locale <- ~w(de es fr ja pt zh) do
      translated =
        Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
          NotificationLabels.category(:review_requested)
        end)

      refute translated == english, "not translated for #{locale}"
    end
  end

  describe "description/1" do
    test "every event type has a distinct, non-empty description" do
      descriptions =
        Enum.map(Kanban.Notifications.event_types(), &NotificationLabels.description/1)

      assert Enum.all?(descriptions, &(is_binary(&1) and &1 != ""))
      assert length(Enum.uniq(descriptions)) == length(descriptions)
    end

    test "descriptions are translated" do
      english = NotificationLabels.description(:task_reviewed)

      for locale <- ~w(de es fr ja pt zh) do
        translated =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            NotificationLabels.description(:task_reviewed)
          end)

        refute translated == english, "not translated for #{locale}"
      end
    end
  end

  describe "detail/1" do
    defp after_goal_failed(metadata) do
      %Notification{event_type: :after_goal_failed, metadata: metadata}
    end

    test "words an after_goal failure with its exit code and duration" do
      notification = after_goal_failed(%{"exit_code" => 2, "duration_ms" => 1500})

      assert NotificationLabels.detail(notification) == "Exit code 2 after 1500 ms"
    end

    test "words an after_goal failure with only an exit code" do
      assert %{"exit_code" => 1} |> after_goal_failed() |> NotificationLabels.detail() ==
               "Exit code 1"
    end

    test "returns nil for malformed metadata and for other event types" do
      assert %{"exit_code" => "1"} |> after_goal_failed() |> NotificationLabels.detail() == nil
      assert %{} |> after_goal_failed() |> NotificationLabels.detail() == nil

      assert NotificationLabels.detail(%Notification{
               event_type: :review_requested,
               metadata: %{"exit_code" => 1}
             }) == nil
    end

    test "words a review outcome" do
      approved = %Notification{event_type: :task_reviewed, metadata: %{"outcome" => "approved"}}

      changes = %Notification{
        event_type: :task_reviewed,
        metadata: %{"outcome" => "changes_requested"}
      }

      assert NotificationLabels.detail(approved) == "Approved"
      assert NotificationLabels.detail(changes) == "Changes requested"

      for metadata <- [%{"outcome" => "other"}, %{}] do
        assert NotificationLabels.detail(%Notification{
                 event_type: :task_reviewed,
                 metadata: metadata
               }) == nil
      end
    end

    test "says an unclaimed task went back to Ready, introducing a reason body" do
      with_reason = %Notification{event_type: :task_unclaimed, body: "blocked"}

      assert NotificationLabels.detail(with_reason) == "Returned to Ready. Reason:"

      for body <- [nil, ""] do
        assert NotificationLabels.detail(%Notification{event_type: :task_unclaimed, body: body}) ==
                 "Returned to Ready"
      end
    end

    test "translates the review and unclaim wording in every locale" do
      notifications = [
        %Notification{event_type: :task_reviewed, metadata: %{"outcome" => "approved"}},
        %Notification{event_type: :task_reviewed, metadata: %{"outcome" => "changes_requested"}},
        %Notification{event_type: :task_unclaimed, body: "blocked"},
        %Notification{event_type: :task_unclaimed}
      ]

      for notification <- notifications, locale <- ~w(de es fr ja pt zh) do
        english = NotificationLabels.detail(notification)

        translated =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            NotificationLabels.detail(notification)
          end)

        refute translated == english, "#{english} not translated for #{locale}"
      end
    end

    defp access_changed(metadata) do
      %Notification{event_type: :board_access_changed, metadata: metadata}
    end

    test "words an add with the membership page's access label" do
      for {access, label} <- [
            {"owner", "Owner"},
            {"modify", "Can Edit"},
            {"read_only", "Read Only"}
          ] do
        assert %{"change" => "added", "access" => access, "tokens_revoked" => 0}
               |> access_changed()
               |> NotificationLabels.detail() == "You were added with #{label} access."
      end
    end

    test "words an access change, counting revoked tokens only for read_only" do
      assert %{"change" => "access_changed", "access" => "modify", "tokens_revoked" => 0}
             |> access_changed()
             |> NotificationLabels.detail() == "Your access changed to Can Edit."

      assert %{"change" => "access_changed", "access" => "read_only", "tokens_revoked" => 1}
             |> access_changed()
             |> NotificationLabels.detail() ==
               "Your access changed to Read Only. 1 API token was revoked."

      assert %{"change" => "access_changed", "access" => "read_only", "tokens_revoked" => 3}
             |> access_changed()
             |> NotificationLabels.detail() ==
               "Your access changed to Read Only. 3 API tokens were revoked."

      assert %{"change" => "access_changed", "access" => "read_only", "tokens_revoked" => 0}
             |> access_changed()
             |> NotificationLabels.detail() == "Your access changed to Read Only."
    end

    test "words a removal with the revoked-token count, leaving out a zero count" do
      assert %{"change" => "removed", "tokens_revoked" => 1}
             |> access_changed()
             |> NotificationLabels.detail() ==
               "You were removed from this board. 1 API token was revoked."

      assert %{"change" => "removed", "tokens_revoked" => 0}
             |> access_changed()
             |> NotificationLabels.detail() == "You were removed from this board."
    end

    test "returns nil for malformed board access metadata" do
      for metadata <- [
            %{},
            %{"change" => "added"},
            %{"change" => "added", "access" => "admin"},
            %{"change" => "removed", "tokens_revoked" => "2"},
            %{"change" => "removed", "tokens_revoked" => -1},
            %{"change" => "deleted", "access" => "modify"}
          ] do
        assert metadata |> access_changed() |> NotificationLabels.detail() == nil
      end
    end

    test "translates the board access wording in every locale" do
      notifications = [
        access_changed(%{"change" => "added", "access" => "modify", "tokens_revoked" => 0}),
        access_changed(%{
          "change" => "access_changed",
          "access" => "owner",
          "tokens_revoked" => 0
        }),
        access_changed(%{
          "change" => "access_changed",
          "access" => "read_only",
          "tokens_revoked" => 1
        }),
        access_changed(%{
          "change" => "access_changed",
          "access" => "read_only",
          "tokens_revoked" => 2
        }),
        access_changed(%{"change" => "removed", "tokens_revoked" => 0}),
        access_changed(%{"change" => "removed", "tokens_revoked" => 1}),
        access_changed(%{"change" => "removed", "tokens_revoked" => 2})
      ]

      for notification <- notifications, locale <- ~w(de es fr ja pt zh) do
        english = NotificationLabels.detail(notification)

        translated =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            NotificationLabels.detail(notification)
          end)

        refute translated == english, "#{english} not translated for #{locale}"
        assert translated =~ ~r/\d/ or notification.metadata["tokens_revoked"] == 0
      end
    end

    defp target_status(metadata) do
      %Notification{event_type: :target_status_changed, metadata: metadata}
    end

    test "words an at-risk and a missed target with its date" do
      assert %{"status" => "at_risk", "target_date" => "2026-07-21"}
             |> target_status()
             |> NotificationLabels.detail() ==
               "At risk of missing its target date of 2026-07-21."

      assert %{"status" => "missed", "target_date" => "2026-07-21"}
             |> target_status()
             |> NotificationLabels.detail() == "Missed its target date of 2026-07-21."
    end

    test "words a target status without a date" do
      assert %{"status" => "at_risk"} |> target_status() |> NotificationLabels.detail() ==
               "At risk of missing its target date."

      assert %{"status" => "missed"} |> target_status() |> NotificationLabels.detail() ==
               "Missed its target date."
    end

    test "returns nil for an unknown target status" do
      for metadata <- [%{}, %{"status" => "on_track"}, %{"status" => "late"}] do
        assert metadata |> target_status() |> NotificationLabels.detail() == nil
      end
    end

    test "translates the target status wording in every locale" do
      notifications = [
        target_status(%{"status" => "at_risk", "target_date" => "2026-07-21"}),
        target_status(%{"status" => "missed", "target_date" => "2026-07-21"}),
        target_status(%{"status" => "at_risk"}),
        target_status(%{"status" => "missed"})
      ]

      for notification <- notifications, locale <- ~w(de es fr ja pt zh) do
        english = NotificationLabels.detail(notification)

        translated =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            NotificationLabels.detail(notification)
          end)

        refute translated == english, "#{english} not translated for #{locale}"

        if date = notification.metadata["target_date"] do
          assert translated =~ date
        end
      end
    end

    test "is translated" do
      notification = after_goal_failed(%{"exit_code" => 2, "duration_ms" => 10})
      english = NotificationLabels.detail(notification)

      german =
        Gettext.with_locale(KanbanWeb.Gettext, "de", fn ->
          NotificationLabels.detail(notification)
        end)

      refute german == english
    end
  end
end
