defmodule Shiina.CommandPurge do
  use Bitwise
  use Alchemy.Cogs

  alias Shiina.Helpers
  alias Alchemy.Client

  Cogs.set_parser(:purge, &Shiina.Helpers.parse_flags/1)

  @doc """
  Bulk deletes messages from the channel of the current message according to mode of operation.
  """
  Cogs.def purge(_, ["help"]) do
    Cogs.say """
    Usage:
    * `s+purge n` deletes from the last message to the nth message inclusively
    * `s+purge -i id1 id2` deletes all messages from id1 to id2 inclusively
    * `s+purge -i -a id` deletes all messages from id to the last message inclusively
    """
  end
  Cogs.def purge(flags, args) do
    known_flags = ["a", "i"]
    flag_values = Map.new(known_flags, fn flag -> {flag, Enum.member?(flags, flag)} end)

    case {flag_values, args} do
      {%{"a" => false, "i" => false}, [amount]} -> delete_amount(message, Integer.parse(amount) |> elem(0))
      {%{"a" => false, "i" => true}, [from_id, to_id]} -> delete_range(message, from_id, to_id)
      {%{"a" => true,  "i" => true}, [from_id]} -> delete_all_from(message, from_id)
      _ -> Cogs.say "Unrecognised purge mode. See `s+purge help`."
    end
  end

  defp delete_amount(message, amount) do
    messages = fetch_messages_before(message.channel_id, amount)
    delete_messages(message.channel_id, messages)
  end

  defp delete_range(message, id_a, id_b) do
    timestamp_a = Helpers.timestamp(id_a)
    timestamp_b = Helpers.timestamp(id_b)

    from = if timestamp_a < timestamp_b, do: id_a, else: id_b
    to   = if timestamp_a < timestamp_b, do: id_b, else: id_a
    messages = fetch_messages_in_range(message.channel_id, from, to)
    delete_messages(message.channel_id, messages)
  end

  defp delete_all_from(message, from_id) do
    messages = fetch_messages_after(message.channel_id, 500, from_id) ++ [message.id]
    delete_messages(message.channel_id, messages)
  end

  defp delete_messages(channel, messages) do
    [candidates | rest] = Enum.chunk_every(messages, 100)
    Client.delete_messages(channel, candidates)

    if Enum.count(rest) != 0 do
      delete_messages(channel, Enum.concat(rest))
    else
      :ok
    end
  end

  defp fetch_messages_in_range(channel_id, from_id, to_id) do
    [from_id] ++ fetch_messages_in_range(channel_id, from_id, to_id, []) ++ [to_id]
  end
  defp fetch_messages_in_range(channel_id, from_id, to_id, previous) do
    {:ok, messages} = Client.get_messages(channel_id, before: to_id, limit: 100)
    messages = Enum.map(messages, fn msg -> msg.id end)

    filtered = Enum.take_while(messages, fn msg -> msg != from_id end)
    if Enum.count(messages) == Enum.count(filtered) do
      fetch_messages_in_range(channel_id, from_id, List.last(messages), previous ++ messages)
    else
      previous ++ filtered
    end
  end

  defp fetch_messages_before(channel, amount) do
    fetch_messages_before(channel, amount, nil, [])
  end
  # defp fetch_messages_before(channel, amount, before) do
  #   fetch_messages_before(channel, amount, before, []) ++ [before]
  # end
  defp fetch_messages_before(_, amount, _, messages) when amount <= 0 do
    messages
  end
  defp fetch_messages_before(channel, amount, before, previous) do
    {:ok, messages} = case before do
      nil -> Client.get_messages(channel, limit: Enum.min([amount, 100]))
      _   -> Client.get_messages(channel, before: before, limit: Enum.min([amount, 100]))
    end
    messages = Enum.map(messages, fn msg -> msg.id end)
    if Enum.count(messages) == 100 do
      fetch_messages_before(channel, amount - 100, List.last(messages), previous ++ messages)
    else
      previous ++ messages
    end
  end

  defp fetch_messages_after(channel, amount, from) do
    [from] ++ fetch_messages_after(channel, amount, from, [])
  end
  defp fetch_messages_after(_, amount, _, messages) when amount <= 0 do
    messages
  end
  defp fetch_messages_after(channel, amount, from, previous) do
    IO.puts "fetch_messages_after: #{amount}, #{from}, #{Enum.count(previous)}"
    {:ok, messages} = Client.get_messages(channel, after: from, limit: Enum.min([amount, 100]))
    messages = Enum.map(messages, fn msg -> msg.id end)
    if Enum.count(messages) == 100 do
      fetch_messages_after(channel, amount - 100, List.first(messages), previous ++ messages)
    else
      previous ++ messages
    end
  end
end
