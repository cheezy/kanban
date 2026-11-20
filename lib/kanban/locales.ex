defmodule Kanban.Locales do
  @moduledoc """
  Maps a stored language tag to the Gettext locale Stride renders in (D4).

  A device reports any well-formed language tag (`"de-AT"`, `"pt-BR"`,
  `"zh-Hant-TW"`, `"ko"`), and Stride is translated into the locales
  `KanbanWeb.Gettext` knows (`en`, `de`, `fr`, `es`, `pt`, `ja`, `zh`).
  `resolve/1` picks, case-insensitively and with `-` or `_` separators:

    1. the known locale the whole tag names (`"DE"` is `"de"`);
    2. else the known locale its base language names (`"de-AT"` is `"de"`,
       `"pt_BR"` is `"pt"`, `"zh-Hant-TW"` is `"zh"`);
    3. else `"en"` (`"ko"`, a blank or missing tag).

  Every place a stored device or user locale picks a Gettext locale goes
  through it: push payloads (`Kanban.Push.PayloadBuilder.locale/1`), the
  announcement and audit-stream emails
  (`Kanban.Notifications.AnnouncementWorker.locale_for/1`), and the
  notification and weekly digest emails (`Kanban.Notifications.EmailWorker`,
  `Kanban.Notifications.DigestWorker`).
  """

  @default "en"

  # Normalised spelling => the known locale's own spelling, so a future
  # region locale such as "pt_BR" still matches "pt-br" exactly.
  @known KanbanWeb.Gettext
         |> Gettext.known_locales()
         |> Map.new(&{&1 |> String.replace("_", "-") |> String.downcase(), &1})

  @doc "The locale used when a tag names no translated language: `\"en\"`."
  @spec default() :: String.t()
  def default, do: @default

  @doc """
  The Gettext locale for the language tag `tag`: its exact known locale,
  else its base language's, else `"en"`. Anything but a string is `"en"`.
  """
  @spec resolve(term()) :: String.t()
  def resolve(tag) when is_binary(tag) do
    normalized = tag |> String.trim() |> String.replace("_", "-") |> String.downcase()
    base = normalized |> String.split("-", parts: 2) |> hd()

    Map.get(@known, normalized) || Map.get(@known, base) || @default
  end

  def resolve(_tag), do: @default
end
