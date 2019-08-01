defmodule Shiina.Guardian.OldModule do
  @moduledoc """
  Guardian's purpose is to identify rule violations and automatically correct them.

  Roles
  * All roles should be categorised (not underneath uncategorised role group) ; :role_category
  * No custom role should have any permissions                                ; :role_permission
  * No role should have @everyone permission                                  ; :role_permission
  * No core roles should be mentionable                                       ; :role_no_mentionable
  * Only authorised users may be given staff roles                            ; :role_whitelist
  * Only authorised users may be given admin roles                            ; :role_whitelist

  Channels
  * Silence role must have negative SEND_MESSAGES override ; :channel_override
  * @everyone must have negative MANAGE_ROLES override     ; :channel_override
  * No override should have positive MENTION_EVERYONE      ; :channel_override

  Rules are evaluated in two, independent ways:
  * Full evaluations. Fetches required data from the Cache and/or API. Occur periodically
  * Event evaluations. Violations cause full evaluations
  """

  @doc """
  Guardian stores a list of rules so that it does not need to query the database whenever an event occurs.
  Rules are in the following format:
  rule = %{
    id: "my_rule",
    type: :example_rule,
    foo: "bar",
    _active: true
  }
  Here, rule[:foo] is an arbitrary attribute of the rule. A rule type's handler uses certain attributes, if present, as required.
  _active is the key which determines whether or not an event handler should consider a rule. It is set based on configuration
  on startup and can be affected using commands.
  """
  use Agent
  use Task

  use Alchemy.Events

  require Logger

  alias Alchemy.Client
  alias Alchemy.Embed

  @type rule_id :: Client.snowflake()
  @type channel_id :: Client.snowflake()
  @type guild_id :: Client.snowflake()

  @type rule :: %{:id => String.t(), :active => false, :type => String.t()}
  @type evaluation :: %{rule_id => {%{type: :user | :role | :channel, entity: Client.snowflake()}, function()}}
  @type guild_state :: %{loaded_rules: [rule()], last_evaluation: evaluation(), last_evaluation_timestamp: integer(), notify_channel: channel_id}
  @type state :: %{guild_id => guild_state()}

  @spec get() :: state
  def get do
    Agent.get(__MODULE__, &(&1))
  end

  @spec get(guild_id) :: guild_state()
  def get(guild_id) do
     get()
     |> Map.get(guild_id, %{})
  end

  @spec set(state) :: :ok
  def set(value) do
    Agent.update(__MODULE__, fn _ -> value end)
  end

  @spec set(guild_id, guild_state) :: :ok
  def set(guild_id, guild_state) do
    new_state =
      get()
      |> Map.put(guild_id, guild_state)

    set(new_state)
  end

  def get_rules(guild_id) do
    # Agent.get(__MODULE__, &Map.get(&1, guild_id, []))
    get(guild_id)
    |> Map.get(:loaded_rules, [])
  end

  def get_rule(guild_id, rule_id) do
    get_rules(guild_id)
    |> Enum.find(fn rule -> rule.id == rule_id end)
  end

  def update_rules(guild_id, rules) do
    # guild_map =
    #   (get() || %{})
    #   |> Map.put(guild_id, rules)

    new_guild_state =
      get(guild_id)
      |> Map.put(:loaded_rules, rules)
    set(guild_id, new_guild_state)
    # Agent.update(__MODULE__, fn _ -> guild_map end)
  end

  # def toggle_rule(guild_id, rule_id, value) when is_boolean(value) do
  #   rules = get_rules(guild_id)
  #   rules = Enum.map(rules, fn rule ->
  #     if rule.id == rule_id do
  #       %{rule | active: value}
  #     else
  #       rule
  #     end
  #   end)
  #   update_rules(guild_id, rules)
  # end

  def get_active_rules(guild_id) do
    get_rules(guild_id)
    |> Enum.filter(fn rule -> rule.active || false end)
  end

  def get_last_evaluation(guild_id) do
    get(guild_id)
    |> Map.get(:last_evaluation, [])
  end

  def set_last_evaluation(guild_id, violations) do
    # IO.inspect get(guild_id)
    now = :erlang.system_time(:millisecond)

    new_guild_state =
      get(guild_id)
      |> Map.put(:last_evaluation, violations)
      |> Map.put(:last_evaluation_timestamp, now)
    # IO.inspect new_guild_state
    set(guild_id, new_guild_state)
  end

  # def log(guild_id, content) do
    # case get(guild_id) do
    #   %{notify_channel: notify_channel} when notify_channel != nil ->
    #     Client.send_message(notify_channel, content)
    #   _ -> nil
    # end
  # end

  def log(guild_id, callback) do
    case get(guild_id) do
      %{notify_channel: notify_channel} when notify_channel != nil ->
        callback.(notify_channel)
      _ -> nil
    end
  end

  def reload_config(guild_id) do
    case MongoConfig.get(guild_id, "guardian") do
      nil ->
        reason = "Error: `guardian.rules` is not defined in configuration"
        log(guild_id, reason)
        {:error, reason}
      config ->
        rules =
          Map.get(config, "rules", %{})
          |> Enum.map(fn {rule_id, rule} -> Map.merge(rule, %{id: rule_id, active: true}) end)

        notify_channel = Map.get(config, "notify_channel")

        # update_rules(guild_id, rules)
        new_guild_state =
          get(guild_id)
          |> Map.merge(%{loaded_rules: rules, notify_channel: notify_channel})
        set(guild_id, new_guild_state)

        {:ok}
    end
  end

  # def test_rule(_, %{"_id" => name, "type" => type}) do
  #   Logger.warn "The rule '#{name}' of type '#{type}' does not have a handler defined. Skipping..."
  # end

  def test_ruleset(guild_id, filter \\ fn _ -> true end) do
    rules = get_active_rules(guild_id)
    rules = Enum.filter(rules, filter)

    try do
      results = Enum.map(rules, fn rule = %{:id => id, "type" => type} ->
        %{args: expected_args} = Enum.find(Guardian.Rules.rules(), &(&1.type == type))
        args = :maps.filter(fn (key, _) -> key in expected_args end, rule)
        if Map.keys(args) == expected_args do
          result = Guardian.Rules.test_rule_all(guild_id, rule)
          {id, result}
        else
          throw {:error, "Rule '#{id}' does not contain all expected arguments: [#{Enum.join(expected_args, ", ")}]."}
        end
      end)
      {:ok, results}
    catch
      x -> x
    end
  end

  def get_violating_entities(ruleset_violations) do
    ruleset_violations
    |> Enum.map(fn {_, violations} ->
      violations
      |> Enum.map(fn {%{entity: entity}, _} -> entity end)
    end)
  end

  def format_violations(ruleset_violations) do
    reports =
      for {rule_id, violations} <- ruleset_violations do
        emoji = if Enum.empty?(violations), do: "✅", else: "❌"
        "#{emoji} `#{rule_id}`\n> `#{Enum.count(violations)}` violations."
      end
    "``` ```\n**Recent test report**\n" <> "\n" <> Enum.join(reports, "\n\n")
  end

  def evaluate_ruleset(guild_id, no_resolve \\ false) do
    old_ruleset_violations = get_last_evaluation(guild_id)
    old_entities = get_violating_entities(old_ruleset_violations)

    {:ok, new_ruleset_violations} = test_ruleset(guild_id)
    new_entities = get_violating_entities(new_ruleset_violations)

    set_last_evaluation(guild_id, new_ruleset_violations)
    {:ok, new_ruleset_violations}

    if old_entities != new_entities and !Enum.empty?(new_entities) do
      log(guild_id, &Client.send_message(&1, format_violations(new_ruleset_violations)))
    end
    rules = get_active_rules(guild_id)
    resolutions =
      for {rule_id, violations} <- new_ruleset_violations,
          rule = Enum.find(rules, &(&1.id == rule_id)),
          Map.get(rule, "auto_resolve", false) do
        violations
      end
    resolutions = List.flatten(resolutions)

    if !Enum.empty?(resolutions) and !no_resolve do
      starting_embed = %Embed{
        description: "Automatically resolving `#{Enum.count(resolutions)}` violations..."
      }
      log(guild_id, &Client.send_message(&1, "", embed: starting_embed))
      for {_, resolve_func} <- resolutions do
        resolve_func.()
      end
      log(guild_id, &Client.send_message(&1, "", embed: %Embed{description: "Resolutions attempted. Re-running test..."}))
      evaluate_ruleset(guild_id, true)
    else
      {:ok, new_ruleset_violations}
    end
  end

  @poll_interval 10_000

  def poll_guild(%{id: id, name: name}) do
    guild_state = get(id)

    now = :os.system_time(:millisecond)
    if now > Map.get(guild_state, :last_evaluation_timestamp, 0) + @poll_interval do
      Logger.info "Polling guild: " <> name
      {:ok, _} = evaluate_ruleset(id)
    end
  end

  def poll do
    receive do
    after
      @poll_interval ->
        {:ok, guilds} = Client.get_current_guilds()
        guilds
        |> Enum.filter(&(&1 != nil))
        |> Enum.map(&poll_guild/1)
        poll()
    end
  end

  def start_link() do
    Agent.start_link(fn -> %{} end, name: __MODULE__)

    {:ok, guilds} = Client.get_current_guilds()
    Enum.map(guilds, &reload_config(&1.id))

    Task.start_link(&poll/0)
  end

  def trigger_test(guild_id, type, entity) do
    %{test: test, args: expected_args, target: target} = Enum.find(Guardian.Rules.rules(), &(&1.type == type))
    for rule <- get_active_rules(guild_id), rule["type"] == type do
      args =
        rule
        |> Enum.filter(fn {key, _} -> key in expected_args end)
        |> Enum.map(fn {key, _} -> key end)
      if args == expected_args do
        case test.(guild_id, rule, entity) do
          {:pass, _} -> {:ok, :passed}
          {:fail, resolve} ->
            if Map.get(rule, "auto_resolve", false) do
              log(guild_id, &Client.send_message(&1, "", embed: %Embed{description: "Rule `#{rule.id}` failed on #{format_entity(target, entity)}. Automatically resolving..."}))
              resolve.()
              log(guild_id, &Client.send_message(&1, "", embed: %Embed{description: "Succesfully resolved violation for `#{rule.id}` on #{format_entity(target, entity)}."}))
              {:ok, :resolved}
            else
              log(guild_id, &Client.send_message(&1, "", embed: %Embed{description: "Rule `#{rule.id}` failed on #{format_entity(target, entity)}. Automatic resolution is disabled."}))
              {:ok, :failed}
            end
        end
      else
        {:error, "Missing one or more expected args: " <> Enum.join(expected_args, ", ")}
      end
    end
  end

  def format_entity(type, entity) do
    case type do
      :user    -> "<@#{entity.user.id}>"
      :role    -> "<&#{entity.id}>"
      :channel -> "<##{entity.id}>"
    end
  end

  Events.on_member_update(:member_update)
  def member_update(member, guild_id) do
    # test_ruleset(guild_id, &(&1.id == "role_whitelist"))
    # {result, resolve} =
    #   get_active_rules(guild_id)
    #   |> Enum.map(&Guardian.Rules.test_rule_whitelist(guild_id, &1, member))
    # case result do
    #   :pass -> nil
    #   :fail ->

    # end
    trigger_test(guild_id, "role_whitelist", member)
  end

end
