defmodule KanbanWeb.NotificationLabelsTest do
  use ExUnit.Case, async: true

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
end
