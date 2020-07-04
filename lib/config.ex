defmodule Shiina.Config do

  @type value :: %{raw: any, type: atom}

  defmodule Cache do
    use Agent
    def start_link() do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    @spec get(bitstring) :: map | :undefined
    def get(guild_id) do
      Agent.get(__MODULE__, fn x -> x[guild_id] || :undefined end)
    end

    require Logger

    def update(guild_id, config) do
      Agent.update(__MODULE__, &Map.put(&1, guild_id, config))
      Logger.debug "Recached"
    end

  end

  def get(guild_id, path \\ [], options \\ []) do
    do_translate = Keyword.get(options, :translate, true)

    document = find_document(guild_id)
    value    = get_in(document, path)

    with %{raw: raw, type: type} <- value
    do
      if do_translate do

      else
        raw
      end
    end
  end

  def translate(raw, type) do
    case type do
      ""
    end
  end

  defp find_document(guild_id) do
    filter = %{guild: guild_id}
    result = Mongo.find_one(:shiina, "guild-config", filter)
    case result do
      nil ->
        Mongo.insert_one(:shiina, "guild-config", filter)
        filter
      document -> Map.delete(document, "_id")
    end
  end

  # def get(guild) do
    # get(guild, "")
  # end

  # def get(guild, "") do
  #   get_document(guild)
  # end

  # def get(guild, path) do
  #   keys = String.split(path, ".")
  #   document = get_document(guild)
  #   Kernel.get_in(document, keys)
  # end

  # def exists(guild, path) do
  #   get(guild, path) != nil
  # end

  # def set(guild, path, value) do
  #   keys = String.split(path, ".")
  #   document = get(guild)
  #   document = Shiina.Helpers.put_in_safely(document, keys, value)
  #   update_document(guild, document)
  #   :ok
  # end

  # def unset(guild, path) do
  #   keys = String.split(path, ".")
  #   document = get(guild)
  #   {_, document} = Kernel.pop_in(document, keys)
  #   update_document(guild, document)
  #   :ok
  # end

  # def reset(guild, to \\ nil) do
  #   new_document = to || get_filter(guild)
  #   update_document(guild, new_document)
  #   {:ok, new_document}
  # end

  # defp update_document(guild, document) do
  #   filter = get_filter(guild)
  #   Mongo.find_one_and_replace(:shiina, "guild-config", filter, document, upsert: true)
  # end

  # defp get_filter(guild) do
  #   %{guild: guild}
  # end

end
