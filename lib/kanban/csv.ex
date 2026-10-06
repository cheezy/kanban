defmodule Kanban.CSV do
  @moduledoc """
  Spreadsheet-safe CSV encoding shared by every CSV export in the app
  (`Kanban.Archives` and `Kanban.AuditLog`).

  Every cell is converted with `to_string/1`, neutralised against spreadsheet
  formula injection (OWASP "CSV injection") and then RFC-4180 quoted. Rows are
  joined with CRLF, as RFC 4180 specifies. Keeping the encoder in one place
  means a fix to the neutralisation reaches every export at once.
  """

  # A cell beginning with one of these is evaluated as a formula by Excel,
  # LibreOffice and Google Sheets.
  @formula_triggers [?=, ?+, ?-, ?@, ?\t, ?\r]

  @doc """
  Encodes a list of rows (each a list of cells) into a CSV binary. Rows are
  separated by CRLF; there is no trailing line break.
  """
  @spec encode([[term()]]) :: binary()
  def encode(rows) when is_list(rows), do: Enum.map_join(rows, "\r\n", &encode_row/1)

  @doc """
  Encodes one row (a list of cells) into a CSV line without a line terminator.
  """
  @spec encode_row([term()]) :: binary()
  def encode_row(fields) when is_list(fields), do: Enum.map_join(fields, ",", &encode_field/1)

  @doc """
  Encodes one cell: `nil` becomes an empty cell, anything else goes through
  `to_string/1`, `neutralize_formula/1` and RFC-4180 quoting.
  """
  @spec encode_field(term()) :: binary()
  def encode_field(nil), do: ""

  def encode_field(value) do
    value
    |> to_string()
    |> neutralize_formula()
    |> rfc4180_quote()
  end

  @doc """
  OWASP CSV-injection guard: a cell beginning with a formula trigger
  (`=`, `+`, `-`, `@`, tab or carriage return) is prefixed with a single quote
  so spreadsheet applications treat it as inert text.
  """
  @spec neutralize_formula(binary()) :: binary()
  def neutralize_formula(<<first, _::binary>> = field) when first in @formula_triggers,
    do: "'" <> field

  def neutralize_formula(field) when is_binary(field), do: field

  # RFC-4180: quote fields containing a comma, double-quote, CR, or LF, and
  # escape embedded double-quotes by doubling them.
  defp rfc4180_quote(field) do
    if String.contains?(field, [",", "\"", "\n", "\r"]) do
      ~s("#{String.replace(field, "\"", "\"\"")}")
    else
      field
    end
  end
end
