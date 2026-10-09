defmodule KanbanWeb.BoardLive.WebhookViewsTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Webhooks.Delivery
  alias Kanban.Webhooks.Endpoint
  alias KanbanWeb.BoardLive.WebhookViews

  defp endpoint(attrs) do
    struct(
      %Endpoint{
        id: 7,
        kind: :generic,
        url: "https://hooks.example.com/path/secret?token=abc",
        event_types: ["task.created"],
        enabled: true
      },
      attrs
    )
  end

  describe "url_host/1" do
    test "keeps only the host" do
      assert WebhookViews.url_host("https://hooks.example.com:8443/a/b?c=d") ==
               "hooks.example.com"
    end

    test "anything without a host gets a fallback" do
      for url <- ["not a url", "", nil, 42, "/relative"] do
        assert WebhookViews.url_host(url) == "unknown host"
      end
    end
  end

  describe "truncate/2" do
    test "short text is unchanged and nil is empty" do
      assert WebhookViews.truncate("short", 10) == "short"
      assert WebhookViews.truncate("exactly10!", 10) == "exactly10!"
      assert WebhookViews.truncate(nil, 10) == ""
    end

    test "long text is cut to max characters plus an ellipsis, multibyte-safe" do
      assert WebhookViews.truncate("abcdefghijkl", 5) == "abcde…"

      cut = "é" |> String.duplicate(50) |> WebhookViews.truncate(10)
      assert cut == String.duplicate("é", 10) <> "…"
      assert String.valid?(cut)
    end
  end

  test "kind_label/1 names both kinds" do
    assert WebhookViews.kind_label(:slack) == "Slack"
    assert WebhookViews.kind_label("slack") == "Slack"
    assert WebhookViews.kind_label(:generic) == "Generic webhook"
  end

  describe "endpoint_row/1" do
    test "never renders the full URL; Slack has no rotate action" do
      assigns = %{endpoint: endpoint(kind: :slack, url: "https://hooks.slack.com/services/T/B/X")}

      html =
        rendered_to_string(~H"""
        <WebhookViews.endpoint_row endpoint={@endpoint} myself={nil} />
        """)

      assert html =~ "hooks.slack.com"
      refute html =~ "services/T/B/X"
      refute html =~ "webhook-rotate-7"
      assert html =~ "webhook-delete-7"
    end

    test "a generic endpoint offers rotate and a disabled one says so" do
      assigns = %{endpoint: endpoint(enabled: false)}

      html =
        rendered_to_string(~H"""
        <WebhookViews.endpoint_row endpoint={@endpoint} myself={nil} />
        """)

      assert html =~ "webhook-rotate-7"
      assert html =~ "data-endpoint-disabled"
      assert html =~ ~s(data-enabled="false")
      refute html =~ "secret?token"
    end
  end

  describe "delivery_log/1" do
    test "renders the empty state" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <WebhookViews.delivery_log endpoint_id={7} deliveries={[]} myself={nil} />
        """)

      assert html =~ "data-deliveries-empty"
      assert html =~ "No deliveries yet."
    end

    test "renders each status, the response code and an escaped error" do
      now = DateTime.utc_now(:second)

      deliveries = [
        %Delivery{
          id: 1,
          event: "ping",
          status: :succeeded,
          attempt: 1,
          response_status: 204,
          inserted_at: now
        },
        %Delivery{
          id: 2,
          event: "task.moved",
          status: :failed,
          attempt: 2,
          response_status: nil,
          error: "<b>boom</b>",
          inserted_at: now
        },
        %Delivery{id: 3, event: "task.created", status: :pending, attempt: 0, inserted_at: now}
      ]

      assigns = %{deliveries: deliveries}

      html =
        rendered_to_string(~H"""
        <WebhookViews.delivery_log endpoint_id={7} deliveries={@deliveries} myself={nil} />
        """)

      assert html =~ ~s(data-delivery-status="succeeded")
      assert html =~ ~s(data-delivery-status="failed")
      assert html =~ ~s(data-delivery-status="pending")
      assert html =~ "204"
      assert html =~ "—"
      assert html =~ "&lt;b&gt;boom&lt;/b&gt;"
      refute html =~ "<b>boom</b>"
    end
  end
end
