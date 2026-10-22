defmodule KanbanWeb.Sentences do
  @moduledoc """
  Joins separately translated sentences into one paragraph.

  Chinese and Japanese end a sentence in full-width punctuation and write the
  next one straight after it; every other locale the app supports separates
  sentences with one space. Both functions read the calling process's
  `KanbanWeb.Gettext` locale, so call them where the sentences are rendered.
  """

  @unspaced ~w(ja zh)

  @doc "Joins `sentences` with the current locale's separator."
  @spec join([String.t()]) :: String.t()
  def join(sentences) when is_list(sentences), do: Enum.join(sentences, separator())

  @doc "The text between two sentences in the current locale: empty or one space."
  @spec separator() :: String.t()
  def separator do
    if Gettext.get_locale(KanbanWeb.Gettext) in @unspaced, do: "", else: " "
  end
end
