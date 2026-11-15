# Running the Flexicast QUIC Receiver Natively on macOS (No Docker)

This guide explains how to build and run the Flexicast QUIC heartbeat receiver (`tfc-receiver`) natively on macOS (`arm64`) without Docker—for example, from a laptop at a meeting venue.

The receiver connects over QUIC to the demo `PING` source (`193.191.171.131:4433`, multicast group `239.239.239.35:4434`), joins the advertised IPv4 multicast group, and automatically falls back to **AMT (RFC 7450)** via the GEANT anycast relay (`62.40.96.44:2268`) if native multicast packets do not arrive.

> **Note on port `4435` (`FC_PING`):** The live demo also runs an `FC_PING` source on `193.191.171.131:4435` (`239.239.239.36:4434`), which requires the `fcping` branch/Docker container (`flexicast-quic` `per-uc-path-cca` does not support the extended `MC_ANNOUNCE` / `FC_PING` frames on `:4435`). Native macOS builds from `per-uc-path-cca` must connect to `:4433` (the default in `run_receiver_macos.sh`).

---

## 1. Prerequisites & Network Requirements

### Software
- macOS on Apple Silicon (`arm64` tested)
- Xcode Command Line Tools (`cc`, `ar`, `make`, `git`): `xcode-select --install`
- `cmake` (required to build BoringSSL, e.g., `brew install cmake`)
- Rust toolchain (`cargo` / `rustc`, e.g., via `rustup`)

### Venue Network Connectivity
- **Outbound UDP to the source:** `193.191.171.131:4433` (`PING` source, default for `per-uc-path-cca`)
- **Outbound UDP to the GEANT AMT relay:** `62.40.96.44:2268` (used automatically when the venue network does not deliver native multicast)
- **Outbound TCP for optional QLOG upload:** `193.191.171.131:8080` (`http://193.191.171.131:8080/qlog/`)

> **Venue Wi-Fi note:** Some university, corporate, or conference networks block outbound QUIC or AMT UDP traffic (`4433` or `2268`). If handshakes time out or AMT discovery receives no response on the venue network, test from a mobile hotspot or residential network.

---

## 2. Building `tfc-receiver` from Source

The workspace layout places `libamt`, `flexicast-quic`, and `multicast-ietf127-demo` side by side in the same parent directory (e.g., `/Users/dikshie/VIRTUAL/`):

```text
<parent>/
├── libamt/
├── flexicast-quic/
└── multicast-ietf127-demo/
```

### Step 1: Build `libamt`
```bash
git clone https://github.com/IPNetworkingLab/libamt.git
cd libamt
make
cd ..
```
This produces `libamt/libamt.a`. (If you keep `libamt` elsewhere, set `LIBAMT_DIR=/path/to/libamt` before running `cargo build`.)

### Step 2: Clone `flexicast-quic` and Initialize the BoringSSL Submodule
`fcquic-beacon/Cargo.toml` depends on `../../flexicast-quic/{tokio-fcquiche,tokio-quiche,quiche}` (`per-uc-path-cca` branch):

```bash
git clone -b per-uc-path-cca https://github.com/IPNetworkingLab/flexicast-quic.git
cd flexicast-quic
git submodule update --init --depth 1 quiche/deps/boringssl
cd ..
```

### Step 3: Build `tfc-receiver`
Build only the receiver binary in release mode:

```bash
cd multicast-ietf127-demo/fcquic-beacon
cargo build --release --bin tfc-receiver
```

The compiled binary is at:
```text
fcquic-beacon/target/release/tfc-receiver
```

Verify it runs natively:
```bash
./target/release/tfc-receiver --help
```

---

## 3. Running the Receiver

