defmodule KanbanWeb.BoardLive.WebhookKinds do
  @moduledoc """
  Every per-kind presentation choice for the endpoints on the board's
  Integrations view (W2365): the kind's label, its badge colours, the URL
  input's placeholder and hint, and whether the endpoint signs its requests.
  `KanbanWeb.BoardLive.WebhookForm` and `KanbanWeb.BoardLive.WebhookViews`
  read from here, so adding a kind is one new clause per function.

  Each function takes the kind as an atom (a loaded endpoint) or a string
  (the create form's params). `:slack` and `:discord` (W2368) each have their
  own clause; `:generic`, like an unknown or `nil` kind on a half-filled
  create form, gets the catch-all generic presentation — except `signed?/1`,
  which is `true` only for `:generic`, so no other kind ever shows a secret
  control.

  The gettext calls run inside the function bodies, at render time, so the
  viewer's locale applies.
  """
  use Gettext, backend: KanbanWeb.Gettext

  @doc "The display name of an endpoint kind."
  def label(kind) when kind in [:slack, "slack"], do: gettext("Slack")
  def label(kind) when kind in [:discord, "discord"], do: gettext("Discord")
  def label(_kind), do: gettext("Generic webhook")

  @doc "The inline background and text colour of an endpoint kind's badge."
  def colors(kind) when kind in [:slack, "slack"],
    do: "background: var(--stride-violet-soft); color: var(--stride-violet-ink);"

  def colors(kind) when kind in [:discord, "discord"],
    do: "background: var(--label-blue-soft); color: var(--label-blue);"

  def colors(_kind), do: "background: var(--surface-sunken); color: var(--ink-2);"

  @doc "The placeholder of the URL input for an endpoint kind."
  def url_placeholder(kind) when kind in [:slack, "slack"],
    do: "https://hooks.slack.com/services/…"

  def url_placeholder(kind) when kind in [:discord, "discord"],
    do: "https://discord.com/api/webhooks/…"

  def url_placeholder(_kind), do: "https://"

  @doc "The hint under the URL input for an endpoint kind."
  def url_hint(kind) when kind in [:slack, "slack"],
    do: gettext("Paste a Slack incoming webhook URL (https://hooks.slack.com/…).")

  def url_hint(kind) when kind in [:discord, "discord"],
    do:
      gettext(
        "Paste the webhook URL you copied from Discord (for example https://discord.com/api/webhooks/…)."
      )

  def url_hint(_kind), do: gettext("Stride sends a signed JSON POST to this HTTPS address.")

  @doc """
  Whether an endpoint of this kind signs its requests with a secret, and so
  shows the Rotate-secret button and note. Only `:generic` does.
  """
  def signed?(kind) when kind in [:generic, "generic"], do: true
  def signed?(_kind), do: false
end
