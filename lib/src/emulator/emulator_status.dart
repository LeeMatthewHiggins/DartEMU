/// Lifecycle states of an `Emulator` instance.
enum EmulatorStatus {
  /// Constructed but not yet started.
  idle,

  /// Machine created, loading images and initialising devices.
  starting,

  /// Emulation loop is active.
  running,

  /// Machine shut down (guest power-off or `Emulator.stop` called).
  stopped,

  /// A fatal error occurred. See `Emulator.lastError` for details.
  error,
}
