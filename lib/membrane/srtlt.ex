defmodule Membrane.SRTLT do
  @moduledoc """
  URI builder for `srt-live-transmit`.

  Builds an SRT URI string from discrete parameters, suitable for passing
  as a source or target argument to the `srt-live-transmit` CLI tool.

  ## Example

      iex> Membrane.SRTLT.build_uri(host: "10.0.0.1", port: 9000, mode: :caller, latency: 350)
      "srt://10.0.0.1:9000?latency=350&mode=caller"

  """

  @srt_query_keys ~w(
    mode latency rcvlatency peerlatency transtype
    streamid passphrase pbkeylen
    conntimeo peeridletimeo
    maxbw inputbw mininputbw oheadbw
    sndbuf rcvbuf fc
    mss ipttl iptos ipv6only
    tlpktdrop snddropdelay nakreport lossmaxttl retransmitalgo
    tsbpdmode messageapi congestion payloadsize
    enforcedencryption kmrefreshrate kmpreannounce
    packetfilter drifttracer linger adapter
  )a

  @doc """
  Builds an SRT URI string from the given options.

  ## Required

    * `:host` — target hostname or IP address
    * `:port` — target port number

  ## Optional

  All other keys are appended as query parameters when their value is
  not `nil`. Atom values are converted to strings. Boolean values become
  `"true"` / `"false"`. The full set of recognised SRT query parameters
  is documented in `docs/srt-live-transmit-reference.md`.

  Unknown keys are silently ignored.

  ## Examples

      iex> Membrane.SRTLT.build_uri(host: "192.168.1.10", port: 9000)
      "srt://192.168.1.10:9000"

      iex> Membrane.SRTLT.build_uri(
      ...>   host: "192.168.1.10",
      ...>   port: 9000,
      ...>   mode: :caller,
      ...>   latency: 350,
      ...>   streamid: "my-stream",
      ...>   passphrase: "secret123456"
      ...> )
      "srt://192.168.1.10:9000?latency=350&mode=caller&passphrase=secret123456&streamid=my-stream"

  """
  @spec build_uri(keyword()) :: String.t()
  def build_uri(opts) when is_list(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)

    query =
      opts
      |> Keyword.drop([:host, :port])
      |> Enum.filter(fn {key, value} -> key in @srt_query_keys and value != nil end)
      |> Enum.map(fn {key, value} -> {Atom.to_string(key), encode_value(value)} end)
      |> Enum.sort()
      |> URI.encode_query()

    base = "srt://#{host}:#{port}"

    case query do
      "" -> base
      q -> "#{base}?#{q}"
    end
  end

  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_boolean(value), do: to_string(value)
  defp encode_value(value) when is_binary(value), do: value
end
