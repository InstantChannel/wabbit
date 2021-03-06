defmodule Wabbit.Connection do
  use Connection
  import Wabbit.Record

  @doc """
  Starts a new connection

  # Options

    * `:username` - Default is `"guest"`
    * `:password` - Default is `"guest"`
    * `:virtual_host` - The name of the virtual host to work with. Default is `"/"`
    * `:host` - Server host name or address. Default is `"localhost"`
    * `:port` - Default is `:undefined`
    * `:channel_max` - The maximum total number of channels that the
      client will use per connection. Default is `0`
    * `:frame_max` - The largest frame size that the client and server
      will use for the connection. Default is `0`
    * `:heartbeat` - The delay, in seconds, of the connection
      heartbeat that the client wants. Default is `0`
    * `:connection_timeout` - Default is `:infinity`
    * `:ssl_options` - Default is `:none`
    * `:client_properties` - Default is `[]`
    * `:socket_options` - Default is `[]`
    * `:auth_mechanisms` - A list of the security mechanisms that the
      server supports. Default is `[&:amqp_auth_mechanisms.plain/3,
      &:amqp_auth_mechanisms.amqplain/3]`
  """
  def start_link(options \\ []) do
    Connection.start_link(__MODULE__, options, options)
  end

  @doc """
  Closes a connection
  """
  def close(conn), do: Connection.call(conn, :close)

  @doc """
  Stops a connection
  """
  def stop(conn), do: GenServer.stop(conn)

  def connect(_, state) do
    case open(state.opts) do
      {:ok, conn} ->
        true = Process.link(conn)
        {:ok, %{state | conn: conn}}
      {:error, reason} ->
        :error_logger.format("Connection error: ~s~n", [reason])
        {:backoff, 1_000, state}
    end
  end

  def disconnect(info, state) do
    case info do
      {:close, from} ->
        :ok = :amqp_connection.close(state.conn)
        Connection.reply(from, :ok)
      {:error, :closed} ->
        :error_logger.format("Connection closed~n", [])
      {:error, reason} ->
        :error_logger.format("Connection error: ~s~n", [reason])
    end
    {:connect, :reconnect, %{state | conn: nil, channels: %{}}}
  end

  @doc """
  Opens a new channel
  """
  def open_channel(conn) do
    Connection.call(conn, :open_channel)
  end

  def init(opts) do
    Process.flag(:trap_exit, true)
    state = %{conn: nil, opts: opts, channels: %{}}
    {:connect, :init, state}
  end

  def handle_call(_, _, %{conn: nil} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call(:open_channel, {from, _ref}, state) do
    try do
      case :amqp_connection.open_channel(state.conn) do
        {:ok, chan} ->
          monitor_ref = Process.monitor(from)
          channels = Map.put(state.channels, monitor_ref, chan)
          {:reply, {:ok, chan}, %{state | channels: channels}}
        other ->
          {:reply, other, state}
      end
    catch
      :exit, {:noproc, _} ->
        {:reply, {:error, :closed}, state}
      _, _ ->
        {:reply, {:error, :closed}, state}
    end
  end

  def handle_call(:close, from, state) do
    {:disconnect, {:close, from}, state}
  end

  def handle_info({:EXIT, conn, {:shutdown, {:server_initiated_close, _, _}}}, %{conn: conn} = state) do
    {:disconnect, {:error, :server_initiated_close}, state}
  end

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) do
    {:disconnect, {:error, reason}, state}
  end

  def handle_info({:EXIT, conn, {:shutdown, :normal}}, %{conn: conn} = state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    state =
      case Map.get(state.channels, monitor_ref) do
        nil -> state
        pid ->
          try do
            :ok = :amqp_channel.close(pid)
          catch
            _, _ -> :ok
          end
          %{state | channels: Map.delete(state.channels, monitor_ref)}
      end
    {:noreply, state}
  end

  def handle_info(_info, state) do
    {:noreply, state}
  end

  def terminate(_reason, state) do
    :amqp_connection.close(state.conn)
  end

  defp open(options) when is_list(options) do
    options = options |> normalize_ssl_options

    amqp_params =
      amqp_params_network(
        username:           Keyword.get(options, :username,           "guest"),
        password:           Keyword.get(options, :password,           "guest"),
        virtual_host:       Keyword.get(options, :virtual_host,       "/"),
        host:               Keyword.get(options, :host,               'localhost') |> to_charlist,
        port:               Keyword.get(options, :port,               :undefined),
        channel_max:        Keyword.get(options, :channel_max,        0),
        frame_max:          Keyword.get(options, :frame_max,          0),
        heartbeat:          Keyword.get(options, :heartbeat,          0),
        connection_timeout: Keyword.get(options, :connection_timeout, :infinity),
        ssl_options:        Keyword.get(options, :ssl_options,        :none),
        client_properties:  Keyword.get(options, :client_properties,  []),
        socket_options:     Keyword.get(options, :socket_options,     []),
        auth_mechanisms:    Keyword.get(options, :auth_mechanisms,    [&:amqp_auth_mechanisms.plain/3, &:amqp_auth_mechanisms.amqplain/3]))

    case :amqp_connection.start(amqp_params) do
      {:ok, pid} -> {:ok, pid}
      error      -> error
    end
  end

  defp normalize_ssl_options(options) when is_list(options) do
    for {k, v} <- options do
      if k in [:cacertfile, :cacertfile, :cacertfile] do
        {k, to_charlist(v)}
      else
        {k, v}
      end
    end
  end
  defp normalize_ssl_options(options), do: options
end
