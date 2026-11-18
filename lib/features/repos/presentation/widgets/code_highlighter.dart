import 'package:flutter/material.dart';

/// Resaltado de sintaxis ligero y genérico, línea a línea (sin estado entre
/// líneas): suficiente para leer diffs con comodidad sin dependencias.
class CodeHighlighter {
  final bool enabled;
  final RegExp _token;
  final Brightness brightness;

  CodeHighlighter._(this.enabled, this._token, this.brightness);

  static const _hashComment = {
    'py', 'sh', 'bash', 'zsh', 'yaml', 'yml', 'rb', 'toml', 'conf', 'cfg', 'ini', 'cmake', 'pl', 'r', 'ps1',
    'dockerfile', 'makefile', 'gitignore', 'env', 'properties',
  };
  static const _plain = {'md', 'txt', 'markdown', 'rst', 'csv', 'log', 'lock', 'svg'};

  static final Map<String, CodeHighlighter> _cache = {};

  factory CodeHighlighter.forPath(String path, Brightness brightness) {
    final name = path.split('/').last.toLowerCase();
    final ext = name.contains('.') ? name.split('.').last : name;
    final key = '$ext|${brightness.name}';
    return _cache.putIfAbsent(key, () {
      final hash = _hashComment.contains(ext);
      final comment = hash ? r'#.*$' : r'//.*$|/\*.*?(?:\*/|$)|<!--.*?(?:-->|$)';
      final pattern = RegExp(
        '($comment)'
        r'''|("(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?|`[^`]*`?)'''
        r'|(\b\d+(?:\.\d+)?\b)'
        r'|(\b[A-Za-z_$][A-Za-z0-9_$]*\b)',
      );
      return CodeHighlighter._(!_plain.contains(ext), pattern, brightness);
    });
  }

  static const _keywords = {
    'abstract', 'as', 'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue', 'def',
    'default', 'defer', 'del', 'do', 'elif', 'else', 'enum', 'export', 'extends', 'extension', 'false',
    'final', 'finally', 'fn', 'for', 'from', 'func', 'function', 'go', 'if', 'impl', 'implements', 'import',
    'in', 'interface', 'is', 'lambda', 'late', 'let', 'match', 'mixin', 'mod', 'module', 'mut', 'namespace',
    'new', 'nil', 'none', 'None', 'not', 'null', 'of', 'or', 'and', 'override', 'package', 'pass', 'private',
    'protected', 'pub', 'public', 'raise', 'readonly', 'required', 'return', 'sealed', 'select', 'self', 'static',
    'struct', 'super', 'switch', 'sync', 'this', 'throw', 'throws', 'trait', 'true', 'True', 'False', 'try',
    'type', 'typedef', 'typeof', 'undefined', 'use', 'val', 'var', 'void', 'when', 'where', 'while', 'with',
    'yield', 'int', 'double', 'float', 'bool', 'string', 'char', 'long', 'short', 'unsigned', 'dynamic',
    'echo', 'then', 'fi', 'done', 'esac', 'local',
  };

  ({Color keyword, Color string, Color comment, Color number, Color type}) get _palette =>
      brightness == Brightness.dark
          ? (
              keyword: const Color(0xFFC678DD),
              string: const Color(0xFF98C379),
              comment: const Color(0xFF7F848E),
              number: const Color(0xFFD19A66),
              type: const Color(0xFFE5C07B),
            )
          : (
              keyword: const Color(0xFFA626A4),
              string: const Color(0xFF50A14F),
              comment: const Color(0xFF9DA0A7),
              number: const Color(0xFF986801),
              type: const Color(0xFFC18401),
            );

  TextSpan highlight(String line, TextStyle base) {
    if (!enabled || line.isEmpty || line.length > 2000) return TextSpan(text: line, style: base);
    final palette = _palette;
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _token.allMatches(line)) {
      if (m.start > last) spans.add(TextSpan(text: line.substring(last, m.start)));
      final text = m.group(0)!;
      TextStyle? style;
      if (m.group(1) != null) {
        style = TextStyle(color: palette.comment, fontStyle: FontStyle.italic);
      } else if (m.group(2) != null) {
        style = TextStyle(color: palette.string);
      } else if (m.group(3) != null) {
        style = TextStyle(color: palette.number);
      } else if (_keywords.contains(text)) {
        style = TextStyle(color: palette.keyword);
      } else if (text.length > 1 && text[0].toUpperCase() == text[0] && text[0] != '_' && text[0] != r'$') {
        style = TextStyle(color: palette.type);
      }
      spans.add(TextSpan(text: text, style: style));
      last = m.end;
    }
    if (last < line.length) spans.add(TextSpan(text: line.substring(last)));
    return TextSpan(style: base, children: spans);
  }
}
