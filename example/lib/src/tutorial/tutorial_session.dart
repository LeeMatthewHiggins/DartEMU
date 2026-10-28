/// Coordinates the tutorial's fixed examples with an idle guest shell.
///
/// The browser adapter verifies message origin and source before calling
/// [receiveMessage]. Arbitrary command text is never accepted from messages.
class TutorialSession {
  /// Creates a session for the bundled Linux shell.
  TutorialSession({
    required void Function(String) sendInput,
    required void Function(Map<String, String>) postMessage,
    void Function()? onDispose,
  }) : _sendInput = sendInput,
       _postMessage = postMessage,
       _onDispose = onDispose;

  final void Function(String) _sendInput;
  final void Function(Map<String, String>) _postMessage;
  final void Function()? _onDispose;
  var _tail = '';
  var _ready = false;
  var _disposed = false;
  String? _runningId;

  /// The only commands the surrounding tutorial is allowed to run.
  static const commands = <String, String>{
    'inspect': 'uname -m; cat /proc/cpuinfo',
    'files':
        r"mkdir -p /tmp/tutorial; printf '%s\n' 'roof 18' 'garden 24' "
        "'attic 31' 'cellar 16' > /tmp/tutorial/weather.txt; cat "
        '/tmp/tutorial/weather.txt',
    'pipeline':
        r"printf '%s\n' 'roof 18' 'garden 24' 'attic 31' 'cellar 16' | sort "
        '-r -k2 | head -n 2',
    'chart':
        r"printf '%s\n' 'roof 18' 'garden 24' 'attic 31' 'cellar 16' | "
        r"""while read place temp; do printf '%-7s ' "$place"; i=0; while [ """
        r""""$i" -lt "$temp" ]; do printf '#'; i=$((i + 1)); done; echo " """
        r'$temp C"; done',
    'script':
        r'limit=16; y=-8; while [ "$y" -le 8 ]; do row=; x=-30; while [ '
        r'"$x" -le 10 ]; do a=0; b=0; n=0; while [ "$((a*a+b*b))" -le 40000 '
        r'] && [ "$n" -lt "$limit" ]; do t=$(((a*a-b*b)/100+x*7)); '
        r'b=$((2*a*b/100+y*14)); a=$t; n=$((n+1)); done; case $n in '
        r""""$limit") p=@;; [0-2]) p=' ';; [3-5]) p=.;; [6-9]) p='*';; *) """
        r"""p=+;; esac; row="$row$p"; x=$((x+1)); done; printf '%s\n' "$row"; """
        r'y=$((y+1)); done',
  };

  /// Runs a known example only when the shell is ready for a new command.
  void receiveMessage(Object? message) {
    if (_disposed || !_ready || _runningId != null || message is! Map) return;
    if (message['type'] != 'dartemu:run') return;
    final id = message['id'];
    if (id is! String) return;
    final command = commands[id];
    if (command == null) return;
    _ready = false;
    _tail = '';
    _runningId = id;
    _postMessage({'type': 'dartemu:running', 'id': id});
    _sendInput('$command\n');
  }

  /// Watches output for the bundled root shell's prompt, including chunks
  /// that split a prompt between two output events.
  void receiveOutput(String chunk) {
    if (_disposed) return;
    _tail += chunk;
    if (_tail.length > _tailLimit) {
      _tail = _tail.substring(_tail.length - _tailLimit);
    }
    final plain = _tail.replaceAll(_ansiEscape, '');
    if (!_prompt.hasMatch(plain) || _ready) return;
    _ready = true;
    final id = _runningId;
    _runningId = null;
    if (id == null) {
      _postMessage({'type': 'dartemu:ready'});
    } else {
      _postMessage({'type': 'dartemu:complete', 'id': id});
    }
  }

  /// Prevents examples from being appended to a partially typed command or
  /// sent to a program the user has started manually.
  void receiveUserInput(String input) {
    if (_disposed || input.isEmpty) return;
    _ready = false;
    _tail = '';
  }

  /// Reports an unusable emulator and stops accepting tutorial requests.
  void fail(String message) {
    if (_disposed) return;
    _postMessage({'type': 'dartemu:error', 'message': message});
    dispose();
  }

  /// Releases the browser listener, if one is attached.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _onDispose?.call();
  }

  static const _tailLimit = 256;
  static final _ansiEscape = RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]');
  // BusyBox shows the working directory before its root prompt. A hash bar
  // followed by a space is ordinary output, even if a chunk ends there.
  static final _prompt = RegExp(
    r'(?:^|[\r\n])(?:~(?:/[^\r\n]*)?|/[^\r\n]*) # $',
  );
}
