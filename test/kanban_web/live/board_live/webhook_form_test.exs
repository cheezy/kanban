defmodule KanbanWeb.BoardLive.WebhookFormTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Webhooks
  alias Kanban.Webhooks.Endpoint
  alias KanbanWeb.BoardLive.WebhookForm

  defp render_form(attrs, opts \\ []) do
    form = %Endpoint{} |> Webhooks.change_endpoint(attrs) |> to_form([as: "endpoint"] ++ opts)
    assigns = %{form: form}

    rendered_to_string(~H"""
    <WebhookForm.endpoint_form form={@form} rev={3} myself={nil} />
    """)
  end

  test "renders every event as a checkbox with a hidden empty value first" do
    html = render_form(%{"event_types" => ["task.moved"]})

    assert html =~ ~s(id="webhook-endpoint-form-3")
    assert html =~ ~r/<input type="hidden" name="endpoint\[event_types\]\[\]" value=""/

    for event <- Endpoint.event_types() do
      assert html =~ ~s(value="#{event}")
    end

    assert html =~ ~r/value="task.moved"\s+checked/
    refute html =~ ~r/value="task.created"\s+checked/
  end

  test "the URL hint follows the selected kind" do
    assert render_form(%{"kind" => "generic"}) =~ "signed JSON POST"
    assert render_form(%{"kind" => "slack"}) =~ "Slack incoming webhook URL"
  end

  test "a field's errors show once it is used, not before" do
    assert render_form(%{"url" => "nope"}, action: :validate) =~ "must start with https://"

    refute render_form(%{"url" => "nope", "_unused_url" => ""}, action: :validate) =~
             "must start with https://"
  end
end
