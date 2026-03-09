# srt-live-transmit Reference

Reference for the `srt-live-transmit` CLI tool from the [Haivision SRT](https://github.com/Haivision/srt) project. Based on the source code at `apps/srt-live-transmit.cpp` (and supporting files) from the `master` branch, accessed March 2026.

## Invocation

```
srt-live-transmit [options] <input-uri> <output-uri>
```

Exactly two positional arguments are required: a source URI and a target URI.

## URI Format

```
SCHEME://HOST:PORT?param1=value1&param2=value2
```

### Supported Schemes

| Scheme  | Description |
|---------|-------------|
| `srt`   | SRT socket. HOST, PORT, and query params configure the connection. |
| `udp`   | UDP socket. |
| `rtp`   | RTP over UDP. |
| `file`  | Local file. Only `file://con` is meaningful for stdin/stdout piping. |

For our use case the relevant pair is: `srt://HOST:PORT?...` → `file://con` (SRT source piped to stdout).

## CLI Options

Options use `-name` or `-name:value` syntax. Some accept a space-separated argument instead (e.g. `-name value`).

### Process Behaviour

| Option | Aliases | Default | Type | Description |
|--------|---------|---------|------|-------------|
| `-autoreconnect` | `-a`, `-auto` | `yes` | bool (`yes`/`no`) | Auto-reconnect on disconnect. When `no`, the process exits on connection loss. |
| `-timeout` | `-t`, `-to` | `0` | int (seconds) | Exit timer. `0` = no timeout. Unix only. |
| `-timeout-mode` | `-tm` | `0` | int | `0` = since app start; `1` = same but cancel timer on connect. |

### Data Transfer

| Option | Aliases | Default | Type | Description |
|--------|---------|---------|------|-------------|
| `-chunk` | `-c` | `1456` | int (bytes) | Max size of data read in one step. Must fit one SRT packet. See [Chunk Size](#chunk-size) below. |
| `-srctime` | `-st`, `-sourcetime` | `yes` | bool | Pass packet timestamps from source to SRT output. |
| `-buffering` | — | `10` | int (packets) | Buffer up to N incoming packets before writing. Must be > 0. |

### Statistics & Logging

| Option | Aliases | Default | Type | Description |
|--------|---------|---------|------|-------------|
| `-stats-report-frequency` | `-s`, `-stats` | `0` | int (packets) | How often to print stats. `0` = disabled. |
| `-statsout` | — | (none) | string (path) | Write stats to this file. If unset and stats enabled, prints to stdout. |
| `-pf` | `-statspf` | `default` | enum | Stats format: `json`, `csv`, or `default` (2-column). |
| `-fullstats` | `-f` | off | flag | Include total (cumulative) counters in stats, not just interval. |
| `-bwreport` | `-r`, `-report`, `-bandwidth-report`, `-bitrate-report` | `0` | int | Bandwidth report frequency in packets. |
| `-loglevel` | `-ll` | `warn` | enum | Minimum log level: `fatal`, `error`, `warn`, `note`, `info`, `debug`. |
| `-logfa` | `-lfa` | all except haicrypt | string | Comma-separated functional areas. Use `all` for everything. |
| `-logfile` | — | (none) | string | Write logs to file instead of stderr. |
| `-quiet` | `-q` | off | flag | Suppress all informational output. |
| `-verbose` | `-v` | off | flag | Verbose output (disabled if `-quiet` is set). |

## SRT URI Query Parameters (Socket Options)

All SRT socket options are passed as URI query parameters on the `srt://` URI. They are applied via `srt_setsockopt()` before or after connecting, depending on binding type.

### Connection Mode

| Parameter | Type | Binding | Description |
|-----------|------|---------|-------------|
| `mode` | string | PRE | Connection mode: `caller`, `listener`, `rendezvous`, `client` (=caller), `server` (=listener), or `default`. |

**Mode auto-detection** (when `mode` is absent or `default`):
- If host is empty → `listener`
- If host is set and `adapter` is set → `rendezvous`
- If host is set and no adapter → `caller`

### Latency & Timing

| Parameter | Type | Binding | Default | Description |
|-----------|------|---------|---------|-------------|
| `latency` | int (ms) | PRE | (SRT default) | Symmetric latency. Sets both receive and peer latency unless overridden. |
| `rcvlatency` | int (ms) | PRE | (SRT default) | Receive-side latency. Overrides `latency` for the receive direction. |
| `peerlatency` | int (ms) | PRE | (SRT default) | Peer (send) latency. Overrides `latency` for the send direction. |
| `tsbpdmode` | bool | PRE | true (live) | Timestamp-based packet delivery mode. |
| `transtype` | enum | PRE | (SRT default) | Transport type: `live` or `file`. Sets a bundle of defaults. |

**Latency negotiation**: SRT negotiates latency between peers. The effective latency is `max(sender's peerlatency, receiver's rcvlatency)`. Setting `latency` is a convenience that sets both `rcvlatency` and `peerlatency` to the same value, but explicit `rcvlatency`/`peerlatency` values take precedence.

### Encryption

| Parameter | Type | Binding | Description |
|-----------|------|---------|-------------|
| `passphrase` | string | PRE | Encryption passphrase (10–79 characters). Empty = no encryption. |
| `pbkeylen` | int | PRE | Encryption key length in bits: `16`, `24`, or `32`. Default depends on SRT build. |
| `enforcedencryption` | bool | PRE | If true, connection fails when encryption parameters don't match. |
| `kmrefreshrate` | int | PRE | Key material refresh rate in packets. |
| `kmpreannounce` | int | PRE | How many packets before key refresh to announce the new key. |

### Stream Identification

| Parameter | Type | Binding | Description |
|-----------|------|---------|-------------|
| `streamid` | string | PRE | Application-defined stream identifier. Passed to the listener's accept callback. Used for stream multiplexing and routing. |

### Buffer & Flow Control

| Parameter | Type | Binding | Description |
|-----------|------|---------|-------------|
| `sndbuf` | int (bytes) | PRE | Send buffer size. |
| `rcvbuf` | int (bytes) | PRE | Receive buffer size. |
| `fc` | int (packets) | PRE | Flow control window size. |
| `maxbw` | int64 (bytes/s) | POST | Maximum bandwidth. `-1` = infinite, `0` = auto (relative to input rate). |
| `inputbw` | int64 (bytes/s) | POST | Estimated input bandwidth (used when `maxbw=0`). |
| `mininputbw` | int64 (bytes/s) | POST | Minimum input bandwidth estimate. |
| `oheadbw` | int (%) | POST | Overhead bandwidth percentage above input rate. |

### Reliability & Loss Recovery

| Parameter | Type | Binding | Description |
|-----------|------|---------|-------------|
| `tlpktdrop` | bool | PRE | Too-late packet drop. If true, packets arriving after the latency window are dropped. |
| `snddropdelay` | int (ms) | POST | Extra delay before the sender drops packets. |
| `nakreport` | bool | PRE | Enable periodic NAK reports. |
| `lossmaxttl` | int | POST | Maximum reorder tolerance in packets. |
| `retransmitalgo` | int | PRE | Retransmission algorithm: `0` = legacy, `1` = efficient (default on recent SRT). |
| `conntimeo` | int (ms) | PRE | Connection timeout. |
| `peeridletimeo` | int (ms) | PRE | Peer idle timeout — disconnect if no packets received for this long. |

### Network

| Parameter | Type | Binding | Description |
|-----------|------|---------|-------------|
| `mss` | int (bytes) | PRE | Maximum segment size (default 1500). |
| `ipttl` | int | PRE | IP Time-To-Live. |
| `iptos` | int | PRE | IP Type of Service. |
| `ipv6only` | int | PRE | Restrict to IPv6 only. |
| `adapter` | string | — | Local network adapter/IP to bind. Also influences mode detection: if set with a host, mode defaults to `rendezvous`. |
| `port` | int | — | Local outgoing port (for caller mode binding). |

### Payload

| Parameter | Type | Binding | Description |
|-----------|------|---------|-------------|
| `payloadsize` | int (bytes) | PRE | Maximum payload size per packet. In live mode, auto-set from `-chunk` if chunk > `SRT_LIVE_DEF_PLSIZE` (1316). Max is `SRT_LIVE_MAX_PLSIZE` (1456). |
| `messageapi` | bool | PRE | Use message API instead of stream API. |
| `congestion` | string | PRE | Congestion control algorithm: `live` (default for live transtype) or `file`. |

### Advanced

| Parameter | Type | Binding | Description |
|-----------|------|---------|-------------|
| `packetfilter` | string | PRE | Packet filter configuration string (e.g. FEC). |
| `drifttracer` | bool | POST | Enable drift tracer for clock drift compensation. |
| `linger` | int (seconds) | PRE | Socket linger time. `0` = off. Handled specially outside the option loop. |

## Chunk Size

The `-chunk` CLI option controls how many bytes are read from the source in a single `Read()` call. This value is also propagated as the SRT `payloadsize` socket option when in live mode.

**Key constants** (from `srtcore/srt.h`):

| Constant | Value | Meaning |
|----------|-------|---------|
| `SRT_LIVE_DEF_PLSIZE` | 1316 bytes | `188 × 7` — recommended for MPEG-TS (7 TS packets). |
| `SRT_LIVE_MAX_PLSIZE` | 1456 bytes | `MTU(1500) − UDP.hdr(28) − SRT.hdr(16)` — absolute max for live mode. |

**Behaviour**:
- Default chunk size is `SRT_LIVE_MAX_PLSIZE` (1456).
- If `-chunk` is set and > `SRT_LIVE_DEF_PLSIZE` (1316), it is also set as `payloadsize` on the SRT socket.
- If `-chunk` > `SRT_LIVE_MAX_PLSIZE` (1456) in live mode, the process throws an error.
- For MPEG-TS, the idiomatic chunk size is `188 × N` where N ≤ 7 (i.e. max 1316).

## Buffering

The `-buffering` CLI option controls the read loop: on each epoll wake-up, the tool reads up to N packets into a queue before flushing them all to the target. This is **not** an SRT socket buffer — it's an application-level read batch size.

Default is `10` packets. For low-latency use cases, smaller values reduce batching delay at the cost of more write calls.

## Signals

- `SIGINT` / `SIGTERM` → graceful shutdown (the main loop checks `int_state`).
- `SIGALRM` → timeout interrupt (Unix only, when `-timeout` is set).

The process does **not** set up its own SIGPIPE handler.

## Exit Behaviour

- With `-autoreconnect yes` (default): on disconnect, the source/target is destroyed and re-created in the next loop iteration. The process runs indefinitely.
- With `-autoreconnect no`: on disconnect, the main loop breaks and the process exits.
- Stats, if enabled, are written to the stats output on each read cycle (every N packets).
- On `file://con` target, data is written to stdout. On `file://con` source, data is read from stdin.

## Typical Usage Pattern (SRT receive → stdout)

```
srt-live-transmit \
  -autoreconnect no \
  -srctime yes \
  -loglevel warn \
  -chunk:1316 \
  -buffering:10 \
  -stats-report-frequency 100 \
  -pf json \
  "srt://192.168.1.10:9000?mode=caller&latency=350&peerlatency=350&rcvlatency=350&transtype=live&streamid=my-stream&passphrase=secret123" \
  file://con \
  -statsout /dev/stderr
```

This:
1. Connects to an SRT listener at `192.168.1.10:9000` as a caller
2. Requests stream `my-stream` via `streamid`
3. Negotiates 350ms latency in both directions
4. Reads 1316-byte chunks (7 TS packets)
5. Buffers up to 10 packets per read cycle
6. Outputs raw transport stream data to stdout
7. Writes JSON stats to stderr every 100 packets
8. Exits on disconnect (no auto-reconnect)
