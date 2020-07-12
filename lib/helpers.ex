defmodule Shiina.Helpers do
  use Bitwise

  alias Alchemy.Client
  alias Alchemy.Cache

  def parse_flags(rest) do
    parts = String.split(rest, " ")

    {raw_flags, args} = Enum.split_with(parts, fn word -> String.starts_with?(word, ["-", "--"]) end)
    flags = Enum.map(raw_flags, fn raw -> String.replace(raw, ~r/--?/, "") end)

    [flags, args]
  end

  def parse_quoted(rest) do
    parse_quoted(rest, [])
  end
  defp parse_quoted(binary, parsed) when binary == "" do
    parsed
  end
  defp parse_quoted(binary, parsed) do
    [word, left] =
      case String.starts_with?(binary, "\"") do
        true  ->
          case String.split(binary, "\"", parts: 3) do
            [_, word]       -> [word, ""]
            [_, word, left] -> [word, left]
          end
        false ->
          case String.split(binary, " ", parts: 2) do
            [word]       -> [word, ""]
            [word, left] -> [word, left]
          end
      end
    parse_quoted(left, parsed ++ [word])
  end

  def timestamp(snowflake) when is_binary(snowflake) do
    {snowflake, _} = Integer.parse(snowflake)
    timestamp(snowflake)
  end
  def timestamp(snowflake) when is_integer(snowflake) do
    (snowflake >>> 22) + 1420070400000
  end

  def put_in_safely(map, keys, value) do
    Kernel.put_in(map, Enum.map(keys, &Access.key(&1, %{})), value)
  end

  def get_all_members(guild) do
    get_all_members(guild, [], nil)
  end
  def get_all_members(guild = %{id: guild_id, member_count: member_count}, previous, after_snowflake) do
    options =
      case after_snowflake do
        nil       -> [limit: 1000]
        snowflake -> [after: snowflake, limit: 1000]
      end
    case Alchemy.Client.get_member_list(guild_id, options) do
      {:ok, members} ->
        case Enum.count(members) do
          x when x == member_count or x < 1000 -> {:ok, previous ++ members}
          _ ->
            highest_member = Enum.max_by(members, &(&1.user.id))
            get_all_members(guild, members ++ previous, highest_member.user.id)
        end
      {:error, reason} -> {:error, reason}
    end

  end
  def get_all_members(guild_id, previous, after_snowflake) when is_binary(guild_id) do
    {:ok, guild} = Alchemy.Client.get_guild(guild_id)
    get_all_members(guild, previous, after_snowflake)
  end

  @spec entity_id(map) :: Alchemy.Client.snowflake()
  def entity_id(entity) do
    case entity do
      %Alchemy.Guild.GuildMember{} -> entity.user.id
      entity                       -> entity.id
    end
  end

  @doc """
  Convert map string keys to :atom keys
  """
  def atomize_keys(nil), do: nil

  # Structs don't do enumerable and anyway the keys are already
  # atoms
  def atomize_keys(struct = %{__struct__: _}) do
    struct
  end

  def atomize_keys(map = %{}) do
    map
    |> Enum.map(fn {k, v} -> {String.to_atom(k), atomize_keys(v)} end)
    |> Enum.into(%{})
  end

  # Walk the list and atomize the keys of
  # of any map members
  def atomize_keys([head | rest]) do
    [atomize_keys(head) | atomize_keys(rest)]
  end

  def atomize_keys(not_a_map) do
    not_a_map
  end

  def format_entity(entity) do
    case entity do
      %Alchemy.User{id: id} ->
        "<@#{id}>"
      %Alchemy.Guild.GuildMember{user: %Alchemy.User{id: id}} ->
        "<@#{id}>"
      %Alchemy.Guild.Role{id: id} ->
        "<@&#{id}>"
      %Alchemy.Channel.TextChannel{id: id} ->
        "<##{id}>"
      %Alchemy.Channel.VoiceChannel{id: id} ->
        "<##{id}>"
      %Alchemy.Channel.ChannelCategory{id: id} ->
        "<##{id}>"
      _ ->
        "???"
    end
  end

  def entity_name(entity) do
    case entity do
      %Alchemy.Guild.GuildMember{user: %Alchemy.User{username: username}} -> username
      _ -> Map.get(entity, :name, "???")
    end
  end

  @spec get_member(Client.snowflake(), Client.snowflake()) :: {:error, any} | {:ok, Alchemy.Guild.GuildMember.t()}
  def get_member(guild_id, member_id) do
    case Alchemy.Cache.member(guild_id, member_id) do
      {:ok, member} -> {:ok, member}
      {:error, _}   -> Alchemy.Client.get_member(guild_id, member_id)
    end
  end

  @spec get_member!(Client.snowflake(), Client.snowflake()) :: Alchemy.Guild.GuildMember.t()
  def get_member!(guild_id, member_id) do
    case get_member(guild_id, member_id) do
      {:ok, member}    -> member
      {:error, reason} -> raise reason
    end
  end

  def get_channel(guild_id, channel_id) do
    case Alchemy.Cache.channel(guild_id, channel_id) do
      {:ok, channel} -> {:ok, channel}
      {:error, _}    -> Alchemy.Client.get_channel(channel_id)
    end
  end

  def get_channel!(guild_id, channel_id) do
    case get_channel(guild_id, channel_id) do
      {:ok, channel}   -> channel
      {:error, reason} -> raise reason
    end
  end

  def get_role(guild_id, role_id) do
    case Alchemy.Cache.role(guild_id, role_id) do
      {:ok, role} ->
        {:ok, role}
      {:error, _} ->
        case Alchemy.Client.get_roles(guild_id) do
          {:ok, roles} ->
            case Enum.find(roles, &(&1.id == role_id)) do
              nil  -> {:error, :not_found}
              role -> {:ok, role}
            end
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def get_role!(guild_id, role_id) do
    case get_role(guild_id, role_id) do
      {:ok, role}      -> role
      {:error, reason} -> raise reason
    end
  end

  @spec guess_entity(Client.snowflake(), Client.snowflake()) :: struct | nil
  def guess_entity(guild_id, entity_id) do
    lookups = [
      &Alchemy.Cache.role/2,
      &Alchemy.Cache.member/2,
      &Alchemy.Cache.channel/2
    ]
    results = Enum.map(lookups, fn lookup ->
      case lookup.(guild_id, entity_id) do
        {:ok, entity} -> entity
        {:error, _}   -> :unknown
      end
    end)
    Enum.find(results, fn result -> result != :unknown end)
  end

  @category_prefix "+"

  @spec is_category_role(Alchemy.Guild.snowflake(), Alchemy.Guild.snowflake()) :: boolean()
  def is_category_role(guild_id, role_id) do
    role = Alchemy.Cache.role(guild_id, role_id)
    String.starts_with?(role.name, @category_prefix)
  end

  @spec find_category(Alchemy.Guild.t(), Alchemy.Guild.Role.t()) :: Alchemy.Guild.Role.t() | :undefined
  def find_category(guild, role) do
      guild.roles
      |> Enum.filter(fn candidate -> String.starts_with?(candidate.name, @category_prefix) end)
      |> Enum.filter(fn category -> category.position > role.position end)
      |> Enum.min_by(fn category -> category.position end, fn -> :undefined end)
  end

  @spec get_roles_in_category(Alchemy.Guild.t(), Alchemy.Guild.Role.t()) :: [Alchemy.Guild.Role.t()]
  def get_roles_in_category(guild, category) do
    guild.roles
    |> Enum.filter(fn role -> role.position < category.position end)
    |> Enum.sort_by(fn role -> role.position end)
    |> Enum.reverse()
    |> Enum.take_while(fn role -> not String.starts_with?(role.name, @category_prefix) end)
  end

  @spec get_highest_role(Alchemy.Guild.t(), Alchemy.Guild.GuildMember.t()) :: Alchemy.Guild.Role.t() | :undefined
  def get_highest_role(guild, _member = %Alchemy.Guild.GuildMember{roles: roles}) do
    sorted =
      roles
      |> Enum.map(fn id -> Enum.find(guild.roles, &(&1.id == id)) end)
      |> Enum.sort_by(fn role -> role.position end)
      |> Enum.reverse()
    case sorted do
      [highest | _] -> highest
      []            -> :undefined
    end
  end

end
