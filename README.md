# Membrane SRT Live Transmit Plugin

A [Membrane](https://membrane.stream) source element that receives data from an
SRT stream via the [`srt-live-transmit`](https://github.com/Haivision/srt) CLI tool.

Instead of linking against libsrt, this plugin spawns `srt-live-transmit` as a
child process and reads its stdout. This keeps the Erlang VM isolated from the
SRT C library while still supporting the full set of SRT socket options.

## Prerequisites

`srt-live-transmit` must be available on `$PATH`. Install it via your package
manager or build from source:

```bash
# macOS
brew install srt

# Ubuntu/Debian
apt install srt-tools
```

## Installation

Add `membrane_srt_live_transmit` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_srt_live_transmit, "~> 0.1.0"}
  ]
end
```

## Docker / `erlexec` considerations

This library uses [`erlexec`](https://hex.pm/packages/erlexec) to spawn and
supervise the `srt-live-transmit` child process. When you run your application
inside Docker, there are two important things to keep in mind:

1. `erlexec` refuses to run as `root`
2. `erlexec` expects the `SHELL` environment variable to be set

That means your container should run the application as a non-root user, and
should define a valid shell path such as `/bin/bash`.

For example, in the test stage of
`/Users/dmorn/projects/video-taxi/speech/Dockerfile`, the container switches to
an unprivileged user before running tests and sets `SHELL` explicitly:

```dockerfile
# erlexec refuses to run as root and requires SHELL to be set.
# Hex/Rebar are per-user installs, so copy root's Mix home to testuser.
RUN useradd -m -s /bin/bash testuser \
  && cp -a /root/.mix /home/testuser/.mix \
  && chown -R testuser:testuser /app /home/testuser/.mix
USER testuser
ENV HOME=/home/testuser
ENV SHELL=/bin/bash
RUN mix test
```

The same applies to release images. In the example Dockerfile, the final image
sets `SHELL` and runs as `nobody` instead of `root`:

```dockerfile
WORKDIR "/app"
RUN chown nobody /app

ENV MIX_ENV="prod"
ENV SHELL=/bin/bash

COPY --from=release --chown=nobody:root /app/_build/${MIX_ENV}/rel/speech ./
USER nobody
```

If your image does not already include Bash, make sure to install it or set
`SHELL` to another valid shell binary available in the container.

## Usage

### Source element

`Membrane.SRTLT.Source` connects to (or listens for) an SRT peer and outputs
raw bytes as a push-mode stream:

```elixir
child(:srt_source, %Membrane.SRTLT.Source{
  host: "10.0.0.1",
  port: 9000,
  mode: :caller,
  latency_ms: 350,
  stream_id: "my-stream",
  passphrase: "secret123456"
})
|> child(:parser, ...)
```

All options have sensible defaults. See the module docs for the full list.

#### Options

| Option | Default | Description |
|--------|---------|-------------|
| `host` | `"127.0.0.1"` | Hostname or IP of the SRT peer |
| `port` | `9710` | Port of the SRT peer |
| `mode` | `:caller` | `:caller` or `:listener` |
| `latency_ms` | `350` | Symmetric SRT latency in ms |
| `peer_latency_ms` | `nil` | Peer (send) latency override, falls back to `latency_ms` |
| `rcv_latency_ms` | `nil` | Receive latency override, falls back to `latency_ms` |
| `transtype` | `"live"` | SRT transport type |
| `stream_id` | `nil` | SRT stream identifier |
| `passphrase` | `nil` | Encryption passphrase (10–79 chars), `nil` = no encryption |
| `chunk_size_bytes` | `1316` | Max bytes per read (188×7, ideal for MPEG-TS) |
| `buffering_packets` | `10` | Application-level read batch size |

#### Lifecycle notifications

The source sends these notifications to its parent:

- `{:source_state, :connected}` — first data received from the SRT peer
- `{:source_state, :disconnected}` — peer disconnected after data was flowing (followed by end-of-stream)

Send a `:close` parent notification to shut down the source gracefully.

### URI builder

`Membrane.SRTLT.build_uri/1` assembles an SRT URI from discrete parameters,
useful when constructing URIs for other tools or a future Sink element:

```elixir
Membrane.SRTLT.build_uri(
  host: "192.168.1.10",
  port: 9000,
  mode: :caller,
  latency: 350,
  transtype: "live",
  streamid: "my-stream"
)
# => "srt://192.168.1.10:9000?latency=350&mode=caller&streamid=my-stream&transtype=live"
```

## Reference

See [`docs/srt-live-transmit-reference.md`](docs/srt-live-transmit-reference.md)
for a complete reference of all `srt-live-transmit` CLI options and SRT socket
parameters.

## License

TODO
