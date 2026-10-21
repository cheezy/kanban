defmodule KanbanWeb.TokenPaths do
  @moduledoc """
  The routes that carry a plaintext secret token as a path segment, and
  redaction of that segment.

  `:filter_parameters` hides a `token` param in logged parameters, but a
  token in the path also shows up wherever the raw path or URL is recorded:
  Phoenix's request log line (`GET /invitations/<token>`) and ErrorTracker's
  request path, LiveView URI and Referer header. `KanbanWeb.RequestLog` and
  `KanbanWeb.ErrorTrackerFilter` use this module to keep those out.

  The routes are the invitation link (`/invitations/:token`, W2219), password
  reset, account confirmation and email-change confirmation. A path with
  repeated slashes (`/users//confirm//<token>`) reaches the same page, so it
  counts as well.
  """

  # Runs of slashes are allowed between segments, because the router ignores
  # empty segments and so serves `/invitations//<token>` as the invitation page.
  @token_path ~r{(/+(?:invitations|users/+reset-password|users/+confirm|users/+settings/+confirm-email)/+)[^/?#\s]+}

  @doc """
  True when `value`, a path or URL, contains a token route's secret segment.

  ## Examples

      iex> token_path?("/invitations/abc")
      true

      iex> token_path?("/invitations//abc")
      true

      iex> token_path?("/users/confirmation-pending")
      false

  """
  @spec token_path?(term()) :: boolean()
  def token_path?(value) when is_binary(value), do: Regex.match?(@token_path, value)
  def token_path?(_value), do: false

  @doc """
  Replaces every token segment in `value`, a path or URL, with `mark`, keeping
  the route prefix, the query string and anything after the segment. Anything
  that is not a string is returned unchanged.

  ## Examples

      iex> redact("https://example.com/invitations/abc?x=1", "[FILTERED]")
      "https://example.com/invitations/[FILTERED]?x=1"

  """
  @spec redact(term(), String.t()) :: term()
  def redact(value, mark) when is_binary(value) and is_binary(mark),
    do: Regex.replace(@token_path, value, fn _match, prefix -> prefix <> mark end)

  def redact(value, _mark), do: value
end