Use [`run_receiver_macos.sh`](file:///Users/dikshie/VIRTUAL/multicast-ietf127-demo/run_receiver_macos.sh) from the `multicast-ietf127-demo` directory.

### Quick Start (Live Demo)
Connect to the `PING` source (`193.191.171.131:4433`) with AMT fallback enabled via `62.40.96.44`:
```bash
./run_receiver_macos.sh
```

### Common Options & Environment Overrides
```bash
# Increase log verbosity (e.g. info or debug)
RUST_LOG=info ./run_receiver_macos.sh

# Disable pretty-printing and pass extra tfc-receiver flags
./run_receiver_macos.sh --pretty-print false

# Override source IP and client ID (matching Docker entrypoint positional args)
./run_receiver_macos.sh 193.191.171.131 2 --amt-fallback-delay 1000

# Test native multicast only (disable AMT fallback)
AMT_FALLBACK=0 ./run_receiver_macos.sh

# Disable QLOG collection or skip QLOG upload (see Section 5)
QLOGDIR="" ./run_receiver_macos.sh
QLOG_UPLOAD_URL="" ./run_receiver_macos.sh
```

Supported environment variables for `run_receiver_macos.sh`:
- `SRC_IP` (default: `193.191.171.131`)
- `SRC_PORT` (default: `4433`, `PING` source; `4435` is only for `fcping`-compatible builds)
- `ID` (default: `1`; used in `./out/client<ID>/qlogs`)
- `LOCAL_IP` (default: `0.0.0.0`)
- `AMT_FALLBACK` (default: `1`; set `0` to omit `--amt-fallback`)
- `AMT_RELAY` (default: `62.40.96.44`)
- `AMT_FALLBACK_DELAY` (default: `750` ms)
- `RUST_LOG` (default: `warn,tfc_receiver=info,tokio_fcquiche=info`)
- `QLOGDIR` (default: `./out/client<ID>/qlogs`; set empty `""` to disable)
- `QLOG_UPLOAD_URL` (default: `http://<SRC_IP>:8080/qlog`; set empty `""` to skip upload)
- `TFC_RECEIVER` (default: `./fcquic-beacon/target/release/tfc-receiver`)

### Running `tfc-receiver` Directly
```bash
RUST_LOG=warn,tfc_receiver=info,tokio_fcquiche=info \
  ./fcquic-beacon/target/release/tfc-receiver \
  https://193.191.171.131:4433/heartbeat \
  -l 0.0.0.0 --flexicast --amt-fallback --amt-relay 62.40.96.44
```

### Supported CLI Flags (`tfc-receiver --help`)
- `<URL>`: Server URL to contact (e.g. `https://193.191.171.131:4433/heartbeat`)
- `--flexicast`: Activate the Flexicast QUIC extension
- `-l, --local <LOCAL_IP>`: Multicast local IP (default: `0.0.0.0`)
- `--proxy`: Listen on own address/port for replicated unicast proxy mode
- `--flow-control <INITIAL_FLOW_CONTROL>`: Initial flow control limit (unlimited if unset)
- `--amt-fallback`: Allow AMT fallback when native multicast packets do not arrive
- `--amt-relay <AMT_RELAY_IP>`: AMT relay IPv4 address (e.g. `62.40.96.44`)
- `--amt-fallback-delay <AMT_FALLBACK_DELAY>`: Delay in ms without native multicast packets before falling back to AMT (default: `750`)
- `--verify-hash <true|false>`: Verify SHA-256 hash of heartbeat payloads (default: `true`)
- `--pretty-print <true|false>`: Parse and pretty-print JSON heartbeats (default: `true`)
- `-h, --help`: Print CLI help

---

## 4. What to Expect & How to Verify Multicast vs. AMT

### Heartbeat Behavior
- You should start receiving heartbeats within a few seconds.
- Each heartbeat is a JSON message carrying `beacon`, `session_id`, `seqnum`, `sent_at_ms`, `interval_ms`, `uptime_s`, and optional `payload` metadata.
- Heartbeats are transmitted every **4 seconds**. Periodically (every 5th heartbeat on the live demo per the receiver guide, or every 10th depending on source configuration), a heartbeat also includes a random binary payload along with its SHA-256 hash, which `tfc-receiver` checks when `--verify-hash true` is active.

### Verifying Native Multicast vs. AMT Fallback
With the default `RUST_LOG=warn,tfc_receiver=info,tokio_fcquiche=info` (or `RUST_LOG=info`), look for these log lines:

1. **Multicast group join:**
   ```text
   Join MULTICAST 239.239.239.35
   ```

2. **If native multicast works at the venue:**
   Heartbeats are printed and you will **not** see AMT fallback lines.

3. **If native multicast does not arrive (AMT fallback):**
   After `--amt-fallback-delay` (`750` ms by default), the receiver logs:
   ```text
   No native multicast packets received within 750ms; falling back to AMT relay 62.40.96.44 for group ...
   AMT tunnel established via relay 62.40.96.44 for (...)
   Left MULTICAST group 239.239.239.35
   Left multicast group after creating AMT gateway
   ```

### Stopping Cleanly
Press `Ctrl-C` once to stop the receiver gracefully. It closes the QUIC connection, prints `Closing connection at ...`, goodput statistics (`RESULT-GOODPUT-PAYLOAD-*`, when payload data was received) and `Client disconnected.`, flushes any QLOG files, and (if enabled) compresses and uploads them. Press `Ctrl-C` a second time only if you need to force-exit immediately.

---

## 5. Data Collection & QLOG Privacy

By default, `run_receiver_macos.sh` collects transport-level QLOG traces in `./out/client<ID>/qlogs/` and uploads compressed `.sqlog.gz` files to `http://<SRC_IP>:8080/qlog/` when the receiver stops.

If QLOG upload is enabled, the demo server collects:
- **Non-anonymized IP address**
- **Complete session logs** (QLOGs include all packets sent and received by the client at the transport level)
- **AMT and unicast fallback events**
- **Retransmissions** and transport metrics

This information is used solely for research purposes to improve the Flexicast QUIC implementation, diagnose issues, and gather insights from real-world deployments.

To opt out or keep logs local:
- **Disable QLOG collection completely:**
  ```bash
  QLOGDIR="" ./run_receiver_macos.sh
  ```
- **Keep QLOG files locally without uploading:**
  ```bash
  QLOG_UPLOAD_URL="" ./run_receiver_macos.sh
  ```

---

## 6. Notes on macOS Differences from the Linux Scripts

Unlike [`containers/fcquic-beacon-receiver/entrypoint.sh`](file:///Users/dikshie/VIRTUAL/multicast-ietf127-demo/containers/fcquic-beacon-receiver/entrypoint.sh) and [`fcquic-beacon/run_tfc_receiver.sh`](file:///Users/dikshie/VIRTUAL/multicast-ietf127-demo/fcquic-beacon/run_tfc_receiver.sh), `run_receiver_macos.sh`:
- Omits `ip netns exec` (Linux network namespaces are not present on macOS; runs directly on the host network stack).
- Omits `setsid` and GNU `env --default-signal=INT` (unsupported by macOS BSD `env`; uses standard `env` and a bash `INT`/`TERM` trap that forwards `SIGINT` to `tfc-receiver` and waits for clean QLOG flush).
- Uses a writable local `./out/client<ID>/qlogs` directory instead of `/bin-fcquic-client$ID/qlogs`.
