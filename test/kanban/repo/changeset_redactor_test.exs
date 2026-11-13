defmodule Kanban.Repo.ChangesetRedactorTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Kanban.Accounts.UserTotp
  alias Kanban.Encryption.EncryptedBinary
  alias Kanban.Encryption.TolerantEncryptedBinary
  alias Kanban.Integrations.EncryptedString
  alias Kanban.Repo.ChangesetRedactor

  doctest Kanban.Repo.ChangesetRedactor

  @mark "**redacted**"

  defmodule Child do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    embedded_schema do
      field :secret, Kanban.Encryption.EncryptedBinary
      field :label, :string
    end

    def changeset(child, params), do: cast(child, params, [:secret, :label])
  end

  defmodule StringCipher do
    @moduledoc false
    use Ecto.Type
    def type, do: :string
    def cast(value), do: {:ok, value}
    def load(value), do: {:ok, String.reverse(value)}
    def dump(value) when is_binary(value), do: {:ok, String.reverse(value)}
    def dump(_value), do: :error
  end

  defmodule ParameterizedCipher do
    @moduledoc false
    use Ecto.ParameterizedType
    def init(opts), do: Map.new(opts)
    def type(_params), do: :binary
    def cast(value, _params), do: {:ok, value}
    def load(value, _loader, _params), do: {:ok, value}
    def dump(nil, _dumper, _params), do: {:ok, nil}
    def dump(value, _dumper, _params) when is_binary(value), do: {:ok, "enc:" <> value}
    def dump(_value, _dumper, _params), do: :error
  end

  defmodule Parent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    embedded_schema do
      field :name, :string
      field :password, :string, virtual: true, redact: true
      field :kind, Ecto.Enum, values: [:a, :b]
      field :wrapped, ParameterizedCipher
      embeds_one :child, Child
      embeds_many :children, Child
    end

    def changeset(parent, params) do
      parent
      |> cast(params, [:name, :password])
      |> cast_embed(:child)
      |> cast_embed(:children)
    end
  end

  describe "encrypting_type?/1" do
    test "is true for every encrypting type in the app" do
      for type <- [EncryptedBinary, TolerantEncryptedBinary, EncryptedString] do
        assert ChangesetRedactor.encrypting_type?(type), inspect(type)
      end
    end

    test "is true inside arrays and maps, for :string ciphers and for parameterized ciphers" do
      for type <- [
            {:array, EncryptedBinary},
            {:map, EncryptedString},
            {:in, TolerantEncryptedBinary},
            StringCipher,
            Parent.__schema__(:type, :wrapped)
          ] do
        assert ChangesetRedactor.encrypting_type?(type), inspect(type)
      end
    end

    test "is false for built-in and pass-through types" do
      for type <- [
            :string,
            :binary,
            :integer,
            :map,
            Ecto.UUID,
            {:array, :string},
            Parent.__schema__(:type, :kind),
            Parent.__changeset__()[:child]
          ] do
        refute ChangesetRedactor.encrypting_type?(type), inspect(type)
      end
    end

    # Independent of the predicate it checks: every custom Ecto type in the app,
    # found by its behaviour, must be classified as encrypting, or be added
    # here as a known pass-through type with a reason.
    test "classifies every custom Ecto type in the app" do
      {:ok, modules} = :application.get_key(:kanban, :modules)
      known_pass_through = []

      custom_types =
        for module <- modules,
            Code.ensure_loaded?(module),
            behaviours = module.module_info(:attributes) |> Keyword.get_values(:behaviour),
            behaviours
            |> List.flatten()
            |> Enum.any?(&(&1 in [Ecto.Type, Ecto.ParameterizedType])),
            do: module

      assert EncryptedBinary in custom_types

      for module <- custom_types -- known_pass_through do
        assert ChangesetRedactor.encrypting_type?(module), "#{inspect(module)} is unclassified"
      end
    end
  end

  describe "sensitive_fields/2" do
    test "finds encrypted fields by type and redact: true fields by declaration" do
      parent = Parent.__changeset__()

      assert ChangesetRedactor.sensitive_fields(%Parent{}, parent) ==
               MapSet.new([:password, :wrapped])

      assert ChangesetRedactor.sensitive_fields(%Child{}, Child.__changeset__()) ==
               MapSet.new([:secret])
    end

    test "works for a schemaless changeset" do
      types = %{token: EncryptedBinary, name: :string}
      assert ChangesetRedactor.sensitive_fields(%{}, types) == MapSet.new([:token])
    end
  end

  describe "redact/1" do
    test "redacts changes and string-keyed params" do
      changeset = cast(%UserTotp{}, %{"secret" => "s3cret", "user_id" => 1}, [:secret, :user_id])
      redacted = ChangesetRedactor.redact(changeset)

      assert redacted.changes.secret == @mark
      assert redacted.changes.user_id == 1
      assert redacted.params == %{"secret" => @mark, "user_id" => 1}
    end

    test "redacts atom-keyed params" do
      changeset = %{change(%UserTotp{}, secret: "s3cret") | params: %{secret: "s3cret"}}
      assert ChangesetRedactor.redact(changeset).params == %{secret: @mark}
    end

    test "redacts nested embeds and their params in every shape" do
      params = %{
        "name" => "visible",
        "password" => "pw",
        "child" => %{"secret" => "one", "label" => "a"},
        "children" => %{"0" => %{"secret" => "two"}, "1" => %{"secret" => nil}}
      }

      redacted = %Parent{} |> Parent.changeset(params) |> ChangesetRedactor.redact()

      assert redacted.changes.name == "visible"
      assert redacted.changes.password == @mark
      assert redacted.changes.child.changes == %{secret: @mark, label: "a"}
      assert [first, second] = redacted.changes.children
      assert first.changes == %{secret: @mark}
      assert second.changes == %{}

      assert redacted.params["name"] == "visible"
      assert redacted.params["password"] == @mark
      assert redacted.params["child"] == %{"secret" => @mark, "label" => "a"}

      assert redacted.params["children"] == %{
               "0" => %{"secret" => @mark},
               "1" => %{"secret" => nil}
             }

      keyed_params = %{"children" => %{"new" => %{"secret" => "four"}, a: %{"secret" => "five"}}}
      keyed = %Parent{} |> Parent.changeset(keyed_params) |> ChangesetRedactor.redact()

      assert keyed.params["children"] == %{
               "new" => %{"secret" => @mark},
               a: %{"secret" => @mark}
             }

      list_params = %{"children" => [%{"secret" => "three"}]}
      listed = %Parent{} |> Parent.changeset(list_params) |> ChangesetRedactor.redact()
      assert listed.params["children"] == [%{"secret" => @mark}]
    end

    test "returns a changeset with no sensitive values unchanged" do
      changeset = Parent.changeset(%Parent{}, %{"name" => "plain"})
      assert ChangesetRedactor.redact(changeset) == changeset
    end

    test "returns anything that is not a changeset unchanged" do
      assert ChangesetRedactor.redact(%{secret: "x"}) == %{secret: "x"}
      assert ChangesetRedactor.redact(nil) == nil
    end
  end

  describe "redact_error/1" do
    test "redacts an invalid changeset error's changeset and keeps its action" do
      changeset = change(%UserTotp{}, secret: "s3cret")
      error = %Ecto.InvalidChangesetError{action: :insert, changeset: changeset}
      redacted = ChangesetRedactor.redact_error(error)

      assert redacted.action == :insert
      assert redacted.changeset.changes.secret == @mark
      refute Exception.message(redacted) =~ "s3cret"
    end

    test "returns any other exception unchanged" do
      error = %ArgumentError{message: "s3cret"}
      assert ChangesetRedactor.redact_error(error) == error
    end
  end
end
