defmodule KanbanWeb.TaskLive.Components.TaskDetailBandTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskLive.Components.TaskDetailBand

  defp task(attrs) do
    Map.merge(
      %{type: :work, identifier: "W42", status: :open, priority: nil, complexity: nil},
      attrs
    )
  end

  defp render_band(attrs) do
    render_component(&TaskDetailBand.detail_band/1,
      task: task(attrs),
      can_modify: true,
      board_id: 1
    )
  end

  test "renders the identifier and both priority and complexity words" do
    html = render_band(%{priority: :high, complexity: :small})

    assert html =~ "data-task-detail-band"
    assert html =~ "W42"
    assert html =~ "High · Small"
    # The priority dot renders only with a priority.
    assert html =~ "border-radius: 50%;"
  end

  test "renders only the word that is set" do
    assert render_band(%{priority: :low}) =~ ~r/>\s*Low\s*</
    assert render_band(%{complexity: :large}) =~ ~r/>\s*Large\s*</
  end

  test "renders no meta words and no priority dot when neither is set" do
    html = render_band(%{})

    refute html =~ "·"
    refute html =~ "border-radius: 50%;"
  end
end
