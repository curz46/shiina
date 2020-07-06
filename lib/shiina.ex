defmodule Shiina do
  use Application
  use Alchemy.Cogs

  require Logger

  alias Alchemy.Client

  def start(_type, _args) do
    case System.get_env("TOKEN") do
      nil   -> IO.puts "TOKEN is not defined, cannot start"
      token ->
        Logger.info "Logging in..."
        run = Client.start(token |> String.trim)
        Logger.debug "Logged in."

        Logger.debug "Establishing connection to MongoDB..."
        mongo_url = System.get_env("MONGO_URL") |> String.trim
        {:ok, _} = Mongo.start_link(name: :shiina, url: mongo_url, pool_size: 2)
        Logger.debug "Connection established."

        Shiina.Config.Cache.start_link()

        # Fetch cache
        {:ok, guilds} = Client.get_current_guilds()
        for %Alchemy.UserGuild{id: guild_id} <- guilds do
          config = Shiina.Config.get(guild_id)
          Shiina.Config.Cache.update(guild_id, config)
        end

        # Register commands
        Cogs.set_prefix("s+")

        use Shiina.CommandHelp
        use Shiina.CommandPurge
        use Shiina.CommandConfig
        Shiina.CommandConfig.start_link()

        Shiina.Guardian.Module.init()

        # Guardian.Module.start_link()
        # use Guardian.Command
        # use Guardian.Module

        Logger.info "Ready to receive events."

        run
    end
  end
end
