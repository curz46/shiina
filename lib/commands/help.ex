defmodule Shiina.CommandHelp do
  use Alchemy.Cogs

  Cogs.def help do
    case :rand.uniform(3) do
      1 -> Cogs.say "Need some help?"
      2 -> Cogs.say "Here's a message!"
      3 -> Cogs.say "My disappointment is immeasureable, and my day is ruined."
    end
  end
end
