defmodule Membrane.SRTLT.Stats do
  @moduledoc """
  Parses JSON stats emitted by `srt-live-transmit` on stderr and emits
  them as `:telemetry` events.

  ## Stats format

  With `-pf json` and `-stats-report-frequency N`, `srt-live-transmit`
  writes a JSON object to stderr every N packets. This module extracts
  a flat measurement map from that JSON.

  ## Telemetry event

  Event name: `prefix ++ [:stats]` (default `[:membrane, :srtlt, :stats]`).

  Measurements:

  | Key | Source | Type |
  |-----|--------|------|
  | `send_bytes` | `send.bytes` | integer |
  | `send_packets` | `send.packets` | integer |
  | `send_packets_lost` | `send.packetsLost` | integer |
  | `send_packets_dropped` | `send.packetsDropped` | integer |
  | `send_packets_retransmitted` | `send.packetsRetransmitted` | integer |
  | `send_mbit_rate` | `send.mbitRate` | float |
  | `recv_bytes` | `recv.bytes` | integer |
  | `recv_packets` | `recv.packets` | integer |
  | `recv_packets_lost` | `recv.packetsLost` | integer |
  | `recv_packets_dropped` | `recv.packetsDropped` | integer |
  | `recv_packets_retransmitted` | `recv.packetsRetransmitted` | integer |
  | `recv_packets_belated` | `recv.packetsBelated` | integer |
  | `recv_mbit_rate` | `recv.mbitRate` | float |
  | `recv_ms_buf` | `recv.msBuf` | integer |
  | `link_rtt` | `link.rtt` | float |
  | `link_bandwidth` | `link.bandwidth` | float |
  """

  @doc """
  Parses a single JSON stats line from `srt-live-transmit` stderr.

  Returns `{:ok, measurements}` with a flat measurement map, or `:error`
  if the line is not valid stats JSON.

  Multiple JSON objects may be present in a single stderr chunk (mixed with
  log lines). Use `parse_all/1` to extract all stats from a chunk.
  """
  @spec parse(binary()) :: {:ok, map()} | :error
  def parse(line) when is_binary(line) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "{") do
      case JSON.decode(trimmed) do
        {:ok, decoded} -> extract_measurements(decoded)
        {:error, _} -> :error
      end
    else
      :error
    end
  end

  def parse(_), do: :error

  @doc """
  Parses all JSON stats objects from a stderr chunk.

  A single stderr message may contain multiple lines — some are log lines,
  some are JSON stats. This function splits on newlines and returns a list
  of successfully parsed measurement maps.
  """
  @spec parse_all(binary()) :: [map()]
  def parse_all(chunk) when is_binary(chunk) do
    chunk
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case parse(line) do
        {:ok, measurements} -> [measurements]
        :error -> []
      end
    end)
  end

  @doc """
  Emits a telemetry event for the given measurements.

  Calls `:telemetry.execute(prefix ++ [:stats], measurements, metadata)`.
  """
  @spec emit(map(), [atom()], map()) :: :ok
  def emit(measurements, prefix, metadata) when is_list(prefix) and is_map(metadata) do
    :telemetry.execute(prefix ++ [:stats], measurements, metadata)
  end

  defp extract_measurements(%{"send" => send, "recv" => recv} = decoded) do
    link = Map.get(decoded, "link", %{})

    measurements = %{
      send_bytes: get_int(send, "bytes"),
      send_packets: get_int(send, "packets"),
      send_packets_lost: get_int(send, "packetsLost"),
      send_packets_dropped: get_int(send, "packetsDropped"),
      send_packets_retransmitted: get_int(send, "packetsRetransmitted"),
      send_mbit_rate: get_float(send, "mbitRate"),
      recv_bytes: get_int(recv, "bytes"),
      recv_packets: get_int(recv, "packets"),
      recv_packets_lost: get_int(recv, "packetsLost"),
      recv_packets_dropped: get_int(recv, "packetsDropped"),
      recv_packets_retransmitted: get_int(recv, "packetsRetransmitted"),
      recv_packets_belated: get_int(recv, "packetsBelated"),
      recv_mbit_rate: get_float(recv, "mbitRate"),
      recv_ms_buf: get_int(recv, "msBuf"),
      link_rtt: get_float(link, "rtt"),
      link_bandwidth: get_float(link, "bandwidth")
    }

    {:ok, measurements}
  end

  defp extract_measurements(_), do: :error

  defp get_int(map, key) when is_map(map) do
    case Map.get(map, key, 0) do
      v when is_integer(v) -> v
      v when is_float(v) -> round(v)
      _ -> 0
    end
  end

  defp get_float(map, key) when is_map(map) do
    case Map.get(map, key, 0.0) do
      v when is_float(v) -> v
      v when is_integer(v) -> v / 1
      _ -> 0.0
    end
  end
end
