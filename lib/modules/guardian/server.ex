defmodule Shiina.Guardian.Server do
  use GenServer
  use Timex

  alias Alchemy.Client

  defmodule State do

    defstruct [
      :lock,
      :evaluation,
      rules: [],
    ]

  end

  ### Client ###

  @type timestamp :: integer

  @type rule :: map
  @type entity :: struct
  @type violations :: [entity]

  @type evaluation_result :: [{rule, violations}]
  @type evaluation :: {timestamp, evaluation_result}

  def start_link(guild_id) do
    GenServer.start_link(__MODULE__, %State{}, name: via_tuple(guild_id))
  end

  def init(init_arg) do
    {:ok, init_arg}
  end

  def call(guild_id, message) do
    GenServer.call(via_tuple(guild_id), message)
  end

  @spec where(Client.snowflake()) :: pid | :undefined
  def where(guild_id) do
    :gproc.where({:n, :l, {:guardian_state, guild_id}})
  end

  @spec exists(Client.snowflake()) :: boolean
  def exists(guild_id) do
    case where(guild_id) do
      :undefined -> false
      _          -> true
    end
  end

  @spec get_rules(Client.snowflake()) :: [map]
  def get_rules(guild_id) do
    call(guild_id, {:section, :rules})
  end

  @spec update_rules(Client.snowflake(), [map]) :: any
  def update_rules(guild_id, rules) do
    call(guild_id, {:put, :rules, rules})
  end

  @spec get_evaluation(Client.snowflake()) :: evaluation | nil
  def get_evaluation(guild_id) do
    call(guild_id, {:section, :evaluation})
  end

  @spec update_evaluation(Client.snowflake(), evaluation_result) :: any
  def update_evaluation(guild_id, result) do
    now = Timex.now() |> Timex.to_unix()
    call(guild_id, {:put, :evaluation, {now, result}})
  end

  def await_lock(guild_id, options \\ []) do
    poll_interval = Keyword.get(options, :poll_interval, 500)

    case call(guild_id, :lock_request) do
      :yes -> :ok
      :no ->
        receive do
        after
          poll_interval -> await_lock(guild_id, options)
        end
    end
  end

  def dispose_lock(guild_id) do
    call(guild_id, :lock_dispose)
  end

  defp via_tuple(guild_id) do
    {:via, :gproc, {:n, :l, {:guardian_state, guild_id}}}
  end

  ### Server ###

  def handle_call(:get, _, state) do
    {:reply, state, state}
  end

  def handle_call({:section, key}, _, state) do
    {:reply, Map.get(state, key), state}
  end

  def handle_call({:put, key, value}, _, state) do
    new_state = Map.put(state, key, value)
    {:reply, new_state, new_state}
  end

  def handle_call(:lock_request, {from, _}, state = %{lock: lock}) do
    case lock do
      nil   -> {:reply, :yes, %{state | lock: from}}
      ^from -> {:reply, :yes, state}
      pid   ->
        # In case the locking process crashed...
        case Process.alive?(pid) do
          true  -> {:reply, :no,  state}
          false -> {:reply, :yes, %{state | lock: from}}
        end
    end
  end

  def handle_call(:lock_dispose, {pid, _}, state = %{lock: lock}) do
    case lock do
      ^pid -> {:reply, {:ok, nil}, %{state | lock: nil}}
      _     -> {:reply, {:error, :bad_pid, state}}
    end
  end

end
