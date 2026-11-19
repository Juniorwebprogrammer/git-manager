import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/settings/app_settings.dart';

/// Tamaño de letra y ajuste de líneas para los visores de código (diff,
/// fichero, blame). Se toma de los ajustes de la app.
class CodeViewStyle extends InheritedWidget {
  final double fontSize;
  final bool wrap;

  const CodeViewStyle({super.key, required this.fontSize, required this.wrap, required super.child});

  static ({double fontSize, bool wrap}) of(BuildContext context) {
    final style = context.dependOnInheritedWidgetOfExactType<CodeViewStyle>();
    return (fontSize: style?.fontSize ?? 12.5, wrap: style?.wrap ?? true);
  }

  @override
  bool updateShouldNotify(CodeViewStyle old) => old.fontSize != fontSize || old.wrap != wrap;
}

/// Envuelve [child] con el estilo de código de los ajustes actuales.
class CodeViewStyleScope extends ConsumerWidget {
  final Widget child;

  const CodeViewStyleScope({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return CodeViewStyle(fontSize: settings.diffFontSize, wrap: settings.wrapLines, child: child);
  }
}

/// Sin ajuste de líneas: el contenido se desplaza en horizontal. El ancho
/// se estima a partir de la línea más larga.
class HorizontalCodeScroll extends StatefulWidget {
  final int maxChars;
  final double fontSize;
  final double gutterWidth;
  final Widget child;

  const HorizontalCodeScroll({
    super.key,
    required this.maxChars,
    required this.fontSize,
    required this.gutterWidth,
    required this.child,
  });

  /// Longitud "visual" de una línea (tabuladores = 4).
  static int visualLength(String line) => line.length + 3 * '\t'.allMatches(line).length;

  @override
  State<HorizontalCodeScroll> createState() => _HorizontalCodeScrollState();
}

class _HorizontalCodeScrollState extends State<HorizontalCodeScroll> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final width = math.max(c.maxWidth, widget.gutterWidth + widget.maxChars * widget.fontSize * 0.62 + 32);
      return Scrollbar(
        controller: _controller,
        thumbVisibility: width > c.maxWidth,
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: width, height: c.maxHeight, child: widget.child),
        ),
      );
    });
  }
}
