defmodule KanbanWeb.AuditLogActionsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.AuditLogActions

  defp catalog_audit_actions do
    for %{domain: :audit, name: [:kanban, :audit, action]} <- Kanban.Telemetry.Catalog.events() do
      Atom.to_string(action)
    end
  end

  describe "action_label/1" do
    test "labels every audit action declared in the telemetry catalog" do
      actions = catalog_audit_actions()

      assert "user_deleted" in actions
      assert "user_delete_refused" in actions

      unlabelled = Enum.filter(actions, &(AuditLogActions.action_label(&1) == &1))
      assert unlabelled == []
    end

    test "labels the account deletion actions" do
      assert AuditLogActions.action_label("user_deleted") == "Account deleted"
      assert AuditLogActions.action_label("user_delete_refused") == "Account deletion refused"
    end

    test "passes an unknown action through unchanged" do
      assert AuditLogActions.action_label("retired_action") == "retired_action"
    end

    test "translates the label for the current locale" do
      Gettext.with_locale(KanbanWeb.Gettext, "de", fn ->
        assert AuditLogActions.action_label("user_deleted") == "Konto gelöscht"
        assert AuditLogActions.action_label("user_delete_refused") == "Kontolöschung abgelehnt"
      end)

      Gettext.with_locale(KanbanWeb.Gettext, "ja", fn ->
        assert AuditLogActions.action_label("user_deleted") == "アカウントの削除"
      end)
    end

    test "every label is translated in every shipped locale" do
      for locale <- ~w(de es fr ja pt zh), action <- catalog_audit_actions() do
        english = AuditLogActions.action_label(action)

        translated =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            AuditLogActions.action_label(action)
          end)

        assert translated != english, "#{action} has no #{locale} translation"
      end
    end
  end

  describe "action_options/1" do
    test "pairs each label with its raw action, keeping the order" do
      assert AuditLogActions.action_options(["user_deleted", "retired_action"]) == [
               {"Account deleted", "user_deleted"},
               {"retired_action", "retired_action"}
             ]
    end

    test "returns no options for no actions" do
      assert AuditLogActions.action_options([]) == []
    end
  end
end
