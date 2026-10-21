defmodule Kanban.SCIM.Patch do
  @moduledoc """
  Reads the `Operations` of a SCIM PATCH request (RFC 7644 §3.5.2) into the
  changes Stride acts on (W2247). It only parses; `Kanban.SCIM.Users` and
  `Kanban.SCIM.Groups` decide what the changes mean.

  Identity providers phrase the same change differently, and both forms are
  read:

    * Okta sends a value map with no path:
      `{"op": "replace", "value": {"active": false}}`.
    * Microsoft Entra ID (Azure AD) sends a path, a capitalised op and
      booleans as strings: `{"op": "Replace", "path": "active", "value": "False"}`.

  Operation names and paths are case-insensitive and may carry the core
  schema's URN prefix. User attributes Stride does not store (emails,
  enterprise extension attributes and so on) are ignored, so a provider that
  sends them is not refused.
  """

  alias Kanban.SCIM.Filter

  @type user_changes :: %{
          optional(:active) => boolean(),
          optional(:name) => String.t(),
          optional(:name_parts) => %{optional(atom()) => String.t()},
          optional(:external_id) => String.t() | nil,
          optional(:user_name) => String.t()
        }

  @type group_op ::
          {:add, [String.t()]}
          | {:remove, [String.t()]}
          | :remove_all
          | {:replace, [String.t()]}
          | {:display_name, String.t()}

  @doc """
  Reads a User PATCH body into the attribute changes it asks for. Returns
  `{:error, :invalid_syntax}` for a body without operations or with an
  unknown op, and `{:error, :invalid_value}` for a value of the wrong type.
  """
  @spec user_changes(term()) :: {:ok, user_changes()} | {:error, :invalid_syntax | :invalid_value}
  def user_changes(%{"Operations" => [_ | _] = operations}) do
    operations
    |> Enum.reduce_while({:ok, %{}}, fn operation, {:ok, acc} ->
      case user_operation(operation) do
        {:ok, changes} -> {:cont, {:ok, Map.merge(acc, changes)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> finish_name()
  end

  def user_changes(_body), do: {:error, :invalid_syntax}

  defp user_operation(%{"op" => op} = operation) when is_binary(op) do
    user_operation(String.downcase(op), Map.get(operation, "path"), Map.get(operation, "value"))
  end

  defp user_operation(_operation), do: {:error, :invalid_syntax}

  defp user_operation(op, nil, value) when op in ["add", "replace"], do: user_attributes(value)

  defp user_operation(op, path, value) when op in ["add", "replace"] and is_binary(path),
    do: user_attributes(%{path => value})

  defp user_operation("remove", path, _value) when is_binary(path), do: user_remove(path)
  defp user_operation(_op, _path, _value), do: {:error, :invalid_syntax}

  defp user_remove(path) do
    case Filter.normalize_attribute(path) do
      "externalid" -> {:ok, %{external_id: nil}}
      _ignored -> {:ok, %{}}
    end
  end

  @doc """
  Reads the attributes of a User value map (a PATCH value or a PUT body)
  into changes, ignoring attributes Stride does not store.
  """
  @spec user_attributes(term()) :: {:ok, map()} | {:error, :invalid_value}
  def user_attributes(%{} = attributes) do
    Enum.reduce_while(attributes, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case user_attribute(Filter.normalize_attribute(to_string(key)), value) do
        {:ok, changes} -> {:cont, {:ok, Map.merge(acc, changes)}}
        :error -> {:halt, {:error, :invalid_value}}
      end
    end)
  end

  def user_attributes(_value), do: {:error, :invalid_value}

  defp user_attribute("active", value) do
    case boolean(value) do
      {:ok, active} -> {:ok, %{active: active}}
      :error -> :error
    end
  end

  defp user_attribute("externalid", value) when is_binary(value) or is_nil(value),
    do: {:ok, %{external_id: value}}

  defp user_attribute("username", value) when is_binary(value), do: {:ok, %{user_name: value}}
  defp user_attribute("displayname", value) when is_binary(value), do: {:ok, %{display: value}}

  defp user_attribute("name", %{} = name) do
    Enum.reduce_while(name, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case user_attribute("name." <> String.downcase(to_string(key)), value) do
        {:ok, changes} -> {:cont, {:ok, Map.merge(acc, changes)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp user_attribute("name.formatted", value) when is_binary(value),
    do: {:ok, %{formatted: value}}

  defp user_attribute("name.givenname", value) when is_binary(value), do: {:ok, %{given: value}}
  defp user_attribute("name.familyname", value) when is_binary(value), do: {:ok, %{family: value}}

  # A null clears nothing Stride stores for these, so it is ignored.
  defp user_attribute(attribute, nil) when attribute != "active", do: {:ok, %{}}

  defp user_attribute(attribute, _value)
       when attribute in [
              "externalid",
              "username",
              "displayname",
              "name",
              "name.formatted",
              "name.givenname",
              "name.familyname"
            ],
       do: :error

  defp user_attribute(_ignored, _value), do: {:ok, %{}}

  # The name parts collapse into one :name change: the formatted name wins,
  # then given plus family name, then the display name. The parts that were
  # sent are kept as :name_parts, so a PATCH of one part can be merged with
  # the parts already stored (RFC 7644 §3.5.2.3).
  defp finish_name({:ok, changes}) do
    {parts, changes} = Map.split(changes, [:formatted, :given, :family, :display])
    changes = if map_size(parts) == 0, do: changes, else: Map.put(changes, :name_parts, parts)

    case compose_name(parts) do
      nil -> {:ok, changes}
      name -> {:ok, Map.put(changes, :name, name)}
    end
  end

  defp finish_name(error), do: error

  @doc """
  Composes a display name from `:formatted`, `:given`, `:family` and
  `:display` parts, or returns `nil` when none has text.
  """
  @spec compose_name(map()) :: String.t() | nil
  def compose_name(parts) do
    [trimmed(parts[:formatted]), trimmed(given_and_family(parts)), trimmed(parts[:display])]
    |> Enum.find(&(not is_nil(&1)))
  end

  defp given_and_family(parts) do
    [parts[:given], parts[:family]]
    |> Enum.map(&trimmed/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

  @doc """
  Reads a SCIM boolean, which Microsoft Entra ID sends as the strings
  `"True"` and `"False"`.
  """
  @spec boolean(term()) :: {:ok, boolean()} | :error
  def boolean(value) when is_boolean(value), do: {:ok, value}

  def boolean(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> :error
    end
  end

  def boolean(_value), do: :error

  @doc """
  Reads a Group PATCH body into member and display-name operations. Returns
  `{:error, :invalid_syntax}` for a body without operations or with an
  unknown op or malformed value, and `{:error, :invalid_path}` for a path
  other than `members`, `members[value eq "<id>"]` or `displayName`.
  """
  @spec group_ops(term()) :: {:ok, [group_op()]} | {:error, :invalid_syntax | :invalid_path}
  def group_ops(%{"Operations" => [_ | _] = operations}),
    do: collect_ops(operations, &group_operation/1)

  def group_ops(_body), do: {:error, :invalid_syntax}

  defp group_operation(%{"op" => op} = operation) when is_binary(op) do
    group_operation(String.downcase(op), Map.get(operation, "path"), Map.get(operation, "value"))
  end

  defp group_operation(_operation), do: {:error, :invalid_syntax}

  defp group_operation(op, nil, %{} = value) when op in ["add", "replace"] do
    collect_ops(value, fn {key, attribute} ->
      attribute_name = key |> to_string() |> Filter.normalize_attribute()
      group_value(op, attribute_name, attribute)
    end)
  end

  defp group_operation(op, path, value) when is_binary(path) do
    case Filter.normalize_attribute(path) do
      "members" -> members_operation(op, value)
      "displayname" -> group_value(op, "displayname", value)
      _member_filter -> member_filter_operation(op, path)
    end
  end

  defp group_operation(_op, _path, _value), do: {:error, :invalid_syntax}

  defp group_value(op, "members", value), do: members_operation(op, value)

  defp group_value(op, "displayname", name) when op in ["add", "replace"] and is_binary(name),
    do: {:ok, [{:display_name, name}]}

  defp group_value(_op, attribute, _value) when attribute in ["id", "externalid", "schemas"],
    do: {:ok, []}

  defp group_value(_op, "displayname", _value), do: {:error, :invalid_syntax}
  defp group_value(_op, _attribute, _value), do: {:error, :invalid_path}

  defp members_operation("remove", nil), do: {:ok, [:remove_all]}

  defp members_operation(op, members) when op in ["add", "remove", "replace"] do
    case member_ids(members) do
      {:ok, ids} -> {:ok, [{member_op(op), ids}]}
      :error -> {:error, :invalid_syntax}
    end
  end

  defp members_operation(_op, _members), do: {:error, :invalid_syntax}

  defp member_op("add"), do: :add
  defp member_op("remove"), do: :remove
  defp member_op("replace"), do: :replace

  defp member_filter_operation("remove", path) do
    case Filter.member_path(path) do
      {:ok, id} -> {:ok, [{:remove, [id]}]}
      :error -> {:error, :invalid_path}
    end
  end

  defp member_filter_operation(_op, _path), do: {:error, :invalid_path}

  defp member_ids(members) when is_list(members) do
    ids = Enum.map(members, &member_id/1)
    if Enum.any?(ids, &is_nil/1), do: :error, else: {:ok, ids}
  end

  defp member_ids(%{"value" => _id} = member), do: member_ids([member])
  defp member_ids(_members), do: :error

  defp member_id(%{"value" => id}) when is_binary(id), do: id
  defp member_id(%{"value" => id}) when is_integer(id), do: Integer.to_string(id)
  defp member_id(_invalid), do: nil

  # Concatenates the operations each item yields, stopping at the first error.
  # The chunks are gathered in reverse and joined once: appending each to the
  # accumulator made a body of many operations quadratic (a full-size PATCH
  # held a scheduler for over a minute).
  defp collect_ops(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, &collect_op(&1, &2, fun))
    |> join_chunks()
  end

  defp collect_op(item, {:ok, chunks}, fun) do
    case fun.(item) do
      {:ok, ops} -> {:cont, {:ok, [ops | chunks]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp join_chunks({:ok, chunks}), do: {:ok, chunks |> Enum.reverse() |> Enum.concat()}
  defp join_chunks({:error, _reason} = error), do: error
end
