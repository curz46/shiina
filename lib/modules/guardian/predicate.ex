defmodule Shiina.Guardian.Predicate do

  alias Alchemy.Client
  alias Alchemy.Cache
  alias Alchemy.Permissions

  alias Alchemy.User
  alias Alchemy.Guild.GuildMember

  alias Shiina.Helpers
  alias Shiina.DiscordLogger

  @enforce_keys [:id, :entity, :test_function, :resolve_function, :args, :description]
  defstruct [:id, :entity, :test_function, :resolve_function, :args, :description]

  @type entity :: struct

  @spec predicates :: [Guardian.Predicate.t()]
  def predicates do
    [
      %__MODULE__{
        id: :member_has_roles,
        entity: :member,
        test_function: &test_member_has_roles/3,
        resolve_function: &resolve_member_has_roles/3,
        args: ["roles", "members"],
        description: "Test and resolve instances where specified `members` should not have specified `roles`. `members` accepts `!` and `*`."
      },
      %__MODULE__{
        id: :role_is_mentionable,
        entity: :role,
        test_function: &test_role_is_mentionable/3,
        resolve_function: &resolve_role_is_mentionable/3,
        args: ["roles"],
        description: "Test and resolve instances where a specified `roles` are mentionable. `roles` accepts `!` and `*`."
      },
      %__MODULE__{
        id: :role_has_permissions,
        entity: :role,
        test_function: &test_role_has_permissions/3,
        resolve_function: &resolve_role_has_permissions/3,
        args: ["roles", "blacklist"],
        description: "Test and resolve instances where specified `roles` should not have any permission in the `blacklist`. `roles` accepts `!` and `*`. `blacklist` accepts `*`."
      },
      %__MODULE__{
        id: :channel_has_overwrites,
        entity: :channel,
        test_function: &test_channel_has_overwrites/3,
        resolve_function: &resolve_channel_has_overwrites/3,
        args: ["channels", "overwrites"],
        description: "Test and resolve instances where specified `channels` should have specific `overwrites`. `channels` accepts `!` and `*`."
      }
    ]
  end

  @spec bulk_test_rule(Client.snowflake(), %{type: atom}) :: {:ok, [entity]}
  def bulk_test_rule(guild_id, rule = %{type: type}) do
    type = String.to_atom(type)

    predicate =
      predicates()
      |> Enum.find(fn %{id: id} -> type == id end)

    case predicate do
      %__MODULE__{test_function: test, entity: entity} ->
        {:ok, guild} = Cache.guild(guild_id)

        entities =
          case entity do
            :member  -> guild.members
            :role    -> guild.roles
            :channel -> guild.channels
          end

        # Violations are those which do *not* pass the test
        violations = Enum.filter(entities, fn entity -> not test.(guild_id, rule, entity) end)
        {:ok, violations}
      _ -> {:error, :bad_type}
    end
  end

  @spec test_rule(Client.snowflake(), %{type: atom}, entity) :: boolean
  def test_rule(guild_id, rule = %{type: type}, entity) do
    type = String.to_atom(type)

    _predicate = %__MODULE__{test_function: test} =
      predicates()
      |> Enum.find(fn %{id: id} -> type == id end)

    test.(guild_id, rule, entity)
  end

  @spec resolve_rule(Client.snowflake(), %{id: bitstring, type: atom}, Client.snowflake()) :: :ok | :error
  def resolve_rule(guild_id, rule = %{type: type}, entity_id) do
    type = String.to_atom(type)

    _predicate = %__MODULE__{entity: entity_type, resolve_function: resolve} =
      predicates()
      |> Enum.find(fn %{id: id} -> type == id end)

    entity =
      case entity_type do
        :member  -> Helpers.get_member!(guild_id, entity_id)
        :channel -> Helpers.get_channel!(guild_id, entity_id)
        :role    -> Helpers.get_role!(guild_id, entity_id)
      end

    case resolve.(guild_id, rule, entity) do
      :ok ->
        DiscordLogger.print(guild_id, :guardian_resolve_success, {rule.id, entity})
        :ok
      :error ->
        DiscordLogger.print(guild_id, :guardian_resolve_failed, {rule.id, entity})
        :error
    end
  end

  ### :role_whitelist ###
  # Make sure that only the given members have the given roles

  # With a role list

  @spec test_member_has_roles(
          Client.snowflake(),
          %{roles: [Client.snowflake()], members: [Client.snowflake()]},
          entity
        ) :: boolean
  def test_member_has_roles(_guild_id, _rule = %{roles: roles, members: members}, member = %Alchemy.Guild.GuildMember{}) when is_list(roles) do
    whitelisted   = is_targeted(members, member.user.id)
    has_any_roles = Enum.any?(roles, &Enum.member?(member.roles, &1))

    whitelisted or not has_any_roles
  end

  # With a category role

  @spec test_member_has_roles(
          Client.snowflake(),
          %{roles: Client.snowflake(), members: [Client.snowflake()]},
          entity
        ) :: boolean
  def test_member_has_roles(guild_id, _rule = %{roles: category_id, members: members}, member = %Alchemy.Guild.GuildMember{}) when is_bitstring(category_id) do
    roles =
      category_roles(guild_id, category_id)
      |> Enum.map(fn role -> role.id end)

    whitelisted   = is_targeted(members, member.user.id)
    has_any_roles = Enum.any?(roles, &Enum.member?(member.roles, &1))

    whitelisted or not has_any_roles
  end

  @spec resolve_member_has_roles(Client.snowflake(), %{roles: [Client.snowflake()]}, entity) ::
          :error | :ok
  def resolve_member_has_roles(guild_id, _rule = %{roles: roles}, member) when is_list(roles) do
    # member = Helpers.get_member!(guild_id, member_id)
    # Keep a role only if it is not in the role whitelist
    new_roles = Enum.filter(member.roles, fn role -> not Enum.member?(roles, role) end)
    case Client.edit_member(guild_id, member.user.id, roles: new_roles) do
      {:ok, _}    -> :ok
      {:error, _} -> :error
    end
  end

  @spec resolve_member_has_roles(Client.snowflake(), %{roles: Client.snowflake()}, entity) ::
          :error | :ok
  def resolve_member_has_roles(guild_id, _rule = %{roles: category_id}, member) when is_bitstring(category_id) do
    roles =
      category_roles(guild_id, category_id)
      |> Enum.map(fn role -> role.id end)

    # member = Helpers.get_member!(guild_id, member_id)
    # Keep a role only if it is not in the role whitelist
    new_roles = Enum.filter(member.roles, fn role -> not Enum.member?(roles, role) end)
    case Client.edit_member(guild_id, member.user.id, roles: new_roles) do
      {:ok, _}    -> :ok
      {:error, _} -> :error
    end
  end

  ### :role_no_mentionable ###
  # Make sure that the given roles are not mentionable

  def test_role_is_mentionable(_guild_id, _rule = %{roles: roles}, role = %Alchemy.Guild.Role{}) when is_list(roles) do
    not Enum.member?(roles, role.id) or not role.mentionable
  end

  def test_role_is_mentionable(guild_id, _rule = %{roles: category_id}, role = %Alchemy.Guild.Role{}) when is_bitstring(category_id) do
    roles =
      category_roles(guild_id, category_id)
      |> Enum.map(fn role -> role.id end)

    targeted = is_targeted(roles, role.id)
    not targeted or not role.mentionable
  end

  @spec resolve_role_is_mentionable(Client.snowflake(), map, struct) :: :error | :ok
  def resolve_role_is_mentionable(guild_id, _rule, _role = %Alchemy.Guild.Role{id: role_id}) do
    # Client.edit_role(guild_id, role_id, name: role.name, permissions: role.permissions, color: role.color, hoist: role.hoist, mentionable: false)
    case Client.edit_role(guild_id, role_id, [mentionable: false]) do
      {:ok, _}    -> :ok
      {:error, _} -> :error
    end
  end

  ### :role_permission_blacklist ###
  # Make sure that no roles have these permissions

  def test_role_has_permissions(_guild_id, _rule = %{roles: roles, blacklist: blacklist}, %Alchemy.Guild.Role{id: role_id, permissions: bitset}) when is_list(roles) do
    permissions = Alchemy.Permissions.to_list(bitset)

    targeted = is_targeted(roles, role_id)
    no_blacklisted =
      cond do
        Enum.member?(blacklist, "*") ->
          Enum.empty?(permissions)
        true ->
          blacklist = Enum.map(blacklist, &String.to_atom/1)
          Enum.all?(permissions, fn perm -> not Enum.member?(blacklist, perm) end)
      end

    not targeted or no_blacklisted
  end

  def test_role_has_permissions(guild_id, _rule = %{roles: category_id, blacklist: blacklist}, %Alchemy.Guild.Role{id: role_id, permissions: bitset}) when is_bitstring(category_id) do
    roles =
      category_roles(guild_id, category_id)
      |> Enum.map(fn role -> role.id end)

    permissions = Alchemy.Permissions.to_list(bitset)

    targeted = is_targeted(roles, role_id)
    no_blacklisted =
      cond do
        Enum.member?(blacklist, "*") ->
          Enum.empty?(permissions)
        true ->
          blacklist = Enum.map(blacklist, &String.to_atom/1)
          Enum.all?(permissions, fn perm -> not Enum.member?(blacklist, perm) end)
      end

    not targeted or no_blacklisted
  end

  def resolve_role_has_permissions(guild_id, _rule = %{blacklist: blacklist}, %Alchemy.Guild.Role{id: role_id, permissions: bitset}) do
    permissions =
      cond do
        Enum.member?(blacklist, "*") -> []
        true ->
          # Remove blacklisted permissions
          blacklist = Enum.map(blacklist, &String.to_atom/1)
          Alchemy.Permissions.to_list(bitset)
          |> Enum.filter(fn perm -> not Enum.member?(blacklist, perm) end)
      end

    case Client.edit_role(guild_id, role_id, permissions: Alchemy.Permissions.to_bitset(permissions)) do
      {:ok, _}    -> :ok
      {:error, _} -> :error
    end
  end

  ### :channel_has_overwrites
  # Make sure that targeted channels have certain overwrites
  def test_channel_has_overwrites(_guild_id, _rule = %{channels: channels, overwrites: required_overwrites}, _channel = %{id: channel_id, permission_overwrites: channel_overwrites}) do
    required_overwrites = Map.values(required_overwrites)
    cond do
      not is_targeted(channels, channel_id) -> true
      true ->
        Enum.all?(
          required_overwrites,
          fn required_overwrite -> test_channel_overwrites(required_overwrite, channel_overwrites) end
      )
    end
  end

  defp test_channel_overwrites(required_overwrite, channel_overwrites) do
    case required_overwrite do
      %{role: role, permission: permission, value: value} ->
        permission = String.to_atom(permission)
        overwrite =
          Enum.find(
            channel_overwrites,
            fn %Alchemy.OverWrite{type: type, id: id} ->
              type == "role" and id == role
            end
          )
        case overwrite do
          nil -> false
          _   ->
            permission_list =
              case value do
                true  -> Permissions.to_list(overwrite.allow)
                false -> Permissions.to_list(overwrite.deny)
              end

            Enum.member?(permission_list, permission)
        end
      # Just ignore if improperly configured
      _ -> true
    end
  end

  def resolve_channel_has_overwrites(_guild_id, %{overwrites: required_overwrites}, %{id: channel_id, permission_overwrites: channel_overwrites}) do
    required_overwrites = Map.values(required_overwrites)

    overwrite_lists =
      channel_overwrites
      |> Enum.map(fn overwrite = %{allow: allow, deny: deny} -> %{overwrite | allow: Permissions.to_list(allow), deny: Permissions.to_list(deny)} end)

    new_overwrites = Enum.reduce(required_overwrites, overwrite_lists, &apply_overwrite/2)
    new_overwrites =
      new_overwrites
      |> Enum.map(fn overwrite = %{allow: allow, deny: deny} -> %{overwrite | allow: Permissions.to_bitset(allow), deny: Permissions.to_bitset(deny)} end)

    case Client.edit_channel(channel_id, permission_overwrites: new_overwrites) do
      {:ok, channel} -> :ok
      {:error, _}    -> :error
    end
  end

  def apply_overwrite(required_overwrite = %{role: role, permission: permission, value: value}, _overwrite_list = [overwrite | rest]) do
    permission = String.to_atom(permission)
    case overwrite do
      %{type: "role", id: ^role, allow: allow, deny: deny} ->
        allow =
          case value do
            true  -> [permission | allow] |> Enum.uniq()
            false -> List.delete(allow, permission)
          end
        deny =
          case value do
            true  -> List.delete(deny, permission)
            false -> [permission | deny] |> Enum.uniq()
          end
        overwrite = %{overwrite | allow: allow, deny: deny}
        [overwrite | rest]
      _ ->
        overwrites = apply_overwrite(required_overwrite, rest)
        [overwrite | overwrites]
    end
  end

  def apply_overwrite(_required_overwrite = %{role: role, permission: permission, value: value}, _overwrite_list = []) do
    permission = String.to_atom(permission)
    {allow, deny} =
      case value do
        true  -> {[permission], []}
        false -> {[], [permission]}
      end

    [%{type: "role", id: role, allow: allow, deny: deny}]
  end

  ### Helpers ###

  def map_to_overwrite(map, id) do
    allow =
      map
      |> Enum.filter(fn {_k, v} -> v == true end)
      |> Enum.map(fn {k, _v} -> k end)
      |> Permissions.to_bitset()
    deny =
      map
      |> Enum.filter(fn {_k, v} -> v == false end)
      |> Enum.map(fn {k, _v} -> k end)
      |> Permissions.to_bitset()
    %Alchemy.OverWrite{type: "role", id: id, allow: allow, deny: deny}
  end

  def overwrite_to_map(overwrite) do
    allow = Permissions.to_list(overwrite.allow)
    deny  = Permissions.to_list(overwrite.deny)

    permissions  = %{}
    permissions  = Enum.reduce(allow, permissions, fn (perm, acc) -> Map.put(acc, perm, true) end)
    _permissions = Enum.reduce(deny, permissions, fn (perm, acc) -> Map.put(acc, perm, false) end)
  end

  @spec category_roles(binary, binary) :: [any]
  def category_roles(guild_id, category_id) do
    {:ok, guild}    = Cache.guild(guild_id)
    {:ok, category} = Cache.role(guild_id, category_id)

    Helpers.get_roles_in_category(guild, category)
  end

  def is_targeted(entities, entity_id) do
    cond do
      Enum.member?(entities, "!") -> not Enum.member?(entities, entity_id)
      Enum.member?(entities, "*") -> true
      true                        -> Enum.member?(entities, entity_id)
    end
  end

end
