/// CRT display effect modes applied via the fragment shader.
enum CrtEffect {
  none(0, 'Off'),
  full(1, 'Full CRT'),
  flat(2, 'Flat CRT'),
  glass(3, 'Cheap TV');

  const CrtEffect(this.mode, this.label);

  final int mode;
  final String label;

  CrtEffect next() {
    final nextIndex = (index + 1) % CrtEffect.values.length;
    return CrtEffect.values[nextIndex];
  }
}
