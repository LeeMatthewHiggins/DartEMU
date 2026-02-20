import 'dart:ui' as ui;

import 'package:dart_emu_example/src/crt/crt_effect.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Wraps a child widget and applies a CRT fragment shader effect.
///
/// Captures the child's rendered output to an offscreen image each frame,
/// then draws that image through the CRT shader.
class CrtEffectWidget extends SingleChildRenderObjectWidget {
  /// Creates a CRT effect wrapper.
  const CrtEffectWidget({
    required this.effect,
    this.shader,
    super.child,
    super.key,
  });

  /// The compiled CRT fragment shader, or null if not yet loaded.
  final ui.FragmentShader? shader;

  /// The active CRT effect mode.
  final CrtEffect effect;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderCrtEffect(shader: shader, effect: effect);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderCrtEffect renderObject,
  ) {
    renderObject
      ..shader = shader
      ..effect = effect;
  }
}

/// Subclass to access the protected [stopRecordingIfNeeded] method.
class _CapturePaintingContext extends PaintingContext {
  _CapturePaintingContext(super.containerLayer, super.estimatedBounds);

  void finalize() {
    stopRecordingIfNeeded();
  }
}

class _RenderCrtEffect extends RenderProxyBox {
  _RenderCrtEffect({
    ui.FragmentShader? shader,
    CrtEffect effect = CrtEffect.none,
  })  : _shader = shader,
        _effect = effect;

  ui.FragmentShader? _shader;
  CrtEffect _effect;

  set shader(ui.FragmentShader? value) {
    if (_shader == value) return;
    _shader = value;
    markNeedsPaint();
  }

  set effect(CrtEffect value) {
    if (_effect == value) return;
    _effect = value;
    markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => _isActive;

  bool get _isActive => _effect != CrtEffect.none && _shader != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || !_isActive) {
      super.paint(context, offset);
      return;
    }

    final childLayer = OffsetLayer();
    final childContext = _CapturePaintingContext(
      childLayer,
      Offset.zero & size,
    );
    super.paint(childContext, Offset.zero);
    childContext.finalize();

    final image = childLayer.toImageSync(Offset.zero & size);

    final shader = _shader!;
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, _effect.mode.toDouble())
      ..setImageSampler(0, image);

    context.canvas.drawRect(
      offset & size,
      Paint()..shader = shader,
    );

    image.dispose();
  }
}
