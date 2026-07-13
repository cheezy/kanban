defmodule Kanban.RateLimit do
  @moduledoc """
  Rate-limiting policy for abuse-prone authentication surfaces.

  Wraps the low-level `Kanban.RateLimiter` (Hammer/ETS) with per-surface
  thresholds and a two-key strategy: every check is evaluated against both a
  combined **IP + identity** key (the primary limit) and a looser **IP-only**
  ceiling. Both must pass. This stops single-source guessing across many
  accounts (the IP ceiling) and single-source targeting of one account (the
  IP+identity key) without letting one abuser behind a shared NAT/office IP lock
  everyone out (identity-only would allow that). It relies on
  `conn.remote_ip` being the real client IP — see `KanbanWeb.Plugs.RemoteClientIp`,
  which corrects it behind the Fly proxy. A botnet spread across many IPs is
  bounded per-source, not globally.

  ## Surfaces and default limits (window / IP+identity / IP-only)

    * `:login`     — 5 min  / 10 / 50   (failure-counted)
    * `:reset`     — 15 min / 3  / 15   (per submission)
    * `:resend`    — 15 min / 3  / 15   (per submission)
    * `:issue`     — 5 min  / 5  / 20   (per submission)
    * `:api_token` — 1 min  / 20        (IP-only, failure-counted)

  Thresholds are a product/ops decision — override per environment via:

      config :kanban, Kanban.RateLimit,
        login: %{scale_ms: 300_000, id_limit: 10, ip_limit: 50}

  ## Operations

    * `check/2`  — increment and evaluate; use for per-submission surfaces
      (`:reset`, `:resend`, `:issue`).
    * `peek/2`   — evaluate WITHOUT incrementing; use to block before doing work
      (`:login`, `:api_token`) so a flood cannot force password hashing or DB
      lookups.
    * `record_failure/2` — increment the failure counter after an authentication
      attempt fails; pair with `peek/2`.

  All three return `:ok` or `{:error, {:rate_limited, retry_after_ms}}`.
  """

  @default_limits %{
    login: %{scale_ms: 300_000, id_limit: 10, ip_limit: 50},
    reset: %{scale_ms: 900_000, id_limit: 3, ip_limit: 15},
    resend: %{scale_ms: 900_000, id_limit: 3, ip_limit: 15},
    issue: %{scale_ms: 300_000, id_limit: 5, ip_limit: 20},
    api_token: %{scale_ms: 60_000, ip_limit: 20}
  }

  @type surface :: :login | :reset | :resend | :issue | :api_token
  @type opts :: [ip: term(), identity: String.t() | nil]
  @type result :: :ok | {:error, {:rate_limited, non_neg_integer()}}

  @doc "Increment the counters and evaluate. For per-submission surfaces."
  @spec check(surface(), opts()) :: result()
  def check(surface, opts) do
    if enabled?(), do: evaluate(surface, opts, 1), else: :ok
  end

  @doc """
  Evaluate WITHOUT incrementing. For block-before-work surfaces (`:login`,
  `:api_token`): denies once the recorded failure count has reached the limit.
  """
  @spec peek(surface(), opts()) :: result()
  def peek(surface, opts) do
    if enabled?(), do: evaluate_peek(surface, opts), else: :ok
  end

  @doc "Record a failed attempt (increment the counters, ignore the verdict)."
  @spec record_failure(surface(), opts()) :: :ok
  def record_failure(surface, opts) do
    if enabled?(), do: evaluate(surface, opts, 1)
    :ok
  end

  # Defaults on (prod/dev); the test environment turns it off globally and the
  # throttle-specific tests opt back in with known limits, so the broad suite
  # never trips the shared-IP counters.
  defp enabled? do
    Application.get_env(:kanban, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  defp evaluate(surface, opts, increment) do
    limits = limits_for(surface)
    ip = format_ip(Keyword.get(opts, :ip))
    identity = normalize_identity(Keyword.get(opts, :identity))

    limits
    |> keyed_checks(surface, ip, identity)
    |> Enum.reduce(:ok, fn {key, limit}, acc ->
      combine(acc, hit(key, limits.scale_ms, limit, increment))
    end)
  end

  # Non-incrementing evaluation: read the current window count and deny when it
  # has reached the limit, so a surface that records failures via
  # `record_failure/2` blocks exactly on the (limit+1)th attempt.
  defp evaluate_peek(surface, opts) do
    limits = limits_for(surface)
    ip = format_ip(Keyword.get(opts, :ip))
    identity = normalize_identity(Keyword.get(opts, :identity))

    limits
    |> keyed_checks(surface, ip, identity)
    |> Enum.reduce(:ok, fn {key, limit}, acc ->
      count = Kanban.RateLimiter.get(key, limits.scale_ms)

      if count >= limit do
        combine(acc, {:error, {:rate_limited, limits.scale_ms}})
      else
        combine(acc, :ok)
      end
    end)
  end

  # The IP-only ceiling always applies; the combined IP+identity key only when
  # an identity is present (absent for :api_token, and defensively for any
  # surface called without one).
  defp keyed_checks(limits, surface, ip, identity) do
    ip_check = [{"#{surface}:ip:#{ip}", limits.ip_limit}]

    case {identity, Map.fetch(limits, :id_limit)} do
      {nil, _} -> ip_check
      {_identity, :error} -> ip_check
      {identity, {:ok, id_limit}} -> [{"#{surface}:id:#{ip}:#{identity}", id_limit} | ip_check]
    end
  end

  defp hit(key, scale_ms, limit, increment) do
    case Kanban.RateLimiter.hit(key, scale_ms, limit, increment) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  # A single denied bucket denies the whole check; keep the longest retry hint.
  defp combine(:ok, :ok), do: :ok
  defp combine(:ok, {:error, _} = err), do: err
  defp combine({:error, _} = err, :ok), do: err

  defp combine({:error, {:rate_limited, a}}, {:error, {:rate_limited, b}}),
    do: {:error, {:rate_limited, max(a, b)}}

  defp limits_for(surface) do
    overrides = Application.get_env(:kanban, __MODULE__, [])
    base = Map.fetch!(@default_limits, surface)

    case Keyword.get(overrides, surface) do
      nil -> base
      %{} = override -> Map.merge(base, override)
    end
  end

  defp normalize_identity(nil), do: nil

  defp normalize_identity(identity) when is_binary(identity) do
    case identity |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  # Accept a raw IP tuple (conn.remote_ip / peer_data address) or a string.
  defp format_ip(nil), do: "unknown"
  defp format_ip(ip) when is_binary(ip), do: ip

  defp format_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> "unknown"
      charlist -> to_string(charlist)
    end
  end

  defp format_ip(_), do: "unknown"
end
