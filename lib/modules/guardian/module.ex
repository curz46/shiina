defmodule Shiina.Guardian.Module do
  require Logger

  alias Alchemy.Client

  alias Shiina.Helpers
  alias Shiina.DiscordLogger
  alias Shiina.Guardian.Server
  alias Shiina.Guardian.Predicate

  def init() do
    {:ok, guilds} = Client.get_current_guilds()
    for %Alchemy.UserGuild{id: guild_id} <- guilds do
      Alchemy.Cache.load_guild_members(guild_id)
      update_server(guild_id)
    end

    use Shiina.Guardian.Events
    use Shiina.Guardian.Command

    Task.start(&poll/0)
  end

  def update_server(guild_id) do
    case Shiina.Config.Cache.get(guild_id) do
      %{"guardian" => %{"rules" => rules}} ->
        # Only start if not already started, in case this is a re-init
        if not Server.exists(guild_id) do
          Server.start_link(guild_id)
        end

        # Convert %{id => rule} map to [{:id, ...}] rule list
        rules =
          rules
          |> Helpers.atomize_keys()
          |> Enum.map(fn {id, rule} -> Map.put(rule, :id, id) end)

        Server.update_rules(guild_id, rules)
        {:ok, nil}
      :undefined ->
        Logger.debug("Guild #{guild_id} cannot start as configuration is undefined.")
        {:error, :config_undefined}
      _ ->
        Logger.debug("Guild #{guild_id} is improperly configured: guardian.rules is undefined.")
        {:error, :config_malformed}
    end
  end

  # @doc """
  # evaluate_ruleset(guild_id) :: [{rule_id, [entity]}]
  # where [entity] is a list of violating entities that were not automatically and successfully resolved.
  # """
  # @spec evaluate_ruleset(Client.snowflake()) :: [{atom, [struct]}]
  # def _evaluate_ruleset(guild_id) do
  #   Server.await_lock(guild_id)

  #   rules = Server.get_active_rules(guild_id)
  #   rule_violations =
  #     for {rule_id, _} <- rules do
  #       violations = evaluate_rule(guild_id, rule_id, locking: false)
  #       {rule_id, violations}
  #     end

  #   # Log report
  #   rule_violations
  #   |> generate_report()
  #   |> (&DiscordLogger.print_raw(guild_id, &1)).()

  #   Server.set_last_report(guild_id, rule_violations)
  #   Server.set_last_report_timestamp(guild_id, :os.system_time(:millisecond))

  #   Server.dispose_lock(guild_id)

  #   rule_violations
  # end

  @doc """
  evaluate_ruleset(guild_id) :: [{rule, [entity]}]
  Evaluate the ruleset by testing every valid entity for every active rule and returning a list of violating entities for each.
  """
  @spec evaluate_ruleset(Client.snowflake()) :: [{map, [struct]}]
  def evaluate_ruleset(guild_id) do
    evaluation_result =
      Server.get_rules(guild_id)
      |> Enum.map(&{&1, Predicate.bulk_test_rule(guild_id, &1)})
      |> Enum.map(
        fn
          {rule, {:ok, violations}} -> {rule, violations}
          {rule, {:error, reason}} ->
            Shiina.DiscordLogger.print(guild_id, :guardian_bad_rule, {rule, reason})
            nil
        end
      )
      |> Enum.filter(&(!is_nil(&1)))

    Server.update_evaluation(guild_id, evaluation_result)
    evaluation_result
  end

  # @doc """
  # evaluate_rule(guild_id, rule_id, locking: true | false) :: [entity]
  # where [entity] is a list of violating entities that were not automatically and successfully resolved.
  # """
  # @spec _evaluate_rule(Client.snowflake(), atom | bitstring, list) :: [struct]
  # def _evaluate_rule(guild_id, rule_id, options \\ [locking: true])
  # def _evaluate_rule(guild_id, rule_id, _options) when is_bitstring(rule_id) do
  #   evaluate_rule(guild_id, String.to_atom(rule_id))
  # end
  # def _evaluate_rule(guild_id, rule_id, options = [locking: true]) when is_atom(rule_id) do
  #   Server.await_lock(guild_id)

  #   evaluate_rule(guild_id, rule_id, Keyword.put(options, :locking, false))

  #   Server.dispose_lock(guild_id)
  # end
  # def _evaluate_rule(guild_id, rule_id, locking: false) when is_atom(rule_id) do
  #   # Get rule from loaded rules
  #   rule = Server.get_active_rules(guild_id) |> Enum.find()

  #   # Find all violating entities by bulk testing the rule
  #   violations = Predicate.bulk_test_rule(guild_id, rule)

  #   if rule[:auto_resolve] do
  #     results =
  #       for entity <- violations do
  #         Predicate.resolve_rule(guild_id, rule, entity)
  #       end

  #     # Only return violations which weren't supposedly resolved
  #     # This function, therefore, believes that the resolve function will always resolve the violation
  #     # TODO: Maybe change it to double check if the resolve function worked? May be performance intensive for little gain...
  #     results
  #     |> Enum.filter(fn {_entity, result} -> result == :error end)
  #     |> Enum.map(fn {entity, _result} -> entity end)
  #   else
  #     violations
  #   end
  # end

  #############################################

  # def evaluate_rule_safely(guild_id, rule, options \\ []) do
  #   Server.await_lock(guild_id)
  #   evaluate_rule(guild_id, rule, options)
  #   Server.dispose_lock(guild_id)
  # end

  # def evaluate_rule(guild_id, rule, options \\ [])

  # def evaluate_rule(guild_id, rule_id, options) when is_bitstring(rule_id) do
  #   evaluate_rule(guild_id, String.to_atom(rule_id), options)
  # end

  # def evaluate_rule(guild_id, rule_id, options) when is_atom(rule_id) do
  #   rules = Server.get_active_rules(guild_id)
  #   case Enum.find(rules, &(&1.id == rule_id)) do
  #     nil  -> {:error, :unknown_rule}
  #     rule -> evaluate_rule(guild_id, rule, options)
  #   end
  # end

  # def evaluate_rule(guild_id, rule, options) do
  #   resolve_all = Keyword.get(options, :resolve_all, false)

  #   violations = Predicate.bulk_test_rule(guild_id, rule)

  #   if resolve_all or rule[:auto_resolve] do
  #     for entity <- violations do
  #       Predicate.resolve_rule(guild_id, rule, entity)
  #     end
  #   else
  #     violations
  #   end
  # end

  ################################################

  @spec create_report([{atom, [struct]}]) :: bitstring
  def create_report(evaluation_result) do
    reports =
      for {rule, violations} <- evaluation_result do
        violation_count = Enum.count(violations)
        violation_list  = violations |> Enum.map(&Helpers.format_entity/1) |> Enum.join(", ")
        case Enum.empty?(violations) do
          true  -> "✅ `#{rule.id}`"
          false -> "❌ `#{rule.id}` » `#{violation_count}` violations\n#{violation_list}"
        end
      end
    Enum.join(reports, "\n\n")
  end

  def poll_guild(_guild = %Alchemy.UserGuild{id: guild_id}) do
    Server.await_lock(guild_id)

    last_result =
      case Server.get_evaluation(guild_id) do
        nil                  -> nil
        {_timestamp, result} -> result
      end
    result = evaluate_ruleset(guild_id)

    resolvable_violations =
      result
      |> Enum.filter(fn {rule, _entities} -> rule[:auto_resolve] end)
      |> Enum.flat_map(fn {_rule, entities} -> entities end)

    if Enum.empty?(resolvable_violations) do
      last_report = if last_result == nil, do: nil, else: create_report(last_result)
      report      = create_report(result)
      if last_report != report do
        DiscordLogger.print_raw(guild_id, report)
      end

      Server.update_evaluation(guild_id, result)
    else
      # Attempt auto resolve
      for {rule, entities} <- result, rule[:auto_resolve] do
        for entity <- entities do
          Shiina.Guardian.Predicate.resolve_rule(guild_id, rule, Helpers.entity_id(entity))
        end
      end

      # Re-evaluate
      result = evaluate_ruleset(guild_id)
      report = create_report(result)

      DiscordLogger.print_raw(guild_id, report)

      Server.update_evaluation(guild_id, result)
    end

    Server.dispose_lock(guild_id)
  end

  @poll_interval 5 * 60_000 # 5 minutes

  def poll do
    {:ok, guilds} = Client.get_current_guilds()
    guilds
    |> Enum.filter(&(&1 != nil))
    |> Enum.map(&poll_guild/1)

    receive do
    after
      @poll_interval -> poll()
    end
  end

end
