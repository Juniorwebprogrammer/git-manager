import '../entities/file_diff.dart';

/// Construye un parche unificado con solo parte de un hunk (o el hunk
/// entero) para aplicarlo con `git apply --recount`.
///
/// [selected] son los índices (dentro de `hunk.lines`) de las líneas `+`/`-`
/// elegidas; `null` = todas.
///
/// Cómo se tratan las líneas cambiadas que NO están seleccionadas depende
/// de hacia dónde se aplica el parche:
///
/// * Hacia delante ([reverse] = false, p. ej. stage sobre el índice, que
///   tiene el lado antiguo): un `+` no elegido se omite (no existe todavía)
///   y un `-` no elegido pasa a ser contexto (sigue estando).
/// * Al revés ([reverse] = true, unstage o descartar, sobre un destino que
///   tiene el lado nuevo): un `+` no elegido pasa a contexto (sigue ahí) y
///   un `-` no elegido se omite (ya no está).
///
/// Devuelve null si la selección no contiene ningún cambio.
String? buildPartialPatch({
  required String path,
  required DiffHunk hunk,
  Set<int>? selected,
  required bool reverse,
}) {
  final body = <String>[];
  var changes = 0;
  var lastKept = false;

  for (var i = 0; i < hunk.lines.length; i++) {
    final line = hunk.lines[i];
    final chosen = selected == null || selected.contains(i);
    switch (line.type) {
      case DiffLineType.context:
        body.add(' ${line.text}');
        lastKept = true;
      case DiffLineType.added:
        if (chosen) {
          body.add('+${line.text}');
          changes++;
          lastKept = true;
        } else if (reverse) {
          body.add(' ${line.text}');
          lastKept = true;
        } else {
          lastKept = false;
        }
      case DiffLineType.removed:
        if (chosen) {
          body.add('-${line.text}');
          changes++;
          lastKept = true;
        } else if (!reverse) {
          body.add(' ${line.text}');
          lastKept = true;
        } else {
          lastKept = false;
        }
      case DiffLineType.meta:
        // "\ No newline at end of file" acompaña a la línea anterior.
        if (lastKept) body.add(line.text);
    }
  }

  if (changes == 0) return null;

  // Los recuentos los recalcula `git apply --recount`; solo importa la
  // posición de inicio para localizar el trozo.
  final buffer = StringBuffer()
    ..writeln('diff --git a/$path b/$path')
    ..writeln('--- a/$path')
    ..writeln('+++ b/$path')
    ..writeln('@@ -${hunk.oldStart},1 +${hunk.newStart},1 @@');
  for (final l in body) {
    buffer.writeln(l);
  }
  return buffer.toString();
}
