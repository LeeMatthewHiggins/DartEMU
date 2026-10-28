# Networking

Guest networking and backend access controls.

- [The stack](#the-stack)
- [The backend seam](#the-backend-seam)
- [Native](#native)
- [In a browser](#in-a-browser)
- [Credential injection](#credential-injection)
- [Failing usefully](#failing-usefully)
- [What a guest can and cannot reach](#what-a-guest-can-and-cannot-reach)
- [Testing it](#testing-it)

## The stack

`UserNetDevice` is a user-mode TCP/IP implementation: the guest sees an
ordinary VirtIO NIC, and the host answers as though it were a network. It
handles ARP, IPv4, ICMP, DHCP, DNS, TCP and UDP.

The virtual network is the familiar user-mode layout:

| Address | Role |
| --- | --- |
| `10.0.2.15` | the guest |
| `10.0.2.2` | the gateway — where the host answers |
| `10.0.2.3` | the DNS server |

The guest uses its ordinary network tools, within the backend's limits.
ICMP echo replies are synthesized locally: a successful `ping` demonstrates
the virtual stack, not connectivity to the destination.

## The backend seam

Everything the stack cannot answer itself goes to a `NetBackend`:

```dart
abstract class NetBackend {
  TcpConnectionHandle? openTcpConnection(Uint8List destIp, int destPort);
  void sendUdpDatagram(Uint8List destIp, int destPort, Uint8List data,
      DataCallback onResponse);
  List<Uint8List>? resolveDns(String hostname);
  void poll();
  void dispose();
}
```

Returning `null` from `openTcpConnection` becomes a TCP RST, usually shown
as *connection refused*. `resolveDns` returns `null` for pending or failed
lookups. The stack retries those queries and eventually drops them without
a reply; the guest may wait for a DNS timeout rather than receive NXDOMAIN.

## Native

`createDefaultNetBackend()` uses host TCP/UDP sockets and IPv4 DNS. These
outbound connections have the host process's network access. It does not
provide inbound port forwarding or a full raw-socket tunnel. To constrain
outbound access, supply your own backend:

```dart
import 'package:dart_emu/dart_emu.dart';

final network = UserNetDevice(backend: MyFilteringBackend());
```

That is the intended extension point for an allow-list on a server. The
guest cannot tell the difference between a host you refused to connect to
and one that is down.

## In a browser

The browser backend uses `fetch`, which accepts HTTP requests rather than
arbitrary TCP bytes. It therefore cannot carry a guest's TLS handshake or
provide a general HTTPS socket. The browser performs TLS for the configured
upstream instead.

So the guest speaks plain HTTP to a named upstream, and the page reissues
the request over TLS:

```dart
import 'package:dart_emu/dart_emu_web.dart';

final network = UserNetDevice(
  backend: WebNetBackend(
    upstreams: [
      Upstream(
        host: 'llm.local',
        target: Uri.parse('https://openrouter.ai/api'),
        injectHeaders: {'authorization': r'Bearer ${OPENROUTER_KEY}'},
      ),
    ],
    credentials: CredentialStore({'OPENROUTER_KEY': key}),
  ),
);
```

`WebNetBackend` and `HttpProxy` restrict requests in three places:

- `resolveDns` answers only for a configured upstream. Everything else
  fails to resolve.
- `openTcpConnection` accepts only port 80. Everything else is refused.
- `HttpProxy` requires a configured HTTP Host header before dispatching the
  request, including when the guest connects directly to an IP address.

An allowed name resolves to the **gateway**, not loopback — a guest
connecting to loopback would answer itself and the packet would never leave
its own stack. Routing to the real endpoint happens on the `Host` header,
not the address.

## Credential injection

The supplied AgentOS image uses a placeholder naming the credential it
needs. The host proxy injects the configured authorization header:

```
guest writes:   Authorization: Bearer ${OPENROUTER_KEY}
host resolves:  Authorization: Bearer sk-real-…
```

`HttpProxy` substitutes `${NAME}` in configured `Upstream.injectHeaders`
from a `CredentialStore` held on the host. It does not substitute arbitrary
guest-supplied headers.
Two tests state the property directly: one asserts the real key appears in
the outbound request, the other asserts the guest's own bytes contain only
the placeholder and never `sk-`.

The proxy also refuses a value a browser cannot actually send. An HTTP
header carries bytes, so a character above `U+00FF` has no representation in
one — and a key copied out of a rendered page can pick up a non-breaking
space or a zero-width character while looking identical to a clean one.
`fetch` answers that with a `TypeError` naming neither the header nor the
value, so the proxy checks first and refuses with the header, the code point
and the position. It reports invalid values without changing the credential.

## Failing usefully

HTTP proxy refusals, such as a missing configured credential, return an
HTTP response with a JSON body. Port refusals and DNS failures happen below
HTTP and follow the behavior described above:

```
HTTP/1.1 401 Unauthorized
{"error":{"message":"No credential is configured for OPENROUTER_KEY.
  Enter a key on the page to continue; this machine never holds one itself.",
  "type":"dartemu_proxy"}}
```

The `type` field distinguishes proxy errors from upstream API errors,
which can also return 401 with a message such as "Missing Authentication
header".

Response framing is rewritten rather than echoed. An upstream
`Content-Length` that disagreed with the body actually forwarded would
desync the guest's HTTP parser — a bug that presents as a hung agent.

## What a guest can and cannot reach

In a browser, with the configuration above:

| The guest tries | Result |
| --- | --- |
| `llm.local:80` | proxied to the upstream, credential attached |
| `llm.local:443` | refused — only port 80 |
| `github.com` | does not resolve |
| `apk add …` | fails; the mirror is not an upstream |
| ping by IP | synthetic local echo; does not test external connectivity |
| outbound UDP other than local DHCP/DNS | not forwarded |
| arbitrary TCP protocols / guest TLS | unsupported |

The ordinary RV32/RV64 browser demos configure no upstreams, so they do
not provide general Internet access. The AgentOS demo configures its model
provider upstream. Widening access in your app means adding entries to
`upstreams`, each with its own injected headers. Note that a destination must also permit cross-origin requests:
most package mirrors send no CORS headers, so `apk add` cannot work from a
browser even if the mirror is allow-listed. On native that constraint
disappears, because there the backend opens real sockets.

## Testing it

Parsing, policy and injection are plain Dart behind an injectable transport:

```dart
typedef ProxyTransport = Future<ProxyResponse> Function(ProxyRequest request);
```

`fetchTransport` on the web, a fake in tests. That is why the proxy has unit
tests as well as a browser transport check. `web_fetch.dart` calls browser
APIs and has tests that run in real Chrome via
`dart test -p chrome test/net`, which CI runs as a separate job.
