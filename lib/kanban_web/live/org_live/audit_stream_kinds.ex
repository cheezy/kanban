defmodule KanbanWeb.OrgLive.AuditStreamKinds do
  @moduledoc """
  What the audit stream destination form (`KanbanWeb.OrgLive.AuditStreamForm`)
  offers for each destination type (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md`
  §5.1 to §5.3, §8.5, §10.3): the type labels, the fields each type shows and
  which of them are secret, the nine Datadog sites, the HTTPS formats, the
  start points each type offers and the actions an org-admin may leave out.

  Every list comes from the context or the type's adapter, so the form can
  never offer what the context would refuse: the Datadog sites from
  `Kanban.AuditStream.Adapters.Datadog.sites/0`, the start points from
  `Kanban.AuditStream.StartPoint.options/1` and the excludable actions from
  `Kanban.AuditStream.Destination.excludable_actions/0`, which never holds an
  `audit_stream_*` action (§12.3).
  """
  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.AuditStream.Adapters.Datadog
  alias Kanban.AuditStream.Adapters.SplunkHec
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.StartPoint
  alias KanbanWeb.AuditLogActions
  alias KanbanWeb.OrgLive.AuditStreamingRow

  @doc "The destination kinds, in the order the Type select lists them."
  @spec kinds() :: [atom()]
  def kinds, do: Destination.kinds()

  @doc """
  The kind a form param names, or nil. Only a known kind's name matches, so
  a crafted value never becomes an atom.
  """
  @spec parse_kind(term()) :: atom() | nil
  def parse_kind(kind) when is_atom(kind) and not is_nil(kind),
    do: if(kind in kinds(), do: kind)

  def parse_kind(value) when is_binary(value),
    do: Enum.find(kinds(), &(Atom.to_string(&1) == value))

  def parse_kind(_value), do: nil

  @doc "The Type select's options, `{label, value}`."
  @spec kind_options() :: [{String.t(), String.t()}]
  def kind_options, do: Enum.map(kinds(), &{label(&1), Atom.to_string(&1)})

  @doc "A kind's label."
  @spec label(atom()) :: String.t()
  defdelegate label(kind), to: AuditStreamingRow, as: :type_label

  @doc "The settings keys `kind` may carry."
  @spec settings_keys(atom()) :: [String.t()]
  def settings_keys(kind), do: Map.get(Destination.settings_keys(), kind, [])

  @doc "The secret fields `kind` asks for, in the order the form shows them."
  @spec secret_fields(atom()) :: [:url | :credential]
  def secret_fields(:datadog), do: [:credential]
  def secret_fields(_splunk_or_https), do: [:url, :credential]

  @doc "The label of a secret field for `kind`."
  @spec secret_label(atom(), :url | :credential) :: String.t()
  def secret_label(:splunk_hec, :url), do: gettext("HEC URL")
  def secret_label(:splunk_hec, :credential), do: gettext("HEC token")
  def secret_label(:datadog, :credential), do: gettext("API key")
  def secret_label(:https, :url), do: gettext("URL")
  def secret_label(:https, :credential), do: gettext("Authorization header value")

  @doc "The Datadog sites, `{label, value}`, exactly the nine the adapter sends to."
  @spec datadog_site_options() :: [{String.t(), String.t()}]
  def datadog_site_options, do: Enum.map(Datadog.sites(), &{&1, &1})

  @doc "The HTTPS body formats, `{label, value}`."
  @spec format_options() :: [{String.t(), String.t()}]
  def format_options, do: [{gettext("JSON batch"), "json"}, {gettext("NDJSON"), "ndjson"}]

  @doc """
  A stored HTTPS body format's name, as `format_options/0` gives it. An
  unknown value, which the changeset refuses but an old row could hold, is
  returned as it is.
  """
  @spec format_label(String.t()) :: String.t()
  def format_label(value) do
    Enum.find_value(format_options(), value, fn {label, option} ->
      if option == value, do: label
    end)
  end

  @doc """
  The label of an HTTPS destination's `header_name` setting: the name of the
  header sent with the credential as its value. It is not a signature; Stride
  sets its own signature headers.
  """
  @spec header_name_label() :: String.t()
  def header_name_label, do: gettext("Authorization header name")

  @doc "The start points `kind` offers, `{label, value}`."
  @spec start_point_options(atom()) :: [{String.t(), String.t()}]
  def start_point_options(kind),
    do: kind |> StartPoint.options() |> Enum.map(&{start_point_label(&1), &1})

  @doc "A start point's label."
  @spec start_point_label(String.t()) :: String.t()
  def start_point_label("now"), do: gettext("Now: only new events")
  def start_point_label("24h"), do: gettext("The last 24 hours")
  def start_point_label("7d"), do: gettext("The last 7 days")
  def start_point_label("17h"), do: gettext("The last 17 hours")
  def start_point_label("all"), do: gettext("Everything in the audit log")

  @doc """
  `start_from` when `kind` offers it, else `"now"`, so a window left over
  from another type (a Datadog destination has no `"7d"`) falls back.
  """
  @spec normalize_start(atom(), term()) :: String.t()
  def normalize_start(kind, start_from) do
    if start_from in StartPoint.options(kind), do: start_from, else: "now"
  end

  @doc "Whether a start point sends past events: every one but `\"now\"`."
  @spec catch_up?(term()) :: boolean()
  def catch_up?(start_from), do: start_from not in [nil, "now"]

  @doc """
  The actions an org-admin may leave out, `{label, value}` sorted by label.
  No `audit_stream_*` action is ever offered (§12.3).
  """
  @spec excludable_options() :: [{String.t(), String.t()}]
  def excludable_options do
    Destination.excludable_actions()
    |> Enum.reject(&String.starts_with?(&1, "audit_stream_"))
    |> AuditLogActions.action_options()
    |> Enum.sort_by(fn {label, _action} -> label end)
  end

  @doc """
  The warning for a Splunk Cloud web address typed as the HEC URL, or nil.
  Only the URL being typed is checked, never a stored one.
  """
  @spec url_warning(atom(), term()) :: String.t() | nil
  def url_warning(:splunk_hec, url), do: SplunkHec.url_warning(url)
  def url_warning(_kind, _url), do: nil
end
