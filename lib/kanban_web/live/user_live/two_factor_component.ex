defmodule KanbanWeb.UserLive.TwoFactorComponent do
  @moduledoc """
  The Two-factor section of the account settings page.

  A small state machine over `Kanban.Accounts.TwoFactor`:

    * `:disabled` — two-factor is off; the user can start enrollment.
    * `:enrolling` — shows the QR code and the manual key, and waits for a
      valid code. Two-factor is still off until that code is accepted.
    * `:codes` — shows the ten recovery codes, once, after enabling or
      regenerating. They are never shown again.
    * `:enabled` — two-factor is on; the user can regenerate recovery codes
      (needs a current code) or turn it off (a current code or a recovery
      code).

  The enrollment secret, as the QR image and manual key, lives in assigns only
  while `:enrolling`, and the recovery codes only while `:codes`; both are
  dropped as soon as the user moves on. Rendered by `KanbanWeb.UserLive.Settings`,
  which is sudo-gated; every change still needs a fresh code here, because the
  sudo check runs only when the page mounts.
  """
  use KanbanWeb, :live_component

  alias Kanban.Accounts

  @input_style "width: 100%; max-width: 220px; padding: 0 10px; height: 32px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 13px; color: var(--ink); outline: none; font-family: var(--font-mono); letter-spacing: 0.08em;"
  @primary_style "height: 32px; padding: 0 14px; border-radius: 5px; background: var(--ink); color: var(--color-base-100); border: none; font-size: 12.5px; font-weight: 500; letter-spacing: -0.005em; cursor: pointer; box-shadow: 0 1px 0 rgba(0, 0, 0, 0.1) inset, 0 1px 2px rgba(0, 0, 0, 0.15);"
  @secondary_style "height: 32px; padding: 0 14px; border-radius: 5px; background: transparent; color: var(--ink-2); border: 1px solid var(--line-strong); font-size: 12.5px; font-weight: 500; cursor: pointer;"

  @impl true
  def mount(socket) do
    {:ok, assign(socket, enrollment: nil, recovery_codes: nil, error: nil, error_form: nil)}
  end

  @impl true
  def update(%{user: user} = assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if Map.has_key?(socket.assigns, :state),
        do: socket,
        else: assign(socket, :state, initial_state(user))

    {:ok, socket}
  end

  defp initial_state(user) do
    if Accounts.two_factor_enabled?(user), do: :enabled, else: :disabled
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        input_style: @input_style,
        primary_style: @primary_style,
        secondary_style: @secondary_style
      )

    ~H"""
    <div id={@id} style="display: flex; flex-direction: column; gap: 16px;">
      <.status enabled={@state in [:enabled, :codes]} />

      <div :if={@state == :disabled}>
        <p style="margin: 0 0 12px; font-size: 12.5px; color: var(--ink-2); line-height: 1.55; max-width: 560px; text-wrap: pretty;">
          {gettext(
            "Add a second step to signing in: a 6-digit code from an authenticator app such as 1Password, Google Authenticator or Authy."
          )}
        </p>
        <button
          id="two-factor-begin"
          type="button"
          phx-click="begin"
          phx-target={@myself}
          style={@primary_style}
        >
          {gettext("Set up two-factor authentication")}
        </button>
      </div>

      <div :if={@state == :enrolling} style="display: flex; flex-direction: column; gap: 14px;">
        <p style="margin: 0; font-size: 12.5px; color: var(--ink-2); line-height: 1.55; max-width: 560px; text-wrap: pretty;">
          {gettext(
            "Scan this QR code with your authenticator app, or enter the key by hand. Then enter the 6-digit code the app shows."
          )}
        </p>
        <div class="flex flex-col @md:flex-row gap-4 @md:items-center">
          <%!-- The SVG has no quiet zone; scanners need a light margin around the code.
                dark-mode-ignore: a QR code needs a fixed light quiet zone in both themes --%>
          <div style="background: #fff; padding: 12px; border-radius: 8px; border: 1px solid var(--line); align-self: flex-start; line-height: 0;">
            <img
              id="two-factor-qr"
              src={@enrollment.qr_data_uri}
              alt={gettext("QR code for your authenticator app")}
              width="184"
              height="184"
              style="width: 184px; height: 184px;"
            />
          </div>
          <div style="display: flex; flex-direction: column; gap: 4px; min-width: 0;">
            <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
              {gettext("Key")}
            </span>
            <code
              id="two-factor-key"
              style="font-family: var(--font-mono); font-size: 13px; color: var(--ink); overflow-wrap: anywhere; letter-spacing: 0.04em;"
            >
              {@enrollment.manual_key}
            </code>
          </div>
        </div>
        <.form
          for={%{}}
          as={:two_factor}
          id="two-factor-confirm-form"
          phx-submit="confirm"
          phx-target={@myself}
          style="display: flex; flex-direction: column; gap: 10px;"
        >
          <.code_field
            id="two-factor-confirm-code"
            label={gettext("6-digit code")}
            style={@input_style}
            error={@error_form == :confirm && @error}
          />
          <div style="display: flex; gap: 8px; flex-wrap: wrap;">
            <button type="submit" phx-disable-with={gettext("Checking...")} style={@primary_style}>
              {gettext("Verify and turn on")}
            </button>
            <button
              id="two-factor-cancel"
              type="button"
              phx-click="cancel"
              phx-target={@myself}
              style={@secondary_style}
            >
              {gettext("Cancel")}
            </button>
          </div>
        </.form>
      </div>

      <div :if={@state == :codes} style="display: flex; flex-direction: column; gap: 12px;">
        <p
          role="alert"
          style="margin: 0; font-size: 12.5px; color: var(--ink); line-height: 1.55; max-width: 560px; text-wrap: pretty;"
        >
          <strong>{gettext("Save these recovery codes now. They will not be shown again.")}</strong>
          {gettext(
            "Each code can be used once to sign in or to turn off two-factor if you lose your authenticator."
          )}
        </p>
        <ol
          id="two-factor-recovery-codes"
          class="grid grid-cols-1 min-[420px]:grid-cols-2"
          style="margin: 0; padding: 12px 16px; list-style: none; gap: 6px 24px; border: 1px solid var(--line); border-radius: 6px; background: var(--bg); max-width: 360px;"
        >
          <li
            :for={code <- @recovery_codes}
            style="font-family: var(--font-mono); font-size: 13px; color: var(--ink); letter-spacing: 0.04em;"
          >
            {code}
          </li>
        </ol>
        <div>
          <button
            id="two-factor-codes-saved"
            type="button"
            phx-click="codes_saved"
            phx-target={@myself}
            style={@primary_style}
          >
            {gettext("I have saved these codes")}
          </button>
        </div>
      </div>

      <div :if={@state == :enabled} class="grid grid-cols-1 @2xl:grid-cols-2 gap-5">
        <.form
          for={%{}}
          as={:two_factor}
          id="two-factor-regenerate-form"
          phx-submit="regenerate"
          phx-target={@myself}
          style="display: flex; flex-direction: column; gap: 10px;"
        >
          <h3 style="margin: 0; font-size: 13px; font-weight: 600; color: var(--ink);">
            {gettext("New recovery codes")}
          </h3>
          <p style="margin: 0; font-size: 12px; color: var(--ink-3); line-height: 1.5; text-wrap: pretty;">
            {gettext("Replaces all of your recovery codes. The old ones stop working.")}
          </p>
          <.code_field
            id="two-factor-regenerate-code"
            label={gettext("6-digit code")}
            style={@input_style}
            error={@error_form == :regenerate && @error}
          />
          <div>
            <button type="submit" phx-disable-with={gettext("Checking...")} style={@primary_style}>
              {gettext("Generate new codes")}
            </button>
          </div>
        </.form>

        <.form
          for={%{}}
          as={:two_factor}
          id="two-factor-disable-form"
          phx-submit="disable"
          phx-target={@myself}
          style="display: flex; flex-direction: column; gap: 10px;"
        >
          <h3 style="margin: 0; font-size: 13px; font-weight: 600; color: var(--ink);">
            {gettext("Turn off two-factor")}
          </h3>
          <p style="margin: 0; font-size: 12px; color: var(--ink-3); line-height: 1.5; text-wrap: pretty;">
            {gettext(
              "Enter a code from your authenticator app, or a recovery code if you no longer have it."
            )}
          </p>
          <.code_field
            id="two-factor-disable-code"
            label={gettext("Code or recovery code")}
            style={@input_style}
            error={@error_form == :disable && @error}
            inputmode="text"
          />
          <div>
            <button type="submit" phx-disable-with={gettext("Checking...")} style={@secondary_style}>
              {gettext("Turn off two-factor")}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr :enabled, :boolean, required: true

  defp status(assigns) do
    ~H"""
    <div id="two-factor-status" style="display: flex; align-items: center; gap: 8px;">
      <.icon
        name={if @enabled, do: "hero-shield-check", else: "hero-shield-exclamation"}
        class="w-4 h-4"
      />
      <span style="font-size: 12.5px; font-weight: 600; color: var(--ink);">
        {if @enabled,
          do: gettext("Two-factor authentication is on."),
          else: gettext("Two-factor authentication is off.")}
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :style, :string, required: true
  attr :error, :any, default: nil
  attr :inputmode, :string, default: "numeric"

  defp code_field(assigns) do
    ~H"""
    <label style="display: flex; flex-direction: column; gap: 5px;">
      <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">{@label}</span>
      <input
        type="text"
        name="code"
        id={@id}
        value=""
        inputmode={@inputmode}
        autocomplete="one-time-code"
        autocapitalize="off"
        spellcheck="false"
        maxlength="32"
        required
        aria-invalid={@error && "true"}
        aria-describedby={@error && "#{@id}-error"}
        style={@style}
      />
      <span
        :if={@error}
        id={"#{@id}-error"}
        style="font-size: 11.5px; color: var(--st-blocked); line-height: 1.45;"
      >
        {@error}
      </span>
    </label>
    """
  end

  @impl true
  def handle_event("begin", _params, socket) do
    user = socket.assigns.user

    case Accounts.begin_two_factor_enrollment(user) do
      {:ok, %{secret: secret, otpauth_uri: uri}} ->
        enrollment = %{qr_data_uri: qr_data_uri(uri), manual_key: manual_key(secret)}
        {:noreply, assign(socket, state: :enrolling, enrollment: enrollment, error: nil)}

      {:error, :already_enabled} ->
        {:noreply, assign(socket, state: :enabled, error: nil)}
    end
  end

  def handle_event("cancel", _params, socket) do
    :ok = Accounts.cancel_two_factor_enrollment(socket.assigns.user)
    {:noreply, assign(socket, state: :disabled, enrollment: nil, error: nil)}
  end

  def handle_event("confirm", %{"code" => code}, socket) do
    case Accounts.confirm_two_factor_enrollment(socket.assigns.user, code) do
      {:ok, codes} ->
        {:noreply,
         socket
         |> assign(state: :codes, enrollment: nil, recovery_codes: codes, error: nil)
         |> put_flash(:info, gettext("Two-factor authentication is on."))}

      {:error, :invalid_code} ->
        {:noreply, invalid_code(socket, :confirm)}

      {:error, :rate_limited} ->
        {:noreply, rate_limited(socket, :confirm)}

      {:error, :not_enrolling} ->
        {:noreply, assign(socket, state: initial_state(socket.assigns.user), enrollment: nil)}
    end
  end

  def handle_event("codes_saved", _params, socket) do
    {:noreply, assign(socket, state: :enabled, recovery_codes: nil)}
  end

  def handle_event("regenerate", %{"code" => code}, socket) do
    case Accounts.regenerate_recovery_codes(socket.assigns.user, code) do
      {:ok, codes} ->
        {:noreply, assign(socket, state: :codes, recovery_codes: codes, error: nil)}

      {:error, :invalid_code} ->
        {:noreply, invalid_code(socket, :regenerate)}

      {:error, :rate_limited} ->
        {:noreply, rate_limited(socket, :regenerate)}

      {:error, :not_enabled} ->
        {:noreply, assign(socket, state: :disabled, error: nil)}
    end
  end

  def handle_event("disable", %{"code" => code}, socket) do
    case Accounts.disable_two_factor(socket.assigns.user, code) do
      :ok ->
        {:noreply,
         socket
         |> assign(state: :disabled, error: nil)
         |> put_flash(:info, gettext("Two-factor authentication is off."))}

      {:error, :invalid_code} ->
        {:noreply, invalid_code(socket, :disable)}

      {:error, :rate_limited} ->
        {:noreply, rate_limited(socket, :disable)}

      {:error, :not_enabled} ->
        {:noreply, assign(socket, state: :disabled, error: nil)}
    end
  end

  defp invalid_code(socket, form) do
    assign(socket,
      error: gettext("That code is not valid. Check it and try again."),
      error_form: form
    )
  end

  defp rate_limited(socket, form) do
    assign(socket,
      error: gettext("Too many attempts. Please wait a few minutes and try again."),
      error_form: form
    )
  end

  defp qr_data_uri(otpauth_uri) do
    svg = otpauth_uri |> EQRCode.encode() |> EQRCode.svg(width: 184)
    "data:image/svg+xml;base64," <> Base.encode64(svg)
  end

  # The key as authenticator apps expect it typed: base32, in groups of four.
  defp manual_key(secret) do
    secret
    |> Base.encode32(padding: false)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end
end
