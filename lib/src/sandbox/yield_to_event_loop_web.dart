import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';

// Halve the native batch to keep browser task latency near its previous level
// after removing the nested-timer sleep between batches.
const stepsPerEventLoopYield = 4;

final _pending = Queue<Completer<void>>();
final _MessageChannel _channel = _createChannel();

_MessageChannel _createChannel() {
  final channel = _MessageChannel();
  channel.port1.onmessage = ((JSAny? _) {
    _pending.removeFirst().complete();
  }).toJS;
  return channel;
}

// Port messages yield to browser tasks without the nested-timer minimum delay.
// One message per request also keeps concurrent sandboxes independent.
Future<void> yieldToEventLoop() {
  final completer = Completer<void>();
  _pending.addLast(completer);
  _channel.port2.postMessage(null);
  return completer.future;
}

@JS('MessageChannel')
extension type _MessageChannel._(JSObject _) implements JSObject {
  external factory _MessageChannel();
  external _MessagePort get port1;
  external _MessagePort get port2;
}

extension type _MessagePort._(JSObject _) implements JSObject {
  external JSFunction? get onmessage;
  external set onmessage(JSFunction callback);
  external void postMessage(JSAny? message);
}
