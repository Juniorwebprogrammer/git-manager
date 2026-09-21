import 'package:flutter/material.dart';

/// Genera un color estable a partir del login de una cuenta, usado como
/// fondo del avatar cuando no hay imagen disponible.
class AvatarPalette {
  const AvatarPalette._();

  static const List<Color> _colors = [
    Color(0xFF6750A4),
    Color(0xFF006A6A),
    Color(0xFF8B5000),
    Color(0xFF3A608F),
    Color(0xFF7D5260),
    Color(0xFF386A20),
    Color(0xFF984061),
    Color(0xFF31629C),
  ];

  static Color colorFor(String seed) {
    if (seed.isEmpty) return _colors.first;
    final index = seed.codeUnits.fold<int>(0, (sum, unit) => sum + unit) %
        _colors.length;
    return _colors[index];
  }

  static String initialsFor(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }
}
