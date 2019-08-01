defmodule Shiina.Guardian.Events do
  use Alchemy.Events

  alias Alchemy.Client
  alias Alchemy.Guild.GuildMember

  alias Shiina.Helpers
  alias Shiina.DiscordLogger

  alias Shiina.Guardian.Predicate
  alias Shiina.Guardian.Server

  @doc """
  get_violated_rules(guild_id, type, entity) :: [{rule_id, rule}]
  """
  @spec get_violated_rules(Client.snowflake(), atom, struct) :: [{atom, map}]
  def get_violated_rules(guild_id, type, entity) do
    # Find rules of predicate type :role_whitelist
    rules =
      Server.get_rules(guild_id)
      |> Enum.filter(fn rule -> rule.type == type end)

    # List of rules which are violated by this change
    Enum.filter(rules, fn rule ->
      not Predicate.test_rule(guild_id, rule, entity)
    end)
  end

  def handle_update(guild_id, type, entity) do
    if Server.exists(guild_id) do
      violated_rules = get_violated_rules(guild_id, type, entity)
      for rule <- violated_rules do
        if rule[:auto_resolve] do
          Server.await_lock(guild_id)
          Predicate.resolve_rule(guild_id, rule, Helpers.entity_id(entity))
          Server.dispose_lock(guild_id)
        else
          DiscordLogger.print(guild_id, :guardian_update_no_resolve, {rule.id, entity})
        end
      end
    end
  end

  ### Events ###

  Events.on_member_update(:member_update)
  def member_update(member = %GuildMember{}, guild_id) do
    handle_update(guild_id, "member_has_roles", member)
  end

  Alchemy.Events.on_role_update(:on_role_update)
  def on_role_update(_old_role, new_role, guild_id) do
    handle_update(guild_id, "role_is_mentionable", new_role)
    handle_update(guild_id, "role_has_permissions", new_role)
  end

  Alchemy.Events.on_role_create(:on_role_create)
  def on_role_create(new_role, guild_id) do
    handle_update(guild_id, "role_is_mentionable", new_role)
    handle_update(guild_id, "role_has_permissions", new_role)
  end

  Alchemy.Events.on_channel_update(:on_channel_event)
  Alchemy.Events.on_channel_create(:on_channel_event)

  def on_channel_event(channel = %{id: channel_id}) do
    {:ok, guild_id} = Alchemy.Cache.guild_id(channel_id)
    handle_update(guild_id, "channel_has_overwrites", channel)
  end

end
