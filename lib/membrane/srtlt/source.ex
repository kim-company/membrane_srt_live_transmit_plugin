defmodule Membrane.SRTLT.Source do
  @moduledoc """
  Membrane source element that receives data from an SRT stream via
  the `srt-live-transmit` CLI tool.

  The element spawns `srt-live-transmit` as a child process, connecting to
  (or listening for) an SRT peer, and forwards the raw byte stream received
  on stdout as `Membrane.Buffer` structs on a push-mode output pad.

  ## Notifications

  The element sends the following notifications to its parent:

    * `{:source_state, :connected}` — first data chunk received from the process.
    * `{:source_state, :disconnected}` — the process exited after data had been
      received. Followed by an end-of-stream action.

  ## Graceful shutdown

  Send a `:close` parent notification to stop the source cleanly. The element
  will terminate the child process and emit end-of-stream.

  ## Example

      child(:srt_source, %Membrane.SRTLT.Source{
        host: "10.0.0.1",
        port: 9000,
        mode: :caller,
        latency_ms: 350,
        stream_id: "my-stream",
        passphrase: "secret123456"
      })

  """

  use Membrane.Source

  require Membrane.Logger

  @retry_base_ms 100
  @retry_max_ms 3_000
  @process_cleanup_tag :srtlt_source_process_cleanup

  def_output_pad(:output,
    accepted_format: Membrane.RemoteStream,
    flow_control: :push
  )

  def_options(
    host: [
      spec: String.t(),
      default: "127.0.0.1",
      description: "Hostname or IP address of the SRT peer."
    ],
    port: [
      spec: :inet.port_number(),
      default: 9710,
      description: "Port of the SRT peer."
    ],
    mode: [
      spec: :caller | :listener,
      default: :caller,
      description: "SRT connection mode."
    ],
    latency_ms: [
      spec: pos_integer(),
      default: 350,
      description:
        "Symmetric SRT latency in milliseconds. Used as the default for `peer_latency_ms` and `rcv_latency_ms` when those are not set."
    ],
    peer_latency_ms: [
      spec: pos_integer() | nil,
      default: nil,
      description: "SRT peer (send) latency in ms. Falls back to `latency_ms`."
    ],
    rcv_latency_ms: [
      spec: pos_integer() | nil,
      default: nil,
      description: "SRT receive latency in ms. Falls back to `latency_ms`."
    ],
    transtype: [
      spec: String.t(),
      default: "live",
      description: "SRT transport type (`live` or `file`)."
    ],
    stream_id: [
      spec: String.t() | nil,
      default: nil,
      description: "SRT stream identifier for multiplexing."
    ],
    passphrase: [
      spec: String.t() | nil,
      default: nil,
      description: "SRT encryption passphrase (10–79 characters). `nil` = no encryption."
    ],
    chunk_size_bytes: [
      spec: pos_integer(),
      default: 1316,
      description:
        "Max bytes read per step by srt-live-transmit. Default 1316 = 188×7 (7 MPEG-TS packets)."
    ],
    buffering_packets: [
      spec: pos_integer(),
      default: 10,
      description: "Application-level read batch size in srt-live-transmit."
    ],
    telemetry_prefix: [
      spec: [atom()] | nil,
      default: [:membrane, :srtlt],
      description:
        "Telemetry event prefix for SRT stats. Events are emitted as `prefix ++ [:stats]`. Set to `nil` to disable."
    ]
  )

  # -- Callbacks --

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      host: opts.host,
      port: opts.port,
      mode: opts.mode,
      latency_ms: opts.latency_ms,
      peer_latency_ms: opts.peer_latency_ms,
      rcv_latency_ms: opts.rcv_latency_ms,
      transtype: opts.transtype,
      stream_id: opts.stream_id,
      passphrase: opts.passphrase,
      chunk_size_bytes: opts.chunk_size_bytes,
      buffering_packets: opts.buffering_packets,
      telemetry_prefix: opts.telemetry_prefix,
      command_ref: nil,
      received_data?: false,
      notified_connected?: false,
      eos_sent?: false,
      retry_timer_ref: nil,
      retry_delay_ms: @retry_base_ms
    }

    {[], state}
  end

  @impl true
  def handle_setup(ctx, state), do: connect(ctx, state)

  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, %Membrane.RemoteStream{}}], state}
  end

  @impl true
  def handle_parent_notification(:close, ctx, state) do
    if state.eos_sent? do
      {[], state}
    else
      state =
        state
        |> cancel_retry_timer()
        |> drop_command_ref(ctx)

      {[end_of_stream: :output], %{state | eos_sent?: true}}
    end
  end

  def handle_parent_notification(_notification, _ctx, state), do: {[], state}

  @impl true
  def handle_terminate_request(ctx, state) do
    state =
      state
      |> cancel_retry_timer()
      |> drop_command_ref(ctx)

    {[terminate: :normal], state}
  end

  @impl true
  def handle_info(:retry_connect, _ctx, %{eos_sent?: true} = state) do
    {[], %{state | retry_timer_ref: nil}}
  end

  def handle_info(:retry_connect, ctx, state) do
    connect(ctx, %{state | retry_timer_ref: nil})
  end

  def handle_info({:stdout, ospid, payload}, ctx, %{command_ref: %{ospid: ospid}} = state) do
    notify_actions =
      if state.notified_connected? do
        []
      else
        [notify_parent: {:source_state, :connected}]
      end

    actions =
      if ctx.playback == :playing do
        notify_actions ++ [buffer: {:output, %Membrane.Buffer{payload: payload}}]
      else
        notify_actions
      end

    {actions,
     %{state | received_data?: true, notified_connected?: true, retry_delay_ms: @retry_base_ms}}
  end

  def handle_info({:stderr, ospid, payload}, _ctx, %{command_ref: %{ospid: ospid}} = state) do
    handle_stderr(payload, state)
    {[], state}
  end

  def handle_info(
        {:DOWN, ospid, :process, _pid, reason},
        ctx,
        %{command_ref: %{ospid: ospid}} = state
      ) do
    reason = normalize_down_reason(reason)

    state =
      state
      |> cancel_retry_timer()
      |> drop_command_ref(ctx)

    cond do
      state.eos_sent? ->
        {[], state}

      state.received_data? ->
        {[notify_parent: {:source_state, :disconnected}, end_of_stream: :output],
         %{state | eos_sent?: true}}

      true ->
        maybe_log_reconnect(reason)

        retry_in_ms = state.retry_delay_ms
        state = schedule_retry_with_backoff(state)

        Membrane.Logger.info(
          "srt-live-transmit[source]: no payload yet, reconnecting in #{retry_in_ms}ms"
        )

        {[], state}
    end
  end

  def handle_info(_message, _ctx, state), do: {[], state}

  # -- Private --

  defp connect(ctx, state) do
    state = cancel_retry_timer(state)

    with {:ok, executable} <- fetch_srt_live_transmit(),
         {:ok, pid, ospid} <- run_command(executable, state) do
      Membrane.ResourceGuard.unregister(ctx.resource_guard, @process_cleanup_tag)

      Membrane.ResourceGuard.register(
        ctx.resource_guard,
        fn -> safe_stop(ospid) end,
        tag: @process_cleanup_tag
      )

      {[], %{state | command_ref: %{pid: pid, ospid: ospid}, eos_sent?: false}}
    else
      {:error, reason} ->
        Membrane.Logger.warning("srt-live-transmit start failed: #{inspect(reason)}")
        {[], schedule_retry_with_backoff(state)}
    end
  end

  defp run_command(executable, state) do
    uri = build_srt_uri(state)

    cmd = [
      executable,
      "-autoreconnect",
      "no",
      "-srctime",
      "yes",
      "-loglevel",
      "warn",
      "-chunk:#{state.chunk_size_bytes}",
      "-buffering:#{state.buffering_packets}",
      "-stats-report-frequency",
      "100",
      "-pf",
      "json",
      uri,
      "file://con",
      "-statsout",
      "/dev/stderr"
    ]

    :exec.run(cmd, [
      {:stderr, self()},
      {:stdout, self()},
      :monitor,
      {:kill, "kill -s TERM ${CHILD_PID}"},
      {:kill_timeout, 1}
    ])
  end

  defp build_srt_uri(state) do
    peer_latency = state.peer_latency_ms || state.latency_ms
    rcv_latency = state.rcv_latency_ms || state.latency_ms

    Membrane.SRTLT.build_uri(
      host: state.host,
      port: state.port,
      mode: state.mode,
      latency: state.latency_ms,
      peerlatency: peer_latency,
      rcvlatency: rcv_latency,
      transtype: state.transtype,
      streamid: state.stream_id,
      passphrase: state.passphrase
    )
  end

  defp fetch_srt_live_transmit do
    case System.find_executable("srt-live-transmit") do
      nil -> {:error, :srt_live_transmit_not_found}
      executable -> {:ok, executable}
    end
  end

  defp schedule_retry_with_backoff(
         %{retry_timer_ref: nil, retry_delay_ms: retry_delay_ms} = state
       ) do
    next_delay_ms = min(retry_delay_ms * 2, @retry_max_ms)

    %{
      state
      | retry_timer_ref: Process.send_after(self(), :retry_connect, retry_delay_ms),
        retry_delay_ms: next_delay_ms
    }
  end

  defp schedule_retry_with_backoff(state), do: state

  defp cancel_retry_timer(%{retry_timer_ref: nil} = state), do: state

  defp cancel_retry_timer(%{retry_timer_ref: timer_ref} = state) do
    _ = Process.cancel_timer(timer_ref)
    %{state | retry_timer_ref: nil}
  end

  defp drop_command_ref(%{command_ref: nil} = state, ctx) do
    Membrane.ResourceGuard.unregister(ctx.resource_guard, @process_cleanup_tag)
    state
  end

  defp drop_command_ref(%{command_ref: %{ospid: ospid}} = state, ctx) do
    safe_stop_and_wait(ospid)
    Membrane.ResourceGuard.unregister(ctx.resource_guard, @process_cleanup_tag)
    %{state | command_ref: nil}
  end

  defp safe_stop_and_wait(ospid) do
    _ = :exec.stop_and_wait(ospid, 300)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp safe_stop(ospid) do
    _ = :exec.stop(ospid)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp handle_stderr(payload, state) when is_binary(payload) do
    if state.telemetry_prefix do
      metadata = %{host: state.host, port: state.port, stream_id: state.stream_id}

      for measurements <- Membrane.SRTLT.Stats.parse_all(payload) do
        Membrane.SRTLT.Stats.emit(measurements, state.telemetry_prefix, metadata)
      end
    end

    maybe_log_stderr(payload)
  end

  defp handle_stderr(_payload, _state), do: :ok

  defp maybe_log_stderr(payload) when is_binary(payload) do
    payload
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      trimmed = String.trim(line)

      if trimmed != "" and not String.starts_with?(trimmed, "{") do
        Membrane.Logger.warning("srt-live-transmit[source]: #{inspect(trimmed)}")
      end
    end)
  end

  defp maybe_log_stderr(_payload), do: :ok

  defp maybe_log_reconnect(:normal), do: :ok
  defp maybe_log_reconnect(:port_closed), do: :ok

  defp maybe_log_reconnect(reason) do
    Membrane.Logger.warning("srt-live-transmit[source]: exited with reason #{inspect(reason)}")
  end

  defp normalize_down_reason(:normal), do: :normal
  defp normalize_down_reason({:status, status}), do: :exec.status(status)
  defp normalize_down_reason({:exit_status, code}), do: {:status, code}
  defp normalize_down_reason(:port_closed), do: :port_closed
  defp normalize_down_reason(other), do: other
end
