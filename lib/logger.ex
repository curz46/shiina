defmodule Shiina.DiscordLogger do

  alias Alchemy.Client
  alias Alchemy.Embed

  alias Shiina.Helpers

  @doc """
  print(guild_id, format, arguments) :: {:ok, message} | {:error, reason}
  """
  @spec print(Client.snowflake(), atom, tuple) :: {:ok, Alchemy.Message.t()} | {:error, any}
  def print(guild_id, format, arguments) do
    content = do_format(format, arguments)
    print_raw(guild_id, content)
  end

  @spec print_raw(Client.snowflake(), bitstring) :: {:error, any} | {:ok, Alchemy.Message.t()}
  def print_raw(guild_id, content) do
    case get_channel_id(guild_id) do
      :undefined -> {:error, :bad_channel}
      channel_id -> Client.send_message(channel_id, "", embed: %Embed{description: content})
    end
  end

  @spec get_channel_id(Client.snowflake()) :: Client.snowflake() | :undefined
  defp get_channel_id(guild_id) do
    case Shiina.Config.Cache.get(guild_id) do
      %{"log_channel" => channel_id} -> channel_id
      _ -> :undefined
    end
  end

  @spec do_format(atom, tuple) :: bitstring
  defp do_format(format, arguments)

  ### Logger format definitions ###

  # # Occurs on update due to a received event
  # defp do_format(:guardian_entity_violation, {entity, rules}) do
  #   entity = format_entity(entity)
  #   rules  = rules |> Enum.map(fn {id, _} -> id end) |> Enum.join(", ")
  #   {:ok, "Entity #{entity} is in violation of rule(s) `#{rules}`."}
  # end

  # # Occurs on update due to a received event
  # defp do_format(:guardian_violation_result, {entity, num_total, num_failed}) do
  #   entity  = format_entity(entity)
  #   message =
  #     case num_failed do
  #       0 -> "`#{num_total}` resolve functions successfully executed on #{entity}."
  #       _ -> "`#{num_total}` resolve functions executed on #{entity} with `#{num_failed}` failures."
  #     end
  #   {:ok, message}
  # end

  defp do_format(:guardian_resolve_success, {rule_id, entity}) do
    entity = Helpers.format_entity(entity)
    "✅ » Entity #{entity} was in violation of rule `#{rule_id}` and has been automatically resolved."
  end

  defp do_format(:guardian_update_no_resolve, {rule_id, entity}) do
    entity = Helpers.format_entity(entity)
    "❌ » Entity #{entity} is in violation of rule `#{rule_id}` due to a recent change. **Requires manual resolution.**"
  end

  defp do_format(:guardian_resolve_failed, {rule_id, entity}) do
    entity = Helpers.format_entity(entity)
    "❌ » Entity #{entity} is in violation of rule `#{rule_id}` and automatic resolution failed."
  end

  defp do_format(:guardian_rule_violations_resolved, {rule_id, entities, num_failed}) do
    count = Enum.count(entities)
    entities = entities |> Enum.map(&Helpers.format_entity/1) |> Enum.join(", ")
    "Resolve function for rule `#{rule_id}` automatically executed on #{count} violating entities with `#{num_failed}` failures: #{entities}."
  end

  defp do_format(:guardian_bad_rule, {rule, reason}) do
    case reason do
      :bad_type -> "❓ » Rule `#{rule.id}` has unrecognised type `#{rule.type}`."
      _         -> "❌ » Failed to test rule `#{rule.id}` with reason `#{reason}`."
    end
  end

end
