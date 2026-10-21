defmodule KanbanWeb.BoardLive.WebhookViewsTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Accounts.User
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

  test "kind_label/1 names every kind" do
    assert WebhookViews.kind_label(:slack) == "Slack"
    assert WebhookViews.kind_label("slack") == "Slack"
    assert WebhookViews.kind_label(:discord) == "Discord"
    assert WebhookViews.kind_label("discord") == "Discord"
    assert WebhookViews.kind_label(:generic) == "Generic webhook"

    for kind <- Endpoint.kinds() -- [:generic] do
      refute WebhookViews.kind_label(kind) == "Generic webhook",
             "#{inspect(kind)} has no label of its own"
    end
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

    test "a Discord row shows only the host, its Discord badge and no rotate action" do
      assigns = %{
        endpoint:
          endpoint(kind: :discord, url: "https://discord.com/api/webhooks/123456789/abcDEF_-tok")
      }

      html =
        rendered_to_string(~H"""
        <WebhookViews.endpoint_row endpoint={@endpoint} myself={nil} />
        """)

      assert html =~ "discord.com"
      assert html =~ ~s(data-endpoint-kind="discord")
      assert html =~ "Discord"
      refute html =~ "api/webhooks"
      refute html =~ "abcDEF_-tok"
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

    test "names the creator by name, by email when the name is blank, or as a deleted account" do
      for {creator, expected} <- [
            {%User{name: "Ada Lovelace", email: "ada@example.com"}, "Added by Ada Lovelace"},
            {%User{name: "  ", email: "ada@example.com"}, "Added by ada@example.com"},
            {nil, "Added by a deleted account"}
          ] do
        assert render_row(endpoint(created_by: creator)) =~ expected
      end
    end

    test "leaves the creator line out when the creator was not preloaded" do
      refute render_row(endpoint([])) =~ "data-endpoint-creator"
    end

    test "says why Stride switched an endpoint off" do
      html = render_row(endpoint(enabled: false, disabled_reason: :creator_lost_access))

      assert html =~ "data-endpoint-disabled"
      assert html =~ "data-endpoint-state-note"
      assert html =~ "no longer has access to this board"
    end

    test "an endpoint the owner switched off has no note" do
      refute render_row(endpoint(enabled: false, created_by: nil)) =~ "data-endpoint-state-note"
    end

    test "an enabled endpoint of a disabled creator is marked Not sending" do
      creator = %User{
        name: "Ada",
        email: "ada@example.com",
        disabled_at: ~U[2026-10-21 10:00:00Z]
      }

      html = render_row(endpoint(created_by: creator))

      assert html =~ "data-endpoint-not-sending"
      assert html =~ "Not sending"
      assert html =~ "is disabled"
    end

    test "a switched-off endpoint of a disabled creator shows only Disabled" do
      creator = %User{
        name: "Ada",
        email: "ada@example.com",
        disabled_at: ~U[2026-10-21 10:00:00Z]
      }

      html = render_row(endpoint(enabled: false, created_by: creator))

      assert html =~ "data-endpoint-disabled"
      refute html =~ "data-endpoint-not-sending"
      refute html =~ "data-endpoint-state-note"
    end
  end

  defp render_row(endpoint) do
    assigns = %{endpoint: endpoint}

    rendered_to_string(~H"""
    <WebhookViews.endpoint_row endpoint={@endpoint} myself={nil} />
    """)
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
