defmodule Shiina.CommandConfig do
  use Agent

  use Alchemy.Cogs

  alias Alchemy.Client
  alias Alchemy.Cache

  alias Shiina.Config
  alias Shiina.Helpers

  Cogs.group("config")
  def start_link() do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def with_prefix(user_id, at) do
    [get_prefix(user_id), at]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(".")
  end

  def get_prefix(user_id) do
    state = Agent.get(__MODULE__, &(&1))
    Map.get(state, user_id, nil)
  end

  def set_prefix(user_id, prefix) do
    Agent.update(__MODULE__, fn state -> Map.put(state, user_id, prefix) end)
  end

  def unset_prefix(user_id) do
    Agent.update(__MODULE__, fn state -> Map.delete(state, user_id) end)
  end

  Cogs.def help do
    description =
      """
      `s+config prefix [path]` Resolve all paths given with this path as the prefix. To remove the prefix, don't specify a path.\n
      `s+config get [path \\ ""] [max_depth \\ 3]` Get the value at the given path.\n
      `s+config set <path> list` Create a list at the given path.\n
      `s+config set <path> integer|string|boolean|channel|role|user <value>` Update the value at the given path.\n
      `s+config unset <path>` Unset the value at the given path.\n
      `s+config put <path> integer|string|boolean|channel|role|user <value>` Add a value to the given path, assuming it is a list.\n
      `s+config insert <path> <index> integer|string|boolean|channel|role|user <value>` Insert a value to the given path at a particular index, assuming it is a list.\n
      `s+config pop <path> <index>` Remove the value from the given path at a particular index, assuming it is a list.\n
      `s+config reset` Reset the configuration, restoring it to an empty document.\n
      `s+config recache` Recache the configuration (unnecessary).
      """
    %{channel_id: channel_id} = message
    Client.send_message(channel_id, "", embed: %{description: description})
  end

  Cogs.def prefix do
    unset_prefix(message.author.id)
    Cogs.say "Unset configuration prefix."
  end

  Cogs.def prefix(value) do
    set_prefix(message.author.id, value)
    Cogs.say "Set configuration prefix to `#{value}`."
  end

  Cogs.set_parser(:get, &Helpers.parse_quoted/1)
  Cogs.def get(at \\ nil, max_depth \\ 3, mode \\ "resolve") do
    {:ok, guild_id} = Cache.guild_id(message.channel_id)

    path = with_prefix(message.author.id, at)

    result =
      case Config.get(guild_id, path) do
        nil               -> ":nil"
        x when is_list(x) ->
          case mode do
            "raw"     -> format_list(x)
            "resolve" -> translate_document(guild_id, x) |> format_list()
          end
        x = %{} -> limit_depth(x, max_depth) |> format_document()
        x       -> format_document(x)
      end

    chunk_fun =
      fn elem, acc ->
        result = acc <> "\n" <> elem
        if String.length(result) >= 1900 do
          {:cont, acc, elem}
        else
          {:cont, result}
        end
      end

    chunk_after =
      fn acc ->
        case acc do
          "" -> {:cont, acc}
          _  -> {:cont, acc, acc}
        end
      end



    pages =
      result
      |> String.split("\n")
      |> Enum.chunk_while("", chunk_fun, chunk_after)

    Enum.each(pages, fn page ->
      Cogs.say "```json\n#{page}\n```"
    end)
  end

  Cogs.set_parser(:set, &Helpers.parse_quoted/1)
  Cogs.def set(at, "list") do
    {:ok, guild_id} = Cache.guild_id(message.channel_id)

    path = with_prefix(message.author.id, at)

    value = []
    :ok = Config.set(guild_id, path, value)
    :ok = recache_config(guild_id)
    Cogs.say "Set value at path `#{path}` to `[]`."
  end
  Cogs.def set(at, type, value) do
    {:ok, guild_id} = Cache.guild_id(message.channel_id)

    path = with_prefix(message.author.id, at)

    case parse_value(guild_id, type, value) do
      {:ok, value} ->
        :ok = Config.set(guild_id, path, value)
        :ok = recache_config(guild_id)
        Cogs.say "Set value at path `#{path}` to `#{value}`."
      {:error, reason} ->
        Cogs.say "Error: #{reason}"
    end
  end

  Cogs.def unset(at) do
    {:ok, guild_id} = Cache.guild_id(message.channel_id)

    path = with_prefix(message.author.id, at)

    :ok = Config.unset(guild_id, path)
    :ok = recache_config(guild_id)
    Cogs.say "Unset value at path `#{path}`."
  end

  Cogs.set_parser(:put, &Helpers.parse_quoted/1)
  Cogs.def put(at, type, value) do
    {:ok, guild_id} = Cache.guild_id(message.channel_id)
    {:ok, value} = parse_value(guild_id, type, value)

    path = with_prefix(message.author.id, at)

    list = Config.get(guild_id, path)
    case list do
      x when is_list(x) ->
        list = [value | list]
        Config.set(guild_id, path, list)
        Cogs.say "Added value `#{value}` to list at path `#{path}`."
        :ok = recache_config(guild_id)
      _ ->
        Cogs.say "Error: Value at path `#{path}` is not a list."
    end
  end

  Cogs.set_parser(:insert, &Helpers.parse_quoted/1)
  Cogs.def insert(at, index, type, value) do
    {:ok, guild_id} = Cache.guild_id(message.channel_id)
    {:ok, value} = parse_value(guild_id, type, value)

    path = with_prefix(message.author.id, at)

    list = Config.get(guild_id, path)
    case list do
      x when is_list(x) ->
        list = List.insert_at(list, index, value)
        Config.set(guild_id, path, list)
        :ok = recache_config(guild_id)
        Cogs.say "Added value `#{value}` to list at path `#{path}`."
      _ ->
        Cogs.say "Error: Value at path `#{path}` is not a list."
    end
  end

  Cogs.set_parser(:pop, &Helpers.parse_quoted/1)
  Cogs.def pop(at, index) do
    {:ok, guild_id} = Cache.guild_id(message.channel_id)

    path = with_prefix(message.author.id, at)

    {index, _} = Integer.parse(index)

    list = Config.get(guild_id, path)
    case list do
      x when is_list(x) ->
        {previous, list} = List.pop_at(list, index)
        Config.set(guild_id, path, list)
        :ok = recache_config(guild_id)
        case previous do
          nil -> Cogs.say "Popped nothing; that index doesn't exist."
          _   -> Cogs.say "Popped value `#{previous}` from list at path `#{path}`."
        end
      _ ->
        Cogs.say "Error: Value at path `#{path}` is not a list."
    end
  end

  Cogs.def reset do
    {:ok, guild_id} = Cache.guild_id(message.channel_id)
    {:ok, document} = Config.reset(guild_id)
    :ok = recache_config(guild_id)
    Cogs.say "Reset configuration:\n" <> format_document(document)
  end

  Cogs.def recache do
    %{channel_id: channel_id} = message
    {:ok, guild_id} = Cache.guild_id(channel_id)

    :ok = recache_config(guild_id)
    Cogs.say "Updated cache"
  end

  Cogs.def bin(url) do
    %{channel_id: channel_id} = message
    {:ok, guild_id} = Cache.guild_id(channel_id)

    parsed =
      with {:ok, %{body: body}} <- HTTPoison.get(url)
      do
        {:ok, Poison.decode!(body)}
      else
        err -> err
      end
    Config.reset(guild_id, parsed)
    Cogs.say "Set document to raw content given by URL."
  end

  defp format_document(document) do
    Poison.encode!(document, pretty: true)
  end

  defp format_list(list) when is_list(list) and Kernel.length(list) == 0 do
    "[]"
  end
  defp format_list(list) do
    "[\n" <> format_list(list, "") <> "]"
  end
  defp format_list(remaining, formatted, index \\ 0) do
    if Enum.count(remaining) == 0 do
      formatted
    else
      [head | tail] = remaining
      format_list(tail, "#{formatted}  #{index}: #{head},\n", index + 1)
    end
  end

  defp recache_config(guild_id) do
    config = Config.get(guild_id)
    Config.Cache.update(guild_id, config)
  end

  defp parse_value(guild_id, type, value) do
    case type do
      t when t in ["integer", "int"] ->
        {value, _} = Integer.parse(value)
        {:ok, value}
      t when t in ["string", "str"] ->
        {:ok, value}
      t when t in ["boolean", "bool"] ->
        value = String.to_existing_atom(value)
        case value do
          _ when value in [true, false] ->
            {:ok, value}
          _ ->
            {:error, "Value must be a boolean (true/false)."}
        end
      "channel" ->
        regex  = ~r/<#(\d{18})>/
        [_, id] = Regex.run(regex, value)
        {:ok, id}
      "role" ->
        value = String.downcase(value)
        roles =
          with {:ok, guild} <- Cache.guild(guild_id) do
            guild[:roles]
          else
            _ -> []
          end
        case Enum.find(roles, &(String.downcase(&1.name) == value)) do
          nil  -> {:error, "Role does not exist with that name."}
          role -> {:ok, role.id}
        end
      "user" ->
        regex = ~r/<@!?(\d{18})>/
        [_, id] = Regex.run(regex, value)
        {:ok, id}
    end
  end

  defp translate_document(guild_id, document) when is_map(document) do
    Enum.map(
      document,
      fn {key, value} -> {key, translate_document(guild_id, value)} end
    ) |> Enum.into(%{})
  end

  defp translate_document(guild_id, document) when is_list(document) do
    Enum.map(document, fn value -> translate_document(guild_id, value) end)
  end

  defp translate_document(guild_id, value) when is_bitstring(value) do
    case Integer.parse(value) do
      {_num, ""} ->
        case Shiina.Helpers.guess_entity(guild_id, value) do
          nil    -> value
          entity -> "#{value} (#{Shiina.Helpers.entity_name entity})"
        end
      _ -> value
    end
  end

  defp translate_document(_guild_id, value) do
    value
  end

  defp limit_depth(map, limit, depth \\ 0)

  defp limit_depth(_map, limit, depth) when limit == depth do
    "%{...}"
  end

  defp limit_depth(map, limit, depth) do
    result =
      for {key, value} <- map do
        case value do
          %{} -> {key, limit_depth(value, limit, depth + 1)}
          _   -> {key, value}
        end
      end
      result |> Enum.into(%{})
  end

end
