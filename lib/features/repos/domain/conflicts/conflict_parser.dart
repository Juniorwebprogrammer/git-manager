/// Fichero con marcadores de conflicto, troceado para resolverlo bloque a
/// bloque:
///
/// ```
/// <<<<<<< HEAD            ← ours  ("Current")
/// ...
/// ||||||| base            ← opcional (estilo diff3 / zdiff3)
/// ...
/// =======
/// ...
/// >>>>>>> feature         ← theirs ("Incoming")
/// ```
sealed class ConflictSegment {
  const ConflictSegment();
}

class TextSegment extends ConflictSegment {
  final List<String> lines;
  const TextSegment(this.lines);
}

class ConflictBlock extends ConflictSegment {
  final List<String> ours;
  final List<String> theirs;
  final List<String>? base;
  final String oursLabel;
  final String theirsLabel;

  const ConflictBlock({
    required this.ours,
    required this.theirs,
    required this.oursLabel,
    required this.theirsLabel,
    this.base,
  });
}

enum ConflictChoice { ours, theirs, oursThenTheirs, theirsThenOurs }

class ParsedConflictFile {
  final List<ConflictSegment> segments;

  /// El fichero termina en salto de línea.
  final bool trailingNewline;

  const ParsedConflictFile(this.segments, {this.trailingNewline = true});

  List<ConflictBlock> get conflicts => segments.whereType<ConflictBlock>().toList();

  /// Reconstruye el fichero con una elección por conflicto (en orden).
  /// Un conflicto sin elección (null) conserva sus marcadores.
  String render(List<ConflictChoice?> choices) {
    final out = <String>[];
    var index = 0;
    for (final segment in segments) {
      switch (segment) {
        case TextSegment(:final lines):
          out.addAll(lines);
        case ConflictBlock():
          final choice = index < choices.length ? choices[index] : null;
          index++;
          out.addAll(switch (choice) {
            ConflictChoice.ours => segment.ours,
            ConflictChoice.theirs => segment.theirs,
            ConflictChoice.oursThenTheirs => [...segment.ours, ...segment.theirs],
            ConflictChoice.theirsThenOurs => [...segment.theirs, ...segment.ours],
            null => [
                '<<<<<<< ${segment.oursLabel}'.trimRight(),
                ...segment.ours,
                if (segment.base != null) ...['|||||||', ...segment.base!],
                '=======',
                ...segment.theirs,
                '>>>>>>> ${segment.theirsLabel}'.trimRight(),
              ],
          });
      }
    }
    final text = out.join('\n');
    return trailingNewline && out.isNotEmpty ? '$text\n' : text;
  }
}

String _label(String line, String marker) {
  final rest = line.substring(marker.length).trimRight();
  return rest.trim();
}

/// Trocea [text]. Las líneas conservan un posible `\r` final (CRLF).
ParsedConflictFile parseConflicts(String text) {
  final trailing = text.endsWith('\n');
  final lines = text.split('\n');
  if (trailing) lines.removeLast();

  bool starts(String line, String marker) {
    final clean = line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
    return clean == marker || clean.startsWith('$marker ');
  }

  String clean(String line) => line.endsWith('\r') ? line.substring(0, line.length - 1) : line;

  final segments = <ConflictSegment>[];
  var text0 = <String>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (!starts(line, '<<<<<<<')) {
      text0.add(line);
      i++;
      continue;
    }

    // Buscar el resto del bloque; si está mal formado, se trata como texto.
    final ours = <String>[];
    List<String>? base;
    final theirs = <String>[];
    var j = i + 1;
    var stage = 0; // 0 = ours, 1 = base, 2 = theirs
    String? theirsLabel;
    while (j < lines.length) {
      final l = lines[j];
      if (stage < 2 && starts(l, '|||||||')) {
        stage = 1;
        base = [];
      } else if (stage < 2 && clean(l) == '=======') {
        stage = 2;
      } else if (stage == 2 && starts(l, '>>>>>>>')) {
        theirsLabel = _label(clean(l), '>>>>>>>');
        break;
      } else {
        (stage == 0 ? ours : stage == 1 ? base! : theirs).add(l);
      }
      j++;
    }

    if (theirsLabel == null) {
      // Sin cierre: no es un conflicto real.
      text0.addAll(lines.sublist(i));
      break;
    }

    if (text0.isNotEmpty) {
      segments.add(TextSegment(text0));
      text0 = <String>[];
    }
    segments.add(ConflictBlock(
      ours: ours,
      theirs: theirs,
      base: base,
      oursLabel: _label(clean(line), '<<<<<<<'),
      theirsLabel: theirsLabel,
    ));
    i = j + 1;
  }
  if (text0.isNotEmpty) segments.add(TextSegment(text0));
  return ParsedConflictFile(segments, trailingNewline: trailing);
}
