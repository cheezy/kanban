defmodule KanbanWeb.Analytics do
  @moduledoc """
  Umami analytics (W2897): the tracker tag, the one-shot signup trigger and
  the configuration both of them, and `KanbanWeb.Plugs.CspNonce`, read.

  Analytics is configured by `config :kanban, :umami` with `script_url`,
  `website_id` and `host_url`, which `config/runtime.exs` sets from
  `UMAMI_SCRIPT_URL`, `UMAMI_WEBSITE_ID` and `UMAMI_HOST_URL` only when all
  three are set. Without it, `config/0` returns `nil`, nothing renders and the
  CSP is unchanged.

  A page loads the tracker only when it opted in with the `:analytics` assign,
  which `KanbanWeb.Plugs.PutAnalytics` (controllers) and
  `KanbanWeb.AnalyticsOnMount` (LiveViews) set. It is off by default, so a new
  signed-in page never loads it. The tracker is told to drop the query string
  and the fragment (`data-exclude-search`, `data-exclude-hash`), because
  `/users/confirmation-pending` carries an email address in its query string,
  and to count only the canonical host (`data-domains`). `data-before-send`
  names the hook in `assets/js/analytics.js` that also strips them from the
  referrer. Nothing here identifies a visitor: no `umami.identify`, no
  `data-distinct-id`, no cookie. `docs/analytics.md` has the events and the
  rules for adding one.
  """
  use Phoenix.Component

  @uuid ~r/\A[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i

  # A plain DNS name. The host is spliced into the CSP, so a '*', ';', ',' or
  # quote must never pass: each would widen the policy or end the directive.
  @hostname ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z/i

  @typedoc "The validated Umami settings, with the two origins the CSP allows."
  @type config :: %{
          script_url: String.t(),
          website_id: String.t(),
          host_url: String.t(),
          script_origin: String.t(),
          connect_origin: String.t()
        }

  @doc """
  The Umami settings, or `nil` when analytics is off.

  It re-checks what `config/runtime.exs` already checked, so a partial or
  malformed application environment turns analytics off rather than
  rendering a broken tag or widening the CSP.
  """
  @spec config() :: config() | nil
  def config, do: :kanban |> Application.get_env(:umami) |> validated()

  defp validated(settings) when is_list(settings) do
    settings
    |> Enum.filter(&match?({key, _value} when key in [:script_url, :website_id, :host_url], &1))
    |> Map.new()
    |> with_origins()
  end

  defp validated(_settings), do: nil

  defp with_origins(%{script_url: script_url, website_id: website_id, host_url: host_url} = umami)
       when is_binary(script_url) and is_binary(website_id) and is_binary(host_url) do
    with true <- Regex.match?(@uuid, website_id),
         {:ok, script_origin} <- origin(script_url),
         {:ok, connect_origin} <- origin(host_url) do
      Map.merge(umami, %{script_origin: script_origin, connect_origin: connect_origin})
    else
      _off -> nil
    end
  end

  defp with_origins(_umami), do: nil

  @doc """
  Whether analytics is configured.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: config() != nil

  @doc """
  The CSP source for an https URL: `https://host`, with `:port` only when it
  is not 443. Anything else (another scheme, no host, a host that is not a
  plain DNS name such as `*` or one with `;`, user info) is `:error`.
  """
  @spec origin(String.t()) :: {:ok, String.t()} | :error
  def origin(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, port: port}
      when is_binary(host) ->
        plain_origin(host, port)

      _other ->
        :error
    end
  end

  def origin(_url), do: :error

  defp plain_origin(host, port) do
    if Regex.match?(@hostname, host),
      do: {:ok, "https://" <> String.downcase(host) <> port_suffix(port)},
      else: :error
  end

  defp port_suffix(port) when port in [nil, 443], do: ""
  defp port_suffix(port), do: ":#{port}"

  @doc """
  The Umami tracker tag, rendered only when the page opted in and analytics
  is configured. Layouts put it before `app.js`, so `window.umami` exists
  before the LiveView hooks mount.
  """
  attr :enabled, :boolean, default: false, doc: "whether the page opted in"
  attr :nonce, :string, default: nil, doc: "the request CSP nonce"

  def tracker(assigns) do
    assigns = assign(assigns, :umami, assigns.enabled && config())

    ~H"""
    <script
      :if={@umami}
      defer
      src={@umami.script_url}
      data-website-id={@umami.website_id}
      data-host-url={@umami.host_url}
      data-domains={KanbanWeb.Endpoint.host()}
      data-exclude-search="true"
      data-exclude-hash="true"
      data-before-send="strideAnalyticsBeforeSend"
      nonce={@nonce}
    >
    </script>
    """
  end

  @doc """
  The hidden element whose `AnalyticsSignup` hook sends the signup event.
  `KanbanWeb.UserLive.ConfirmationPending` renders it only on the request
  right after a successful registration, and only when analytics is
  configured. It carries no data about the person.
  """
  def signup_event(assigns) do
    assigns = assign(assigns, :enabled, enabled?())

    ~H"""
    <div :if={@enabled} id="analytics-signup-event" phx-hook="AnalyticsSignup" hidden></div>
    """
  end
end
