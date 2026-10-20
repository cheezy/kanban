defmodule Kanban.ApiTokens.ApiTokenTest do
  @moduledoc """
  The varchar(255) length checks on both token changesets (G442 exploratory
  finding 2): an oversized name, model, version or capability is a changeset
  error, never a Postgrex 22001.
  """
  use Kanban.DataCase, async: true

  alias Kanban.ApiTokens.ApiToken

  @valid %{name: "Agent", user_id: 1, board_id: 1}
  @valid_workspace %{name: "Agent", user_id: 1, workspace_id: 1}

  # "e" + a combining acute accent: one grapheme, two code points. Postgres
  # counts code points, so 128 of these (256 code points) overflow the column
  # although they are only 128 characters to the eye.
  @combining "é"

  describe "changeset/2 and workspace_changeset/2" do
    for {label, fun, base} <- [
          {"board", :changeset, @valid},
          {"workspace", :workspace_changeset, @valid_workspace}
        ] do
      @fun fun
      @base base

      test "#{label}: accepts 255-character text fields" do
        attrs =
          Map.merge(@base, %{
            name: text(255),
            agent_model: text(255),
            agent_version: text(255),
            agent_capabilities: [text(255)]
          })

        assert apply(ApiToken, @fun, [%ApiToken{}, attrs]).valid?
      end

      test "#{label}: rejects a 256-character name, model and version" do
        for field <- [:name, :agent_model, :agent_version] do
          changeset = apply(ApiToken, @fun, [%ApiToken{}, Map.put(@base, field, text(256))])

          refute changeset.valid?, "#{field}"
          assert "should be at most 255 character(s)" in errors_on(changeset)[field]
        end
      end

      test "#{label}: counts code points, as Postgres does" do
        name = String.duplicate(@combining, 128)
        assert String.length(name) == 128

        changeset = apply(ApiToken, @fun, [%ApiToken{}, Map.put(@base, :name, name)])
        assert "should be at most 255 character(s)" in errors_on(changeset).name
      end

      test "#{label}: rejects a capability longer than 255 characters" do
        for capability <- [text(256), String.duplicate(@combining, 128)] do
          attrs = Map.put(@base, :agent_capabilities, ["testing", capability])
          changeset = apply(ApiToken, @fun, [%ApiToken{}, attrs])

          assert errors_on(changeset).agent_capabilities == [
                   "each capability must be at most 255 characters"
                 ]
        end
      end

      test "#{label}: leaves agent_purpose, a text column, uncapped" do
        attrs = Map.put(@base, :agent_purpose, text(5_000))
        assert apply(ApiToken, @fun, [%ApiToken{}, attrs]).valid?
      end
    end
  end

  describe "validate_column_lengths/1" do
    test "passes a changeset without the capped fields" do
      assert %ApiToken{}
             |> Ecto.Changeset.change()
             |> ApiToken.validate_column_lengths()
             |> Map.fetch!(:valid?)
    end

    test "ignores a non-string capability, which cast already refuses" do
      changeset =
        %ApiToken{}
        |> Ecto.Changeset.change(agent_capabilities: [nil, "ok"])
        |> ApiToken.validate_column_lengths()

      assert changeset.valid?
    end
  end

  test "max_text_length/0 is the column size the forms use as maxlength" do
    assert ApiToken.max_text_length() == 255
  end

  test "the capability message is translated" do
    msg = {"each capability must be at most 255 characters", [validation: :length, kind: :max]}

    for {locale, expected} <- [
          {"en", "each capability must be at most 255 characters"},
          {"de", "jede Fähigkeit darf höchstens 255 Zeichen lang sein"},
          {"es", "cada capacidad debe tener como máximo 255 caracteres"},
          {"fr", "chaque capacité doit comporter au plus 255 caractères"},
          {"ja", "各ケイパビリティは255文字以内にしてください"},
          {"pt", "cada capacidade deve ter no máximo 255 caracteres"},
          {"zh", "每项能力最多 255 个字符"}
        ] do
      assert Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
               KanbanWeb.CoreComponents.translate_error(msg)
             end) == expected
    end
  end

  defp text(length), do: String.duplicate("a", length)
end
