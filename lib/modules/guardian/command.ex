defmodule Shiina.Guardian.Command do
  use Alchemy.Cogs
  use Timex

  require Logger

  alias Shiina.Guardian.Module
  alias Shiina.Guardian.Server
  alias Shiina.Guardian.Predicate

  alias Shiina.Helpers
  alias Shiina.DiscordLogger

  alias Alchemy.Client
  alias Alchemy.Cache

  Cogs.group "guardian"

  @doc """
  Update Guardian Server to cached configuration
  """
  Cogs.def reload do
    %{channel_id: channel_id} = message
    {:ok, guild_id} = Cache.guild_id(channel_id)
    case Module.update_server(guild_id) do
      {:ok, _}         -> Cogs.say "Guardian configuration reloaded."
      {:error, reason} -> Cogs.say "Could not reload. Reason: #{reason}."
    end
  end

  # @doc """
  # Inspect in detail the result of the most recent ruleset evaluation.
  # """
  # Cogs.def inspect do
  #   %{channel_id: channel_id} = message
  #   {:ok, guild_id} = Cache.guild_id(channel_id)

  #   report    = Server.get_last_report(guild_id)
  #   timestamp = Server.get_last_report_timestamp(guild_id)



  #   # {:ok, ruleset_violations} = Module.test_ruleset(guild_id)

  #   # rule_reports =
  #   #   for {rule_id, violations} <- ruleset_violations, Kernel.length(violations) > 0 do
  #   #     "* `#{rule_id}` has `#{Enum.count(violations)}` violations."
  #   #   end
  #   # if Enum.empty?(rule_reports) do
  #   #   Cogs.say "There were no violations on `#{Enum.count(ruleset_violations)}` evaluated rules."
  #   # else
  #   #   Cogs.say "Evaluated `#{Enum.count(ruleset_violations)}` active rules:\n" <> Enum.join(rule_reports, "\n")
  #   # end
  # end

  @doc """
  Inspect the result of the most recent ruleset evaluation for a specific rule.
  """
  Cogs.def inspect do
    %{channel_id: channel_id} = message
    {:ok, guild_id} = Cache.guild_id(channel_id)

    if Server.exists(guild_id) do
      # Log report
      case Server.get_evaluation(guild_id) do
        nil -> Cogs.say "The ruleset has not yet been evaluated, so there is no report to inspect."
        {timestamp, result} ->
          report = Module.create_report(result)
          {:ok, relative_time} = Timex.from_unix(timestamp) |> Timex.format("{relative}", :relative)
          send_message_safe(channel_id, %{description: report, footer: %Alchemy.Embed.Footer{text: relative_time}})
      end
    else
      Cogs.say "Guardian is not running for the current guild."
    end

    # {:ok, message} = Client.send_message(channel_id, "Evaluating ruleset...")

    # {:ok, ruleset_violations} = Module.test_ruleset(guild_id)
    # {_, violations} = Enum.find(ruleset_violations, fn {id, _} -> id == rule_id end)

    # if Enum.empty?(violations) do
    #   # Client.edit_message(message, "There were no violations on rule `#{rule_id}`.")
    #   Cogs.say "There were no violations on rule `#{rule_id}`."
    # else
    #   targets = Enum.map(violations, fn {%{type: type, entity: entity}, _} ->
    #     case type do
    #       :user -> "<@#{entity.user.id}>"
    #       :role -> "<&#{entity.id}>"
    #       :channel -> "<##{entity.id}>"
    #     end
    #   end)
    #   targets = case Enum.count(targets) do
    #     x when x > 20 -> Enum.slice(targets, 0..19) ++ ["..."]
    #     _             -> targets
    #   end
    #   # Client.edit_message(message, "`#{Enum.count(violations)}` violating entities on rule `#{rule_id}`: " <> Enum.join(targets, ", "))
    #   Cogs.say "`#{Enum.count(violations)}` violating entities on rule `#{rule_id}`: " <> Enum.join(targets, ", ")
    # end
  end

  @doc """
  Evaluate the ruleset.
  """
  Cogs.def evaluate do
    %{channel_id: channel_id} = message
    {:ok, guild_id} = Cache.guild_id(channel_id)

    result = Module.evaluate_ruleset(guild_id)

    if Enum.empty?(result) do
      send_message_safe(channel_id, %{description: "There are no valid rules to evaluate."})
    else
      report = Module.create_report(result)
      send_message_safe(channel_id, %{description: report})
    end
  end

  @doc """
  Try to resolve all violations on the last evaluation.
  """
  Cogs.def resolve do
    %{channel_id: channel_id, author: %Alchemy.User{id: author_id}} = message
    {:ok, guild_id} = Cache.guild_id(channel_id)

    evaluation_result = Module.evaluate_ruleset(guild_id)
    rule_count =
      evaluation_result
      |> Enum.filter(fn {_rule, entities} -> not Enum.empty?(entities) end)
      |> Enum.count()
    entity_count =
      evaluation_result
      |> Enum.flat_map(fn {_rule, entities} -> entities end)
      |> Enum.uniq()
      |> Enum.count()

    embed = %Alchemy.Embed{
      title: "⚡ Are you sure?",
      description: "This operation will attempt to resolve `#{rule_count}` rules affecting a total of `#{entity_count}` entities."
    }
    {:ok, response} = Client.send_message(channel_id, "", embed: embed)

    Client.add_reaction(response, "\u2705")

    Cogs.wait_for(
      :message_reaction_add,
      fn (user_id, _channel_id, _message_id, _emoji = %{"name" => name}) ->
        user_id == author_id and name == "\u2705"
      end,
      fn(_user_id, _channel_id, _message_id, _emoji = %{"name" => "\u2705"}) ->
        Server.await_lock(guild_id)

        results =
          for {rule, entities} <- evaluation_result do
            for entity <- entities do
              Shiina.Guardian.Predicate.resolve_rule(guild_id, rule, Helpers.entity_id(entity))
            end
          end

        Module.evaluate_ruleset(guild_id)

        Server.dispose_lock(guild_id)

        results       = results |> Enum.flat_map(&(&1))
        success_count = results |> Enum.count(&(&1 == :ok))
        failure_count = results |> Enum.count(&(&1 == :error))

        embed = %Alchemy.Embed{
          title: "✅ Operation Completed",
          description: "Latest ruleset violations resolved with `#{success_count}` successes and `#{failure_count}` failures."
        }
        Client.edit_message(response, "", embed: embed)
      end
    )

    # count =
    #   ruleset_violations
    #   |> Enum.map(fn {_, violations} -> Enum.count(violations) end)
    #   |> Enum.sum()
    # Cogs.say "Found #{count} violations, automatically resolving..."

    # for {_, violations} <- ruleset_violations, Kernel.length(violations) > 0 do
    #   for {%{type: type, entity: entity}, resolve_func} <- violations do
    #     case type do
    #       :user    -> Cogs.say "Resolving violation on user <@#{entity.user.id}>"
    #       :role    -> Cogs.say "Resolving violation on role <&#{entity.id}>`"
    #       :channel -> Cogs.say "Resolving violation on channel <##{entity.id}>"
    #     end
    #     resolve_func.()
    #   end
    # end
    # Cogs.say "Done."
  end

  @doc """
  Try to resolve violations on a certain rule_id for the last evaluation.
  """
  Cogs.def resolve(rule_id) do

  end

  Cogs.def predicates do
    %{channel_id: channel_id} = message

    content =
      Predicate.predicates()
      |> Enum.map(
        fn predicate ->
          args = predicate.args |> Enum.map(&("`#{&1}`")) |> Enum.join(", ")
          resolve_support =
            case predicate.resolve_function do
              nil -> "no"
              _   -> "yes"
            end
          "`#{predicate.id}` » #{predicate.description}\nRequired arguments: #{args}\nResolve function: #{resolve_support}"
        end
      )
      |> Enum.join("\n\n")
    send_message_safe(channel_id, embed: %{description: content})
  end

  defp send_message_safe(channel_id, embed = %{description: description}) do
    description
    |> chunk_on_length(2000)
    |> Enum.map(fn x -> %{embed | description: x} end)
    |> Enum.each(fn x -> Client.send_message(channel_id, "", embed: x) end)
  end

  defp chunk_on_length(string, length) do
    enumerable = String.split(string, " ")
    chunked = Enum.chunk_while(
      enumerable,
      [],
      fn (elem, acc) ->
        joined = acc ++ [elem]
        new_length =
          joined
          |> Enum.join(" ")
          |> String.length()
        if new_length > length do
          {:cont, acc, [elem]}
        else
          {:cont, joined}
        end
      end,
      fn acc -> {:cont, acc, []} end
    )
    chunked
    |> Enum.map(fn x -> Enum.join(x, " ") end)
  end

  # Cogs.def test(channel_id) do
  #   Client.edit_channel(channel_id, permission_overwrites: [%Alchemy.OverWrite{id: "594855207368916992", type: "role", allow: 346112, deny: 0}])
  #   Cogs.say "Done"
  # end

end
