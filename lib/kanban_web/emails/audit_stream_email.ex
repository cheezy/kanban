defmodule KanbanWeb.Emails.AuditStreamEmail do
  @moduledoc """
  Builds the audit stream security emails every org-admin receives
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.4, §8.6, §8.8, §12.3, §13.3),
  sent by `Kanban.Notifications.AuditStreamEmailWorker`.

  One email per kind: a destination created (a catch-up is named in the
  subject), changed, paused, resumed or deleted by an org-admin; and, recorded
  by Stride, a destination that became Failing, recovered, was halted because
  transaction ids went backwards, or will never receive some events (a gap).
  Each names who acted, or that Stride recorded it, and the destination's
  name, type, host and credential hint, and links to its page.

  The alert is the worker's parsed snapshot, never the destination itself,
  and holds no URL, credential, header value or signing secret. These are
  security emails sent to every org-admin, so they carry no unsubscribe link
  or `List-Unsubscribe` header.

  Every value interpolated into the HTML body — text and hrefs alike — is
  HTML-escaped; the text body carries the same content unescaped. The name is
  org-admin input: its control characters are replaced and it is isolated
  (U+2068 … U+2069) so right-to-left text can't reorder the sentence around
  it. The email renders in the calling process's Gettext locale, which the
  worker sets to the recipient's.
  """

  use Gettext, backend: KanbanWeb.Gettext
  use KanbanWeb, :verified_routes

  import Swoosh.Email
  import KanbanWeb.Emails.EmailHelpers, only: [escape: 1]

  alias Kanban.Accounts.User
  alias Kanban.AuditStream.Destination
  alias KanbanWeb.Emails.EmailHelpers
  alias KanbanWeb.OrgLive.AuditStreamDestinationView
  alias KanbanWeb.OrgLive.AuditStreamingRow
  alias KanbanWeb.OrgLive.AuditStreamKinds
  alias KanbanWeb.Sentences

  # dark-mode-ignore: email HTML cannot use the app's CSS variables
  @rule_style "border:none;border-top:1px solid #d4d4d8;margin:24px 0 12px"
  @paragraph_style "margin:0 0 12px"
  @table_style "border-collapse:collapse;margin:0 0 16px"
  @label_style "padding:4px 16px 4px 0;vertical-align:top;font-weight:600"
  @value_style "padding:4px 0;vertical-align:top"
  @footer_style "font-size:12px;margin:0;opacity:0.75"

  @typedoc "Who acted: a user's email, Stride, or an account that no longer exists."
  @type actor :: {:user, String.t()} | :stride | :deleted_account

  @typedoc "The alert the worker parses from a job's args."
  @type alert :: %{
          required(:kind) => atom(),
          required(:ref) => String.t(),
          required(:destination) => map(),
          required(:actor) => actor(),
          optional(atom()) => term()
        }

  @doc "Builds the email for `alert` to `user`."
  @spec build(User.t(), alert()) :: Swoosh.Email.t()
  def build(%User{} = user, %{kind: _kind, ref: ref, destination: _destination} = alert) do
    content = content(alert)

    new()
    |> to(user.email)
    |> from(EmailHelpers.from())
    |> subject("[Stride] " <> content.heading)
    |> html_body(render_html(content))
    |> text_body(render_text(content))
    |> header("Message-ID", "<audit-stream-#{safe_ref(ref)}-#{user.id}@stridelikeaboss.com>")
  end

  defp content(alert) do
    name = display_name(alert.destination.name)

    %{
      heading: heading(alert, name),
      paragraphs: paragraphs(alert, name, actor_label(alert.actor)),
      details: details(alert, name),
      links: links(alert),
      notice:
        gettext(
          "You are receiving this security notice because you are an org-admin of this Organization. Every org-admin receives it, whatever their notification settings."
        )
    }
  end

  # --- subject ----------------------------------------------------------------

  defp heading(%{kind: :created, start_from: "24h"}, name),
    do:
      gettext("Audit streaming destination created, catching up the last 24 hours: %{name}",
        name: name
      )

  defp heading(%{kind: :created, start_from: "7d"}, name),
    do:
      gettext("Audit streaming destination created, catching up the last 7 days: %{name}",
        name: name
      )

  defp heading(%{kind: :created, start_from: "17h"}, name),
    do:
      gettext("Audit streaming destination created, catching up the last 17 hours: %{name}",
        name: name
      )

  defp heading(%{kind: :created, start_from: "all"}, name),
    do:
      gettext("Audit streaming destination created, sending the whole audit log: %{name}",
        name: name
      )

  defp heading(%{kind: :created}, name),
    do: gettext("Audit streaming destination created: %{name}", name: name)

  defp heading(%{kind: :updated}, name),
    do: gettext("Audit streaming destination changed: %{name}", name: name)

  defp heading(%{kind: :paused}, name),
    do: gettext("Audit streaming destination paused: %{name}", name: name)

  defp heading(%{kind: :resumed}, name),
    do: gettext("Audit streaming destination resumed: %{name}", name: name)

  defp heading(%{kind: :deleted}, name),
    do: gettext("Audit streaming destination deleted: %{name}", name: name)

  defp heading(%{kind: :failing}, name),
    do: gettext("Audit streaming destination is failing: %{name}", name: name)

  defp heading(%{kind: :recovered}, name),
    do: gettext("Audit streaming destination recovered: %{name}", name: name)

  defp heading(%{kind: :txid_reset}, name),
    do: gettext("Audit streaming must be re-seeded: %{name}", name: name)

  defp heading(%{kind: :gap, gap: %{opened: true}}, name),
    do: gettext("Audit events lost for %{name}", name: name)

  defp heading(%{kind: :gap}, name),
    do: gettext("Audit events still being lost for %{name}", name: name)

  # --- body -------------------------------------------------------------------

  defp paragraphs(%{kind: :created} = alert, name, actor) do
    lead =
      gettext("%{actor} created the audit streaming destination %{name}.",
        actor: actor,
        name: name
      )

    if AuditStreamKinds.catch_up?(alert.start_from),
      do: [
        lead,
        gettext(
          "It is catching up: it also sends audit events recorded before it was created, from the start point below."
        )
      ],
      else: [lead]
  end

  defp paragraphs(%{kind: :updated}, name, actor),
    do: [
      gettext("%{actor} changed the audit streaming destination %{name}.",
        actor: actor,
        name: name
      )
    ]

  defp paragraphs(%{kind: :paused}, name, actor),
    do: [
      Sentences.join([
        gettext("%{actor} paused the audit streaming destination %{name}.",
          actor: actor,
          name: name
        ),
        gettext("It receives no audit events until an org-admin resumes it.")
      ])
    ]

  defp paragraphs(%{kind: :resumed}, name, actor),
    do: [
      gettext("%{actor} resumed the audit streaming destination %{name}.",
        actor: actor,
        name: name
      )
    ]

  defp paragraphs(%{kind: :deleted}, name, actor),
    do: [
      Sentences.join([
        gettext("%{actor} deleted the audit streaming destination %{name}.",
          actor: actor,
          name: name
        ),
        gettext("It no longer receives this Organization's audit events.")
      ])
    ]

  defp paragraphs(%{kind: :failing} = alert, name, _actor) do
    lead =
      gettext("Stride marked the audit streaming destination %{name} as Failing.", name: name)

    [lead, failing_reason(alert.reason)] ++ datadog_note(alert.destination.kind)
  end

  defp paragraphs(%{kind: :recovered}, name, _actor),
    do: [
      gettext(
        "The audit streaming destination %{name} has recovered: Stride delivered to it again.",
        name: name
      )
    ]

  defp paragraphs(%{kind: :txid_reset}, name, _actor),
    do: [
      gettext(
        "Stride halted the audit streaming destination %{name}: transaction ids went backwards after a database move.",
        name: name
      ),
      gettext("An operator must re-seed audit streaming before it sends again.")
    ]

  defp paragraphs(%{kind: :gap, gap: gap}, name, _actor) do
    lead =
      if gap.opened,
        do:
          gettext(
            "Stride recorded a gap for the audit streaming destination %{name}: some audit events will never reach it.",
            name: name
          ),
        else:
          gettext("The gap for the audit streaming destination %{name} has grown.", name: name)

    [lead, gap_count(gap)] ++ gap_reminder(gap)
  end

  defp failing_reason(:unauthorized),
    do: gettext("The destination refused the credentials Stride sends.")

  defp failing_reason(:config_error),
    do: gettext("The destination answered that its configuration is wrong.")

  defp failing_reason(:no_success), do: gettext("No delivery has succeeded for 30 minutes.")

  defp failing_reason(:rejected_batch),
    do:
      gettext(
        "The destination rejected the same batch 3 times. Nothing more is sent until an org-admin chooses Retry now or Skip this batch on the destination's page."
      )

  defp failing_reason(:blocked_address),
    do:
      gettext(
        "Stride refused to send to the destination's address. Nothing more is sent until an org-admin changes its URL."
      )

  defp failing_reason(:credentials_unreadable),
    do:
      gettext(
        "The destination's credentials can't be read. An org-admin must enter them again on the destination's edit page."
      )

  defp failing_reason(_unknown), do: gettext("Deliveries to the destination are failing.")

  defp datadog_note(:datadog),
    do: [
      gettext(
        "Datadog refuses events more than 18 hours old, so events not delivered within 17 hours of the destination failing are lost."
      )
    ]

  defp datadog_note(_kind), do: []

  defp gap_count(gap) do
    Sentences.join([
      ngettext(
        "%{count} audit event will never reach this destination.",
        "%{count} audit events will never reach this destination.",
        gap.events
      ),
      gettext("They were recorded between %{first} and %{last} UTC.",
        first: Calendar.strftime(gap.first_at, "%Y-%m-%d %H:%M"),
        last: Calendar.strftime(gap.last_at, "%Y-%m-%d %H:%M")
      )
    ])
  end

  defp gap_reminder(%{opened: true}),
    do: [gettext("While the gap grows, you are emailed about it at most once every 7 days.")]

  defp gap_reminder(_gap), do: []

  # --- details ----------------------------------------------------------------

  defp details(alert, name) do
    destination = destination(alert.destination)

    [
      {gettext("Destination"), name},
      {gettext("Type"), AuditStreamingRow.type_label(destination.kind)},
      {gettext("Host"), AuditStreamingRow.host(destination) || "—"},
      {gettext("Credential"), AuditStreamingRow.hint(destination) || "—"},
      {gettext("By"), by(alert)}
    ] ++ kind_details(alert)
  end

  defp destination(snapshot) do
    %Destination{
      kind: snapshot.kind,
      url_host: snapshot.url_host,
      url_hint: snapshot.url_hint,
      credential_hint: snapshot.credential_hint,
      settings: if(snapshot.site, do: %{"site" => snapshot.site}, else: %{})
    }
  end

  defp by(%{kind: kind}) when kind in [:failing, :recovered, :txid_reset, :gap],
    do: gettext("Stride recorded this")

  defp by(%{actor: actor}), do: actor_label(actor)

  defp kind_details(%{kind: :created, destination: %{kind: kind}, start_from: start_from}),
    do: [
      {gettext("Start from"),
       kind
       |> AuditStreamKinds.normalize_start(start_from)
       |> AuditStreamKinds.start_point_label()}
    ]

  defp kind_details(%{kind: :updated, destination: %{kind: kind}, changed: changed}),
    do: [{gettext("Changed"), Enum.map_join(changed, ", ", &field_label(kind, &1))}]

  defp kind_details(%{kind: :gap, gap: gap}),
    do: [{gettext("Reason"), AuditStreamDestinationView.gap_reason(gap.reason)}]

  defp kind_details(_alert), do: []

  defp field_label(:datadog, "url"), do: gettext("URL")
  defp field_label(kind, "url"), do: AuditStreamKinds.secret_label(kind, :url)
  defp field_label(kind, "credential"), do: AuditStreamKinds.secret_label(kind, :credential)
  defp field_label(_kind, "include_personal_data"), do: gettext("Email and IP addresses")
  defp field_label(_kind, "excluded_actions"), do: gettext("Excluded actions")
  defp field_label(_kind, "index"), do: gettext("Index")
  defp field_label(_kind, "site"), do: gettext("Site")
  defp field_label(_kind, "service"), do: gettext("Service")
  defp field_label(_kind, "tags"), do: gettext("Tags")
  defp field_label(_kind, "header_name"), do: gettext("Signature header")
  defp field_label(_kind, _other), do: gettext("Settings")

  defp actor_label({:user, email}) when is_binary(email), do: email
  defp actor_label(:stride), do: "Stride"
  defp actor_label(_deleted), do: gettext("A deleted account")

  # --- links ------------------------------------------------------------------

  # Verified routes, so a renamed page fails to compile rather than sending a
  # dead link.
  defp links(%{kind: :deleted}),
    do: [{gettext("Open audit streaming"), localized(url(~p"/org/audit/streaming"))}]

  defp links(%{kind: :failing, reason: :credentials_unreadable, destination: %{id: id}}),
    do: [
      {gettext("Enter the credentials again"),
       localized(url(~p"/org/audit/streaming/#{id}/edit"))},
      {gettext("Open the destination"), localized(url(~p"/org/audit/streaming/#{id}"))}
    ]

  defp links(%{destination: %{id: id}}),
    do: [{gettext("Open the destination"), localized(url(~p"/org/audit/streaming/#{id}"))}]

  defp localized(url) do
    case Gettext.get_locale(KanbanWeb.Gettext) do
      "en" -> url
      locale -> url <> "?" <> URI.encode_query(locale: locale)
    end
  end

  # --- rendering --------------------------------------------------------------

  defp render_html(content) do
    """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><meta name="color-scheme" content="light dark"></head>
    <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;line-height:1.5;max-width:600px;margin:0 auto;padding:24px">
    <h1 style="font-size:20px;margin:0 0 16px">#{escape(content.heading)}</h1>
    #{Enum.map_join(content.paragraphs, "\n", &~s(<p style="#{@paragraph_style}">#{escape(&1)}</p>))}
    #{html_details(content.details)}
    #{html_links(content.links)}
    <hr style="#{@rule_style}">
    <p style="#{@footer_style}">#{escape(content.notice)}</p>
    </body>
    </html>
    """
  end

  defp html_details(details) do
    rows =
      Enum.map_join(details, "\n", fn {label, value} ->
        ~s(<tr><td style="#{@label_style}">#{escape(label)}</td><td style="#{@value_style}"><bdi>#{escape(value)}</bdi></td></tr>)
      end)

    ~s(<table role="presentation" style="#{@table_style}">\n#{rows}\n</table>)
  end

  defp html_links([{label, url} | rest]) do
    primary =
      ~s(<a href="#{escape(url)}" style="#{EmailHelpers.button_style()}">#{escape(label)}</a>)

    others =
      Enum.map_join(rest, "", fn {l, u} ->
        ~s(\n<p style="#{@paragraph_style}"><a href="#{escape(u)}">#{escape(l)}</a></p>)
      end)

    ~s(<p style="margin:24px 0">#{primary}</p>) <> others
  end

  defp render_text(content) do
    details = Enum.map_join(content.details, "\n", fn {label, value} -> "#{label}: #{value}" end)
    links = Enum.map_join(content.links, "\n", fn {label, url} -> "#{label}: #{url}" end)

    Enum.join(
      [content.heading | content.paragraphs] ++ [details, links, "--\n" <> content.notice],
      "\n\n"
    )
  end

  # Control characters (a newline in a subject, say) become spaces; the name
  # is then isolated so right-to-left text stays inside it.
  defp display_name(name) do
    "\u2068" <>
      String.replace(name, ~r/[\p{Cc}\x{2066}-\x{2069}\x{202A}-\x{202E}]/u, " ") <> "\u2069"
  end

  defp safe_ref(ref), do: String.replace(ref, ~r/[^A-Za-z0-9-]/, "")
end
