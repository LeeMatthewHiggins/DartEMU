# Architecture

How the emulator is put together, what the seams are, and where the
boundaries fall.

- [The shape of the tree](#the-shape-of-the-tree)
- [Layers](#layers)
- [The interfaces](#the-interfaces)
- [The three entry points](#the-three-entry-points)
- [The two facades](#the-two-facades)
- [Where the boundaries are](#where-the-boundaries-are)
- [Following a request out of a browser guest](#following-a-request-out-of-a-browser-guest)
- [Where state lives](#where-state-lives)

## The shape of the tree

Three things, only the first of which is a library:

```
lib/        the emulator, in pure Dart — CPU, MMU, devices, machine,
            plus the Emulator and AgentSandbox facades
agentos/    an agent in C that runs inside a guest, as its only console
example/    a Flutter demo: config picker, terminal, and the proxy that
            gives a browser guest its network
```

The emulator knows nothing about agents. The agent knows nothing about the
emulator — it is an ordinary Linux program that happens to be compiled for
RISC-V. Everything that crosses between them does so through one of the
interfaces below.

## Layers

Bottom to top, each layer depending only on those beneath it.

**CPU** — `lib/src/cpu/`. The interpreter, register file, CSRs, and the
extensions (`M`, `A`, `F`/`D`, `C`). A predecoded instruction cache sits in
front of the decoder; it is the single largest source of throughput, worth
roughly 1.7x on RV64 and 1.9x on RV32.

The register file is where the web split lives. RV64 needs `Int64List`,
which the JavaScript backend cannot allocate, so RV64 runs only under
WasmGC. RV32 uses `Uint32List` and runs anywhere.

**Memory and MMU** — `lib/src/cpu/mmu.dart`, `lib/src/machine/`. SV39 on
RV64 and SV32 on RV32, with a hardware page-table walk and a TLB. Physical
memory is a map of ranges; a range is either RAM or a device with read and
write callbacks, which is how MMIO is dispatched without a special case in
the CPU.

**Devices** — `lib/src/device/`. VirtIO MMIO transport with console, block,
network and 9P devices on top of it, plus CLINT (timers and software
interrupts), PLIC (external interrupt routing) and HTIF. Each device is
reached through an interface rather than a concrete class, which is what
lets the same machine run against a file on disk, a byte array in memory, or
a directory handle from a browser.

**Machine** — `lib/src/machine/riscv_machine.dart`. Assembles a CPU, a
memory map and a set of devices from a `MachineConfig`, builds the device
tree the kernel reads, and can act as machine-mode firmware itself by
answering SBI calls directly (see [Building a modern
kernel](images.md#building-a-modern-kernel)).

**Facades** — `Emulator` for lifecycle and streams, `AgentSandbox` for
running commands. Most embedders should never reach below these.

## The interfaces

These are the seams. Each exists so the core can run unchanged on a server,
a desktop, a phone and a browser.

### Devices

```dart
abstract class BlockDevice {          // disks
  int get sectorCount;
  void readSectors(int sectorNum, Uint8List buffer, int count);
  void writeSectors(int sectorNum, Uint8List buffer, int count);
  static const sectorSize = 512;
}

abstract class CharacterDevice {      // consoles
  void writeData(Uint8List data);
  Uint8List readData(int maxLength);
}

abstract class EthernetDevice {       // NICs
  Uint8List get macAddress;
  void writePacket(Uint8List data);   // guest → wire
  Uint8List? readPacket();            // wire → guest
  bool canDeviceWritePacket();
  void deviceWritePacket(Uint8List data);
  void setCarrier({required bool state});
  void poll();
}
```

Implementations choose the platform. `MemoryBlockDevice` holds bytes and
works anywhere; `FileBlockDevice` needs `dart:io` and so lives behind the
`dart_emu_io` entry point.

### Filesystems

`NinePBackend` is the entire host side of a 9P share, so a share can be a
real directory, an in-memory tree, or a folder the user picked in a browser:

```dart
abstract class NinePBackend {
  NinePStat? stat(String path);
  List<NinePStat> readdir(String path);
  Uint8List read(String path, int offset, int count);
  int write(String path, int offset, Uint8List data);
  NinePStat create(String parent, String name,
      {required bool isDir, required int permBits});
  void remove(String path);
  void setLength(String path, int length);
  void setMtime(String path, int mtimeSeconds);
}
```

See [Filesystems and shares](filesystems.md).

### Network

The most load-bearing seam, because a server and a browser have nothing in
common here:

```dart
abstract class NetBackend {
  TcpConnectionHandle? openTcpConnection(Uint8List destIp, int destPort);
  void sendUdpDatagram(Uint8List destIp, int destPort, Uint8List data,
      DataCallback onResponse);
  List<Uint8List>? resolveDns(String hostname);
  void poll();
  void dispose();
}

abstract class TcpConnectionHandle {
  void send(Uint8List data);
  Uint8List? receive();
  bool get isConnected;
  bool get hasData;
  bool get isRemoteClosed;
  void close();
}
```

`UserNetDevice` implements the guest-facing TCP/IP stack — ARP, IPv4, ICMP,
DHCP, DNS, TCP and UDP — and delegates everything outbound to a backend.
Returning `null` is meaningful in both cases: from `openTcpConnection` it
produces a RST the guest sees as *connection refused*, and from `resolveDns`
it produces NXDOMAIN.

On the web that is the whole enforcement mechanism. See
[Networking](networking.md).

### Internal seams

Only relevant if you are extending the emulator itself: `RiscVCpuState`,
`Mmu`, `MExtension`, `VirtioDevice`, `NinePWriteSink`, and the callback
typedefs (`SetIrqCallback`, `DeviceReadFunc`, `DeviceWriteFunc`,
`DnsLookupCallback`, `PowerDownCallback`).

## The three entry points

The split is enforced by imports, not convention — the core has no
`dart:io`, which is why it runs in a browser at all.

| Import | Holds | Use when |
| --- | --- | --- |
| `package:dart_emu/dart_emu.dart` | `Emulator`, `MachineConfig`, `AgentSandbox`, devices, `ConfigDocument`, `NetBackend`, `HttpProxy` | anywhere, including web |
| `package:dart_emu/dart_emu_io.dart` | `FileBlockDevice`, `ConfigLoader`, `ConfigResolver`, directory 9P backend | server, desktop, CLI |
| `package:dart_emu/dart_emu_web.dart` | folder picker, `WebNetBackend` | browser |

## The two facades

**`Emulator`** is lifecycle and streams:

```dart
final emulator = Emulator(config);
emulator.output.listen(...);   // console bytes out
emulator.status.listen(...);   // idle → starting → running → stopped
emulator.sendInput(bytes);     // console bytes in
await emulator.start();        // or stepFor(micros) to drive it yourself
await emulator.dispose();
```

`stepFor` matters in Flutter: a browser clamps `Future.delayed`, so the demo
drives the emulator from a `Ticker`, one frame's budget per frame, rather
than letting it run free.

**`AgentSandbox`** treats a machine as a unit of work — boot, run commands
under budgets, exchange files, snapshot. See [Agents](agents.md).

## Where the boundaries are

Worth being exact about, because it is the design rather than a detail.

**The emulator is the security boundary.** Nothing filters what a guest may
run. `rm -rf /` executes, and a test asserts that it does. The guest never
executes a host instruction, so containment is a property of emulation
rather than of any check.

**The host is the network boundary.** A guest reaches exactly the
destinations its backend allows. On native that is real sockets; in a
browser it is a fixed list of upstreams over HTTP.

**The page is the credential boundary.** Keys live on the host and are
attached to requests on their way out. The guest image carries a placeholder
naming the credential, and has no field able to hold the credential itself.

Bounds that exist *inside* a guest — output caps, command timeouts — protect
the machine from itself. They are not a security control, and a rooted guest
can remove its own.

## Following a request out of a browser guest

The path that is hardest to reconstruct from the source, end to end:

```
in-guest agent            socket() → connect(10.0.2.2:80) → write(HTTP)
  ↓
UserNetDevice             ARP, IPv4, TCP handshake, reassembly
  ↓
WebNetBackend             port 80 only; anything else returns null → RST
  ↓
GuestRequestParser        buffers until Content-Length is satisfied
  ↓
HttpProxy.resolve()       Host header → configured upstream, or 502
                          ${OPENROUTER_KEY} → the real key
                          rejects header values a browser cannot send
  ↓
fetchTransport            the only web-specific code: dart:js_interop fetch
  ↓
renderResponse()          back to HTTP/1.1 bytes, Content-Length rewritten
  ↓
UserNetDevice             segmented back to the guest, then FIN
```

Two details in there are load-bearing and were each a bug first. DNS
resolves an allowed name to the **gateway**, not loopback — a guest
connecting to loopback answers itself and the packet never leaves. And the
upstream's path is **appended** to, not replaced by, the guest's: `Uri.resolve`
would send `/v1/chat/completions` to the site root.

## Where state lives

A snapshot has to capture all of this, which is a good way to enumerate it:

- CPU registers, CSRs, and the current privilege level
- All of guest RAM
- The disk, as a byte array
- Device state — VirtIO queues, CLINT/PLIC registers, console buffers
- Timers, restored relative to a coherent clock rather than jumping

What a snapshot deliberately does *not* capture is anything on the host: an
open file handle, a socket, or a credential. That is what makes a restored
guest independent of the one it came from, and why one snapshot can seed any
number of clones.
