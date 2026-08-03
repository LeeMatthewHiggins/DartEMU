# Networking

How a guest reaches the outside, and how much outside it gets.

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

Nothing above the device driver in the guest knows any of this is simulated.
`ping`, `curl` and a resolver behave normally, within the limits of whatever
backend is underneath.

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

Returning `null` is how a backend says no, and it says it in the guest's own
vocabulary: `null` from `openTcpConnection` becomes a RST, which the guest
reports as *connection refused*; `null` from `resolveDns` becomes NXDOMAIN.
A refusal is therefore indistinguishable from an ordinary network failure,
which is what you want — there is nothing to detect and route around.

## Native

`createDefaultNetBackend()` gives real sockets. A guest gets what the host
has, and the emulator imposes nothing. If you want it constrained, supply
your own backend:

```dart
UserNetDevice(backend: MyFilteringBackend())
```

That is the intended extension point for an allow-list on a server. The
guest cannot tell the difference between a host you refused to connect to
and one that is down.

## In a browser

A browser has no raw sockets. It has `fetch`, and `fetch` owns the TLS — so
a guest **cannot** speak HTTPS through it: the guest would have to hold the
certificate and do the handshake, and the browser will not carry the result.

So the guest speaks plain HTTP to a named upstream, and the page reissues
the request over TLS:

```dart
UserNetDevice(
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
)
```

That limitation turns out to be the feature. Since every request already has
to pass through host code to reach the network at all, that code is the
natural place to decide *which* requests exist and *what* they carry.

`WebNetBackend` enforces exactly two things:

- `resolveDns` answers only for a configured upstream. Everything else
  fails to resolve.
- `openTcpConnection` accepts only port 80. Everything else is refused.

An allowed name resolves to the **gateway**, not loopback — a guest
connecting to loopback would answer itself and the packet would never leave
its own stack. Routing to the real endpoint happens on the `Host` header,
not the address.

## Credential injection

The guest is built with a placeholder naming the credential it needs, never
the credential:

```
guest writes:   Authorization: Bearer ${OPENROUTER_KEY}
host resolves:  Authorization: Bearer sk-real-…
```

`HttpProxy` substitutes `${NAME}` from a `CredentialStore` held on the host.
Two tests state the property directly: one asserts the real key appears in
the outbound request, the other asserts the guest's own bytes contain only
the placeholder and never `sk-`.

The proxy also refuses a value a browser cannot actually send. An HTTP
header carries bytes, so a character above `U+00FF` has no representation in
one — and a key copied out of a rendered page can pick up a non-breaking
space or a zero-width character while looking identical to a clean one.
`fetch` answers that with a `TypeError` naming neither the header nor the
value, so the proxy checks first and refuses with the header, the code point
and the position. It refuses rather than repairs: quietly altering a
credential would turn one confusing failure into a worse one.

## Failing usefully

A guest that is refused must not meet a dead socket. Every refusal comes
back as a real HTTP response with a JSON body:

```
HTTP/1.1 401 Unauthorized
{"error":{"message":"No credential is configured for OPENROUTER_KEY.
  Enter a key on the page to continue; this machine never holds one itself.",
  "type":"dartemu_proxy"}}
```

An agent reads that like any other API error. The `type` field marks it as
the proxy's own, which matters more than it looks: a refusal from the host
and a refusal from the API beyond it arrive in the same shape and read
identically, and every layer in the chain can answer 401. Without the mark,
a message like *"Missing Authentication header"* sends you looking at the
wrong layer.

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
| ping, UDP, raw sockets | nothing |

Widening it means adding entries to `upstreams`, each with its own injected
headers. Note that a destination must also permit cross-origin requests:
most package mirrors send no CORS headers, so `apk add` cannot work from a
browser even if the mirror is allow-listed. On native that constraint
disappears, because there the backend opens real sockets.

## Testing it

Parsing, policy and injection are plain Dart behind an injectable transport:

```dart
typedef ProxyTransport = Future<ProxyResponse> Function(ProxyRequest request);
```

`fetchTransport` on the web, a fake in tests. That is why the proxy has unit
tests rather than a manual browser check — only `web_fetch.dart` is
genuinely web-specific, and it has its own tests that run in real Chrome via
`dart test -p chrome test/net`, which CI runs as a separate job.
