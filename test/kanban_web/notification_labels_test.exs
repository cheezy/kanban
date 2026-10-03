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
