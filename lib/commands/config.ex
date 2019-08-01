defmodule Shiina.CommandConfig do
  use Agent

  use Alchemy.Cogs

  alias Alchemy.Client
  alias Alchemy.Cache

  alias Shiina.Helpers

  Cogs.group("config")
  def format_document(document) do
    document = Poison.encode!(document, pretty: true)
    "```json\n#{document}```"
  end

  def start_link() do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def get_prefix(user_id) do
    state = Agent.get(__MODULE__, &(&1))
    Map.get(state, user_id, "")
  end

  def set_prefix(user_id, prefix) do
    Agent.update(__MODULE__, fn state -> Map.put(state, user_id, prefix) end)
  end

  def unset_prefix(user_id) do
    Agent.update(__MODULE__, fn state -> Map.delete(state, user_id) end)
  end

  Cogs.def prefix do
    unset_prefix(message.author.id)
    Cogs.say "Unset configuration prefix."
  end

  Cogs.def prefix(value) do
    set_prefix(message.author.id, value)
    Cogs.say "Set configuration prefix to `#{value}`."
  end

  Cogs.def get do
    {:ok, guild_id} = Cache.guild_id(message.channel_id)
    prefix = get_prefix(message.author.id)

    case prefix do
      "" ->
        Shiina.Config.get(guild_id)
        |> (&translate_document(guild_id, &1)).()
        |> format_document()
        |> Cogs.say
      _  ->
        Cogs.say "Using prefix `#{prefix}`..."
        do_get(message, prefix)
    end
  end

  Cogs.def get(path) do
    prefix = get_prefix(message.author.id)
    case prefix do
      "" -> do_get(message, path)
      _  ->
        Cogs.say "Using prefix `#{prefix}`..."
        path = if prefix == "", do: path, else: prefix <> "." <> path
        do_get(message, path)
    end
  end

  def do_get(message, path) do
    {:ok, guild_id} = Cache.guild_id(message.channel_id)

    value = Shiina.Config.get(guild_id, path)
    case value do
      nil ->
        Cogs.say "Value: `undefined`"
      v when is_list(v) ->
        Cogs.say "Value: ```json\n" <> path <> " = " <> (translate_document(guild_id, value) |> format_list()) <> "\n```"
      _ ->
        Cogs.say "Value: #{translate_document(guild_id, value) |> format_document}"
      # _ ->
      #   Cogs.say "Value: " <> format_document(value)
    end
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

  Cogs.set_parser(:set, &Helpers.parse_quoted/1)
  Cogs.def set(path, "list") do
    {:ok, guild} = Cache.guild_id(message.channel_id)

    prefix = get_prefix(message.author.id)
    path = if prefix == "", do: path, else: prefix <> "." <> path

    value = []
    :ok = Shiina.Config.set(guild, path, value)
    Cogs.say "Set value at path `#{path}` to `[]`."
  end
  Cogs.def set(path, type, value) do
    {:ok, guild} = Cache.guild_id(message.channel_id)

    prefix = get_prefix(message.author.id)
    path = if prefix == "", do: path, else: prefix <> "." <> path

    case parse_value(guild, type, value) do
      {:ok, value} ->
        :ok = Shiina.Config.set(guild, path, value)
        Cogs.say "Set value at path `#{path}` to `#{value}`."
      {:error, reason} ->
        Cogs.say "Error: #{reason}"
    end
  end

  Cogs.def unset(path) do
    {:ok, guild} = Cache.guild_id(message.channel_id)

    prefix = get_prefix(message.author.id)
    path = if prefix == "", do: path, else: prefix <> "." <> path

    :ok = Shiina.Config.unset(guild, path)
    Cogs.say "Unset value at path `#{path}`."
  end

  Cogs.set_parser(:put, &Helpers.parse_quoted/1)
  Cogs.def put(path, type, value) do
    {:ok, guild} = Cache.guild_id(message.channel_id)
    {:ok, value} = parse_value(guild, type, value)

    prefix = get_prefix(message.author.id)
    path = if prefix == "", do: path, else: prefix <> "." <> path

    list = Shiina.Config.get(guild, path)
    case list do
      x when is_list(x) ->
        list = [value | list]
        Shiina.Config.set(guild, path, list)
        Cogs.say "Added value `#{value}` to list at path `#{path}`."
      _ -> Cogs.say "Error: Value at path `#{path}` is not a list."
    end
  end

  Cogs.set_parser(:insert, &Helpers.parse_quoted/1)
  Cogs.def insert(path, index, type, value) do
    {:ok, guild} = Cache.guild_id(message.channel_id)
    {:ok, value} = parse_value(guild, type, value)

    prefix = get_prefix(message.author.id)
    path = if prefix == "", do: path, else: prefix <> "." <> path

    list = Shiina.Config.get(guild, path)
    case list do
      x when is_list(x) ->
        list = List.insert_at(list, index, value)
        Shiina.Config.set(guild, path, list)
        Cogs.say "Added value `#{value}` to list at path `#{path}`."
      _ -> Cogs.say "Error: Value at path `#{path}` is not a list."
    end
  end

  Cogs.def pop(path, index) do
    {:ok, guild} = Cache.guild_id(message.channel_id)

    prefix = get_prefix(message.author.id)
    path = if prefix == "", do: path, else: prefix <> "." <> path

    {index, _} = Integer.parse(index)

    list = Shiina.Config.get(guild, path)
    case list do
      x when is_list(x) ->
        {previous, list} = List.pop_at(list, index)
        Shiina.Config.set(guild, path, list)
        Cogs.say "Popped value `#{previous}` from list at path `#{path}`."
      _ -> Cogs.say "Error: Value at path `#{path}` is not a list."
    end
  end

  Cogs.def reset do
    {:ok, guild} = Cache.guild_id(message.channel_id)
    {:ok, document} = Shiina.Config.reset guild
    Cogs.say "Reset configuration:\n" <> format_document(document)
  end

  Cogs.def recache do
    %{channel_id: channel_id} = message
    {:ok, guild_id} = Cache.guild_id(channel_id)

    config = Shiina.Config.get(guild_id)
    :ok    = Shiina.Config.Cache.update(guild_id, config)

    Cogs.say "Updated cache"
  end

  defp parse_value(guild, type, value) do
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
        {:ok, roles} = Client.get_roles(guild)
        role = Enum.find(roles, fn r -> String.downcase(r.name) == String.downcase(value) end)
        case role do
          nil -> {:error, "Role does not exist with that name."}
          _   -> {:ok, role.id}
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

end
