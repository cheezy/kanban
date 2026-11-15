defmodule KanbanWeb.OrgLive.AuditStreamFormView do
  @moduledoc """
  The pure helpers behind the audit stream destination form
  (`KanbanWeb.OrgLive.AuditStreamForm`, design §10.3): turning the submitted
  params into the attributes `Kanban.AuditStream` takes, and a changeset into
  the plain values and translated error texts the template renders.

  The form never renders a changeset. Its values come from `values/2`, which
  reads only the non-secret fields, so a stored or typed URL, credential or
  signing secret can never reach the page (§12.2); a secret input is always
  rendered empty. A saved secret is shown only as its hint (`hints/1`) and
  its state (`secret_states/1`): stored, can't be read, or not set.

  Blank means keep: `attrs/3` passes a URL or credential only when one was
  typed, so a blank field leaves the stored secret as it is.
  """
  use Gettext, backend: KanbanWeb.Gettext

  alias Ecto.Changeset
  alias Kanban.AuditStream.Destination
  alias Kanban.Webhooks.UrlGuard
  alias KanbanWeb.CoreComponents
  alias KanbanWeb.OrgLive.AuditStreamKinds

  @guard_reasons ~w(too_long invalid_url scheme_not_allowed userinfo_not_allowed invalid_port
                    invalid_host blocked_address unresolvable)a

  # Errors with no input of their own to mark as touched, shown on every render.
  @always_shown [:kind, :start_from, :excluded_actions, :settings]

  # The secret inputs are named destination[secret_token][url] and
  # destination[secret_token][credential]: a key holding "token" is filtered
  # by :filter_parameters, so LiveView's event log and ErrorTracker's event
  # params never hold the plaintext (§12.2).
  @secret_key "secret_token"

  @doc """
  The attributes for the context from the form's `params`. `:new` keeps the
  submitted `kind` and start point as given (the context refuses an unknown
  kind and a start point the kind does not offer); `:edit` drops both, since
  neither can change after creation, and leaves the settings out when none
  were sent. A blank URL or credential is left out, and the Datadog form
  never sends a URL.
  """
  @spec attrs(map(), :new | :edit, atom() | nil) :: map()
  def attrs(params, action, kind) when is_map(params) do
    params
    |> base_attrs(kind)
    |> put_action_attrs(params, action, kind)
  end

  defp base_attrs(params, kind) do
    %{}
    |> put_present(params, "name")
    |> put_present(params, "include_personal_data")
    |> put_secrets(params, kind)
    |> put_settings(params, kind)
    |> put_excluded(params)
  end

  # The form always sends its type's settings inputs, so an edit without
  # them changes no setting rather than emptying the stored ones.
  defp put_settings(attrs, %{"settings" => %{} = submitted}, kind),
    do: Map.put(attrs, "settings", settings(submitted, kind))

  defp put_settings(attrs, _params, _kind), do: attrs

  defp put_action_attrs(attrs, params, :new, kind) do
    attrs
    |> Map.put("kind", params["kind"] || to_string(kind))
    |> Map.put_new("settings", %{})
    |> Map.put("start_from", start_from(params["start_from"]))
  end

  defp put_action_attrs(attrs, _params, :edit, _kind), do: attrs

  # A start point the type does not offer goes to the context, which refuses
  # it on :start_from, rather than being saved as "now" (§8.5).
  defp start_from(start_from) when start_from in [nil, ""], do: "now"
  defp start_from(start_from), do: start_from

  defp put_present(attrs, params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(attrs, key, value)
      :error -> attrs
    end
  end

  defp put_secrets(attrs, params, kind) do
    kind
    |> AuditStreamKinds.secret_fields()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.reduce(attrs, fn key, acc ->
      if typed?(params[key]), do: Map.put(acc, key, params[key]), else: acc
    end)
  end

  defp put_excluded(attrs, %{"excluded_actions" => actions}),
    do: Map.put(attrs, "excluded_actions", actions |> List.wrap() |> Enum.reject(&(&1 == "")))

  defp put_excluded(attrs, _params), do: attrs

  @doc """
  The form's params with the secrets lifted out of `#{@secret_key}` to the
  top-level `"url"` and `"credential"` keys `attrs/3` reads. A top-level
  `"url"` or `"credential"` is dropped, so only the filtered key carries a
  secret.
  """
  @spec lift_secrets(map()) :: map()
  def lift_secrets(params) when is_map(params) do
    secrets =
      case params[@secret_key] do
        %{} = submitted -> Map.take(submitted, ["url", "credential"])
        _other -> %{}
      end

    params
    |> Map.drop([@secret_key, "url", "credential"])
    |> Map.merge(secrets)
  end

  @doc "The input name of a secret field."
  @spec secret_input_name(:url | :credential) :: String.t()
  def secret_input_name(field), do: "destination[#{@secret_key}][#{field}]"

  @doc """
  The settings for `kind` from the submitted settings map: only `kind`'s
  keys, blank values left out, and the Datadog tags split from the textarea
  on whitespace and commas.
  """
  @spec settings(term(), atom() | nil) :: map()
  def settings(submitted, kind) when is_map(submitted) do
    submitted
    |> Map.take(AuditStreamKinds.settings_keys(kind))
    |> Enum.flat_map(&setting/1)
    |> Map.new()
  end

  def settings(_submitted, _kind), do: %{}

  defp setting({"tags", text}) when is_binary(text) do
    text
    |> String.split(~r/[\s,]+/u, trim: true)
    |> case do
      [] -> []
      tags -> [{"tags", tags}]
    end
  end

  defp setting({key, value}) when is_binary(value) do
    if String.trim(value) == "", do: [], else: [{key, value}]
  end

  # A value the form never sends (not text) goes to the context as given,
  # which refuses it on :settings, rather than being dropped unseen.
  defp setting(pair), do: [pair]

  @doc """
  The values the form shows: the name, the personal-data flag, the settings,
  the excluded actions and, while typing, the raw name and tags. Never a URL
  or credential.
  """
  @spec values(Changeset.t(), map()) :: map()
  def values(%Changeset{} = changeset, params) do
    settings = changeset |> Changeset.get_field(:settings) |> displayable()

    %{
      name: raw_or(params, "name", Changeset.get_field(changeset, :name)),
      include_personal_data: Changeset.get_field(changeset, :include_personal_data) != false,
      settings: settings,
      tags: raw_tags(params) || settings["tags"] |> List.wrap() |> Enum.join("\n"),
      excluded_actions: changeset |> Changeset.get_field(:excluded_actions) |> List.wrap()
    }
  end

  # Only text reaches an input. A crafted non-text setting stays in the
  # changeset for the context to refuse, but rendering it as an input value
  # would raise after the event, outside the form's containment.
  defp displayable(%{} = settings) do
    Map.filter(settings, fn
      {"tags", tags} -> is_list(tags) and Enum.all?(tags, &is_binary/1)
      {_key, value} -> is_binary(value)
    end)
  end

  defp displayable(_settings), do: %{}

  defp raw_or(params, key, default) do
    case params[key] do
      value when is_binary(value) -> value
      _absent -> default
    end
  end

  defp raw_tags(%{"settings" => %{"tags" => text}}) when is_binary(text), do: text
  defp raw_tags(_params), do: nil

  @doc """
  The changeset's errors as translated text, keyed by the input they belong
  to, keeping only those the person can act on: every error once the form
  was submitted, else only errors of an input already typed in. A stale
  `lock_version` (`:id`) is left out; the form reports it on its own.
  """
  @spec errors(Changeset.t(), map(), boolean()) :: %{atom() => [String.t()]}
  def errors(%Changeset{errors: errors}, params, submitted?) do
    errors
    |> Enum.reject(&stale_error?/1)
    |> drop_settings_of_unknown_kind()
    |> Enum.map(&present/1)
    |> Enum.filter(&visible?(&1, params, submitted?))
    |> group_texts()
  end

  defp stale_error?({field, _error}), do: field == :id

  # With no known type the settings can't be judged, so only the type's own
  # error is shown, not a settings error for the type still on screen.
  defp drop_settings_of_unknown_kind(errors) do
    if Keyword.has_key?(errors, :kind),
      do: Enum.reject(errors, fn {field, _error} -> field == :settings end),
      else: errors
  end

  defp visible?({key, _text}, params, submitted?), do: submitted? or shown?(key, params)

  defp group_texts(errors) do
    errors
    |> Enum.group_by(fn {key, _text} -> key end, fn {_key, text} -> text end)
    |> Map.new(fn {key, texts} -> {key, Enum.uniq(texts)} end)
  end

  @doc "Whether the changeset's errors include a stale `lock_version`."
  @spec stale?(Changeset.t()) :: boolean()
  def stale?(%Changeset{errors: errors}),
    do: Enum.any?(errors, fn {field, {_msg, opts}} -> field == :id and opts[:stale] end)

  defp shown?(key, _params) when key in @always_shown, do: true

  defp shown?(:credential, params),
    do: typed?(params["credential"]) or typed_setting?(params, "header_name")

  defp shown?(key, params) when key in [:name, :url], do: typed?(params[Atom.to_string(key)])
  defp shown?(key, params), do: typed_setting?(params, Atom.to_string(key))

  defp typed_setting?(%{"settings" => settings}, key) when is_map(settings),
    do: typed?(settings[key])

  defp typed_setting?(_params, _key), do: false

  defp typed?(value) when is_binary(value), do: String.trim(value) != ""
  defp typed?(_value), do: false

  @doc "An error as `{input, translated text}`."
  @spec present({atom(), {String.t(), keyword()}}) :: {atom(), String.t()}
  def present({:settings, {_msg, opts}}), do: present_setting(opts[:validation])

  def present({field, {_msg, opts}} = error) when field in [:url, :credential] do
    case opts[:validation] || opts[:reason] do
      :unreadable -> {field, unreadable_text()}
      validation -> {field, secret_error(field, validation, error)}
    end
  end

  def present({:excluded_actions, {_msg, opts}}) do
    if opts[:validation] == :audit_stream_action,
      do: {:excluded_actions, gettext("Changes to audit streaming can't be left out.")},
      else: {:excluded_actions, gettext("Choose actions from the list.")}
  end

  def present({:start_from, _error}),
    do: {:start_from, gettext("Choose one of the listed start points.")}

  def present({:kind, _error}), do: {:kind, gettext("Choose a destination type.")}
  def present({field, error}), do: {field, CoreComponents.translate_error(error)}

  defp present_setting(:site), do: {:site, gettext("Choose one of the listed Datadog sites.")}

  defp present_setting(:tags),
    do:
      {:tags,
       gettext(
         "Use at most 90 tags of the form key:value, each at most 200 characters. Stride sets the keys source and organization_id itself."
       )}

  defp present_setting(:index),
    do: {:index, gettext("Use lowercase letters, digits, _ and -, at most 80 characters.")}

  defp present_setting(:service), do: {:service, gettext("At most 100 characters.")}
  defp present_setting(:source_type), do: {:source_type, gettext("At most 100 characters.")}

  defp present_setting(:format), do: {:format, gettext("Choose JSON batch or NDJSON.")}
  defp present_setting(:header_name), do: {:header_name, gettext("Enter a valid header name.")}

  defp present_setting(:reserved_header),
    do: {:header_name, gettext("Stride sets this header itself. Choose another name.")}

  defp present_setting(:header_name_required),
    do: {:credential, gettext("Enter the header name for this value.")}

  defp present_setting(_other),
    do: {:settings, gettext("These settings don't belong to this type.")}

  defp secret_error(:url, :path, _error),
    do: gettext("Use the collector path /services/collector or /services/collector/event.")

  defp secret_error(:url, :query, _error),
    do: gettext("Remove the query string. Splunk takes the token in a header.")

  defp secret_error(:url, validation, _error) when validation in [:url, :url_host, :kind],
    do: gettext("Enter a valid https:// address.")

  defp secret_error(:url, reason, _error) when reason in @guard_reasons,
    do: Gettext.dgettext(KanbanWeb.Gettext, "errors", UrlGuard.error_message(reason))

  defp secret_error(:credential, :header_value, _error),
    do: gettext("This value has characters that can't be sent in a header.")

  defp secret_error(:credential, :required, _error),
    do: gettext("Enter the header value, or clear the header name.")

  defp secret_error(_field, _validation, {_field_name, error}),
    do: CoreComponents.translate_error(error)

  @doc "The text for a saved URL or credential that can no longer be read (D17)."
  @spec unreadable_text() :: String.t()
  def unreadable_text, do: gettext("Can't be read. Enter it again.")

  @doc """
  Each secret field's state on a saved destination: `:stored`, `:unreadable`
  (written under a lost or replaced key) or `:empty`. Only the state is kept,
  never the value.
  """
  @spec secret_states(Destination.t()) :: %{url: atom(), credential: atom()}
  def secret_states(%Destination{} = destination),
    do: %{url: state(destination.url), credential: state(destination.credential)}

  defp state(:unreadable), do: :unreadable
  defp state(value) when is_binary(value), do: :stored
  defp state(_unset), do: :empty

  @doc "What each saved secret shows in its place: `•••• ` and its hint."
  @spec hints(Destination.t()) :: %{url: String.t(), credential: String.t()}
  def hints(%Destination{} = destination),
    do: %{url: hint(destination.url_hint), credential: hint(destination.credential_hint)}

  defp hint(hint) when is_binary(hint) and hint != "", do: "•••• " <> hint
  defp hint(_none), do: "••••"

  @doc "The two settings that change what a batch carries (D16), comparable."
  @spec filters(map()) :: {boolean(), [String.t()]}
  def filters(%{include_personal_data: personal, excluded_actions: actions}),
    do: {personal != false, actions |> List.wrap() |> Enum.sort()}

  @doc "Whether the form's filters differ from the stored ones."
  @spec filters_changed?(map(), {boolean(), [String.t()]} | nil) :: boolean()
  def filters_changed?(_values, nil), do: false
  def filters_changed?(values, stored), do: filters(values) != stored

  @doc """
  Whether saving turns Include email and IP addresses off: it is off in the
  form and was on (on is the default for a new destination).
  """
  @spec personal_data_off?(map(), {boolean(), [String.t()]} | nil) :: boolean()
  def personal_data_off?(%{include_personal_data: false}, {true, _actions}), do: true
  def personal_data_off?(%{include_personal_data: false}, nil), do: true
  def personal_data_off?(_values, _stored), do: false
end
