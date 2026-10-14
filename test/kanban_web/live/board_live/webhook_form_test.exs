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

    assert html =~
             ~r/<input type="hidden" id="endpoint_event_types_empty" name="endpoint\[event_types\]\[\]" value=""/

    # Each input's id comes from the form's, so a reset form gets fresh inputs.
    assert html =~ ~s(id="endpoint_event_types_task_moved")

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

  test "the URL placeholder follows the selected kind, and a blank kind gets the generic one" do
    assert render_form(%{"kind" => "slack"}) =~
             ~s(placeholder="https://hooks.slack.com/services/…")

    assert render_form(%{"kind" => "generic"}) =~ ~s(placeholder="https://")
    assert render_form(%{}) =~ ~s(placeholder="https://")
    assert render_form(%{}) =~ "signed JSON POST"
  end

  test "a field's errors show once it is used, not before" do
    assert render_form(%{"url" => "nope"}, action: :validate) =~ "must start with https://"

    refute render_form(%{"url" => "nope", "_unused_url" => ""}, action: :validate) =~
             "must start with https://"
  end

  describe "edit_form/1" do
    @stored_url "https://hooks.example.com/stride/secret-path?token=abc"

    defp render_edit(endpoint, attrs \\ %{}) do
      form =
        endpoint
        |> Webhooks.change_endpoint(attrs)
        |> to_form(as: "endpoint_edit", action: if(attrs == %{}, do: nil, else: :validate))

      assigns = %{form: form, endpoint: endpoint}

      rendered_to_string(~H"""
      <WebhookForm.edit_form form={@form} endpoint={@endpoint} myself={nil} />
      """)
    end

    defp endpoint(attrs) do
      struct(
        %Endpoint{id: 7, kind: :generic, url: @stored_url, event_types: ["task.moved"]},
        attrs
      )
    end

    test "the edit form renders the kind read-only with no kind select, ticks the endpoint's current events, leaves the URL input empty and shows the current host in its hint" do
      html = render_edit(endpoint(%{}))

      assert html =~ ~s(id="webhook-edit-form-7")
      assert html =~ ~s(phx-value-id="7")
      refute html =~ "<select"
      assert html =~ ~s(data-edit-kind="generic")
      assert html =~ "Generic webhook"
      assert html =~ ~r/id="webhook-edit-url-7"[^>]*value=""/
      assert html =~ "Leave blank to keep the current URL (hooks.example.com)."
      assert html =~ ~s(placeholder="hooks.example.com")
      refute html =~ "secret-path"
      refute html =~ "token=abc"
      assert html =~ ~r/name="endpoint_edit\[event_types\]\[\]" value=""/
      assert html =~ ~r/value="task.moved"\s+checked/
      refute html =~ ~r/value="task.created"\s+checked/
    end

    test "a Slack endpoint's edit form shows the Slack URL hint and no Rotate-secret note; a generic endpoint's shows the note" do
      slack =
        render_edit(endpoint(%{kind: :slack, url: "https://hooks.slack.com/services/T0/B0/X"}))

      assert slack =~ "Slack incoming webhook URL"
      refute slack =~ "data-rotate-note"
      refute slack =~ "services/T0"

      generic = render_edit(endpoint(%{}))
      assert generic =~ "signed JSON POST"
      assert generic =~ "data-rotate-note"
      assert generic =~ "Rotate secret"
    end

    test "a typed URL is echoed from the params, never the stored one" do
      html = render_edit(endpoint(%{}), %{"url" => "https://hooks.example.com/typed"})

      assert html =~ ~s(value="https://hooks.example.com/typed")
      refute html =~ "secret-path"

      blank = render_edit(endpoint(%{}), %{"event_types" => ["task.created"]})
      assert blank =~ ~r/id="webhook-edit-url-7"[^>]*value=""/
      refute blank =~ "secret-path"
    end

    test "a used URL field shows its translated error" do
      assert render_edit(endpoint(%{}), %{"url" => "nope"}) =~ "must start with https://"
    end
  end
end
