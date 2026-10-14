defmodule KanbanWeb.BoardLive.WebhookKindsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.BoardLive.WebhookKinds

  @slack_colors "background: var(--stride-violet-soft); color: var(--stride-violet-ink);"
  @generic_colors "background: var(--surface-sunken); color: var(--ink-2);"
  @slack_hint "Paste a Slack incoming webhook URL (https://hooks.slack.com/…)."
  @generic_hint "Stride sends a signed JSON POST to this HTTPS address."

  describe "label/1, colors/1, url_placeholder/1, url_hint/1 and signed?/1" do
    test "return the current values for :generic and :slack, as atoms and as strings" do
      for kind <- [:slack, "slack"] do
        assert WebhookKinds.label(kind) == "Slack"
        assert WebhookKinds.colors(kind) == @slack_colors
        assert WebhookKinds.url_placeholder(kind) == "https://hooks.slack.com/services/…"
        assert WebhookKinds.url_hint(kind) == @slack_hint
        refute WebhookKinds.signed?(kind)
      end

      for kind <- [:generic, "generic"] do
        assert WebhookKinds.label(kind) == "Generic webhook"
        assert WebhookKinds.colors(kind) == @generic_colors
        assert WebhookKinds.url_placeholder(kind) == "https://"
        assert WebhookKinds.url_hint(kind) == @generic_hint
        assert WebhookKinds.signed?(kind)
      end
    end

    test "an unknown or nil kind falls back to the generic values" do
      for kind <- [nil, "", "discord", :discord, 42] do
        assert WebhookKinds.label(kind) == "Generic webhook"
        assert WebhookKinds.colors(kind) == @generic_colors
        assert WebhookKinds.url_placeholder(kind) == "https://"
        assert WebhookKinds.url_hint(kind) == @generic_hint
      end
    end

    test "signed?/1 is true only for :generic, so no other kind shows a secret control" do
      for kind <- [nil, "", "discord", :discord, :slack, "slack", 42] do
        refute WebhookKinds.signed?(kind)
      end
    end
  end

  describe "translations" do
    test "the label and hint are translated at call time, in the current locale" do
      Gettext.with_locale(KanbanWeb.Gettext, "es", fn ->
        refute WebhookKinds.label(:generic) == "Generic webhook"
        refute WebhookKinds.url_hint(:slack) == @slack_hint
      end)
    end
  end
end
