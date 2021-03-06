defmodule Tai.VenueAdapters.Bitmex.Stream.Connection do
  use WebSockex
  alias Tai.VenueAdapters.Bitmex.Stream

  defmodule State do
    @type product :: Tai.Venues.Product.t()
    @type venue_id :: Tai.Venue.id()
    @type credential_id :: Tai.Venue.credential_id()
    @type channel_name :: atom
    @type route :: :auth | :order_books | :optional_channels
    @type t :: %State{
            venue: venue_id,
            routes: %{required(route) => atom},
            channels: [channel_name],
            credential: {credential_id, map} | nil,
            products: [product],
            quote_depth: pos_integer,
            opts: map,
            heartbeat_timer: reference | nil,
            heartbeat_timeout_timer: reference | nil
          }

    @enforce_keys ~w[venue routes channels products quote_depth opts]a
    defstruct ~w[venue routes channels credential products quote_depth opts heartbeat_timer heartbeat_timeout_timer]a
  end

  @type stream :: Tai.Venues.Stream.t()
  @type venue_id :: Tai.Venue.id()
  @type credential_id :: Tai.Venue.credential_id()
  @type credential :: Tai.Venue.credential()
  @type venue_msg :: map

  @spec start_link(
          endpoint: String.t(),
          stream: stream,
          credential: {credential_id, credential} | nil
        ) :: {:ok, pid} | {:error, term}
  def start_link(endpoint: endpoint, stream: stream, credential: credential) do
    routes = %{
      auth: stream.venue.id |> Stream.ProcessAuth.to_name(),
      order_books: stream.venue.id |> Stream.RouteOrderBooks.to_name(),
      optional_channels: stream.venue.id |> Stream.ProcessOptionalChannels.to_name()
    }

    state = %State{
      venue: stream.venue.id,
      routes: routes,
      channels: stream.venue.channels,
      credential: credential,
      products: stream.products,
      quote_depth: stream.venue.quote_depth,
      opts: stream.venue.opts
    }

    name = to_name(stream.venue.id)
    headers = auth_headers(state.credential)
    WebSockex.start_link(endpoint, __MODULE__, state, name: name, extra_headers: headers)
  end

  @spec to_name(venue_id) :: atom
  def to_name(venue), do: :"#{__MODULE__}_#{venue}"

  def terminate(close_reason, state) do
    TaiEvents.warn(%Tai.Events.StreamTerminate{venue: state.venue, reason: close_reason})
  end

  def handle_connect(_conn, state) do
    TaiEvents.info(%Tai.Events.StreamConnect{venue: state.venue})
    send(self(), :init_subscriptions)
    {:ok, state}
  end

  def handle_disconnect(conn_status, state) do
    TaiEvents.warn(%Tai.Events.StreamDisconnect{
      venue: state.venue,
      reason: conn_status.reason
    })

    {:ok, state}
  end

  @optional_channels [
    :trades,
    :connected_stats,
    :liquidations,
    :notifications,
    :funding,
    :insurance,
    :settlement
  ]
  def handle_info(:init_subscriptions, state) do
    if state.credential do
      send(self(), :login)
      send(self(), {:subscribe, :margin})
      send(self(), {:subscribe, :positions})
    end

    send(self(), {:subscribe, :depth})

    state.channels
    |> Enum.each(fn c ->
      if Enum.member?(@optional_channels, c) do
        send(self(), {:subscribe, c})
      else
        TaiEvents.warn(%Tai.Events.StreamChannelInvalid{
          venue: state.venue,
          name: c,
          available: @optional_channels
        })
      end
    end)

    schedule_autocancel(0)
    state = state |> schedule_heartbeat()

    {:ok, state}
  end

  def handle_info(:login, state) do
    msg = %{"op" => "subscribe", "args" => ["order"]} |> Jason.encode!()
    {:reply, {:text, msg}, state}
  end

  def handle_info({:send_msg, msg}, state) do
    {:reply, {:text, msg}, state}
  end

  # Bitmex has an unpublished limit to websocket message lengths.
  @products_chunk_count 10
  def handle_info({:subscribe, :depth}, state) do
    # > 25 quotes are experimental. It has performance issues causing message queue back pressure
    order_book_table = if state.quote_depth <= 25, do: "orderBookL2_25", else: "orderBookL2"

    state.products
    |> Enum.chunk_every(@products_chunk_count)
    |> Enum.each(fn products ->
      args = products |> Enum.map(fn p -> "#{order_book_table}:#{p.venue_symbol}" end)
      msg = %{"op" => "subscribe", "args" => args} |> Jason.encode!()
      send(self(), {:send_msg, msg})
    end)

    {:ok, state}
  end

  def handle_info({:subscribe, :trades}, state) do
    state.products
    |> Enum.chunk_every(@products_chunk_count)
    |> Enum.each(fn products ->
      args = products |> Enum.map(fn p -> "trade:#{p.venue_symbol}" end)
      msg = %{"op" => "subscribe", "args" => args} |> Jason.encode!()
      send(self(), {:send_msg, msg})
    end)

    {:ok, state}
  end

  def handle_info({:subscribe, :positions}, state) do
    msg = %{"op" => "subscribe", "args" => ["position"]} |> Jason.encode!()
    {:reply, {:text, msg}, state}
  end

  def handle_info({:subscribe, :margin}, state) do
    msg = %{"op" => "subscribe", "args" => ["margin"]} |> Jason.encode!()
    {:reply, {:text, msg}, state}
  end

  def handle_info({:subscribe, :connected_stats}, state) do
    msg = %{"op" => "subscribe", "args" => ["connected"]} |> Jason.encode!()
    {:reply, {:text, msg}, state}
  end

  def handle_info({:subscribe, :liquidations}, state) do
    msg = %{"op" => "subscribe", "args" => ["liquidation"]} |> Jason.encode!()
    {:reply, {:text, msg}, state}
  end

  def handle_info({:subscribe, :notifications}, state) do
    msg = %{"op" => "subscribe", "args" => ["publicNotifications"]} |> Jason.encode!()
    {:reply, {:text, msg}, state}
  end

  def handle_info({:subscribe, :funding}, state) do
    msg = %{"op" => "subscribe", "args" => ["funding"]} |> Jason.encode!()
    {:reply, {:text, msg}, state}
  end

  def handle_info({:subscribe, :insurance}, state) do
    msg = %{"op" => "subscribe", "args" => ["insurance"]} |> Jason.encode!()
    {:reply, {:text, msg}, state}
  end

  def handle_info({:subscribe, :settlement}, state) do
    msg = %{"op" => "subscribe", "args" => ["settlement"]} |> Jason.encode!()
    {:reply, {:text, msg}, state}
  end

  def handle_info(
        :ping_autocancel,
        %{
          opts: %{
            autocancel: %{ping_interval_ms: ping_interval_ms, cancel_after_ms: cancel_after_ms}
          }
        } = state
      )
      when ping_interval_ms > 0 and is_integer(ping_interval_ms) and
             cancel_after_ms > 0 and is_integer(cancel_after_ms) do
    schedule_autocancel(ping_interval_ms)
    msg = %{"op" => "cancelAllAfter", "args" => cancel_after_ms} |> Jason.encode!()
    {:reply, {:text, msg}, state}
  end

  def handle_info(:ping_autocancel, state), do: {:ok, state}

  def handle_info(:heartbeat, state) do
    state = state |> schedule_heartbeat_timeout()
    {:reply, :ping, state}
  end

  def handle_info(:heartbeat_timeout, state) do
    {:close, {1000, "heartbeat timeout"}, state}
  end

  def handle_pong(:pong, state) do
    state =
      state
      |> cancel_heartbeat_timeout()
      |> schedule_heartbeat()

    {:ok, state}
  end

  def handle_frame({:text, msg}, state) do
    msg
    |> Jason.decode!()
    |> handle_msg(state)

    {:ok, state}
  end

  def handle_frame(_frame, state) do
    {:ok, state}
  end

  defp auth_headers({_credential_id, %{api_key: api_key, api_secret: api_secret}}) do
    nonce = ExBitmex.Auth.nonce()
    api_signature = ExBitmex.Auth.sign(api_secret, "GET", "/realtime", nonce, "")

    [
      "api-key": api_key,
      "api-signature": api_signature,
      "api-expires": nonce
    ]
  end

  defp auth_headers(nil), do: []

  defp schedule_autocancel(after_ms) do
    Process.send_after(self(), :ping_autocancel, after_ms)
  end

  @heartbeat_ms 5_000
  defp schedule_heartbeat(state) do
    timer = Process.send_after(self(), :heartbeat, @heartbeat_ms)
    %{state | heartbeat_timer: timer}
  end

  @heartbeat_timeout_ms 3_000
  defp schedule_heartbeat_timeout(state) do
    timer = Process.send_after(self(), :heartbeat_timeout, @heartbeat_timeout_ms)
    %{state | heartbeat_timeout_timer: timer}
  end

  defp cancel_heartbeat_timeout(state) do
    Process.cancel_timer(state.heartbeat_timeout_timer)
    %{state | heartbeat_timeout_timer: nil}
  end

  @spec handle_msg(venue_msg, State.t()) :: no_return
  defp handle_msg(msg, state)

  defp handle_msg(%{"limit" => %{"remaining" => remaining}, "version" => _}, state) do
    TaiEvents.info(%Tai.Events.BitmexStreamConnectionLimitDetails{
      venue_id: state.venue,
      remaining: remaining
    })
  end

  defp handle_msg(%{"request" => _, "subscribe" => _} = msg, state) do
    msg |> forward(:order_books, state)
  end

  @order_book_tables ~w(orderBookL2 orderBookL2_25)
  defp handle_msg(%{"table" => table} = msg, state) when table in @order_book_tables do
    msg |> forward(:order_books, state)
  end

  @auth_tables ~w(position wallet margin order execution transact)
  defp handle_msg(%{"table" => table} = msg, state) when table in @auth_tables do
    msg |> forward(:auth, state)
  end

  defp handle_msg(msg, state) do
    msg |> forward(:optional_channels, state)
  end

  defp forward(msg, to, state) do
    state.routes
    |> Map.fetch!(to)
    |> GenServer.cast({msg, System.monotonic_time()})
  end
end
