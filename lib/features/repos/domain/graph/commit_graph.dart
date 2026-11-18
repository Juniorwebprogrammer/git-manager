import '../entities/git_commit.dart';

enum GraphSegment {
  /// De la parte de arriba de la fila al nodo (mitad superior).
  top,

  /// Del nodo a la parte de abajo de la fila (mitad inferior).
  bottom,

  /// Carril que atraviesa la fila entera sin tocar el nodo.
  through,
}

class GraphLine {
  final int fromLane;
  final int toLane;
  final GraphSegment segment;
  final int color;

  const GraphLine(this.fromLane, this.toLane, this.segment, this.color);
}

/// Lo que hay que pintar en la fila de un commit del grafo.
class GraphRow {
  /// Carril en el que se dibuja el nodo del commit.
  final int lane;
  final int color;
  final List<GraphLine> lines;

  /// Número de carriles ocupados en esta fila.
  final int width;

  const GraphRow({
    required this.lane,
    required this.color,
    required this.lines,
    required this.width,
  });
}

/// Asigna carriles a una lista de commits ordenada hijos→padres
/// (`git log --date-order` / `--topo-order`), al estilo de `git log --graph`.
///
/// Cada carril "espera" un sha concreto: cuando aparece ese commit, todos
/// los carriles que lo esperaban convergen en su nodo, y el carril del nodo
/// pasa a esperar a su primer padre. Los padres adicionales (merges)
/// abren o reutilizan otros carriles.
List<GraphRow> buildCommitGraph(List<GitCommit> commits) {
  final lanes = <String?>[];
  final colors = <int>[];
  var nextColor = 0;
  final rows = <GraphRow>[];

  int allocate(String sha) {
    var index = lanes.indexOf(null);
    if (index == -1) {
      lanes.add(sha);
      colors.add(nextColor++);
      return lanes.length - 1;
    }
    lanes[index] = sha;
    colors[index] = nextColor++;
    return index;
  }

  for (final commit in commits) {
    var lane = lanes.indexOf(commit.sha);
    final isTip = lane == -1;
    if (isTip) lane = allocate(commit.sha);

    final lines = <GraphLine>[];

    // Mitad superior: carriles que llegan al nodo o lo atraviesan.
    for (var j = 0; j < lanes.length; j++) {
      final expected = lanes[j];
      if (expected == null) continue;
      if (expected == commit.sha) {
        if (isTip && j == lane) continue;
        lines.add(GraphLine(j, lane, GraphSegment.top, colors[j]));
        if (j != lane) lanes[j] = null;
      } else {
        lines.add(GraphLine(j, j, GraphSegment.through, colors[j]));
      }
    }

    final nodeColor = colors[lane];

    // Mitad inferior: del nodo hacia sus padres.
    if (commit.parents.isEmpty) {
      lanes[lane] = null;
    } else {
      lanes[lane] = commit.parents.first;
      lines.add(GraphLine(lane, lane, GraphSegment.bottom, nodeColor));
      for (final parent in commit.parents.skip(1)) {
        var target = lanes.indexOf(parent);
        if (target == -1) target = allocate(parent);
        lines.add(GraphLine(lane, target, GraphSegment.bottom, colors[target]));
      }
    }

    var width = lanes.length;
    while (lanes.isNotEmpty && lanes.last == null) {
      lanes.removeLast();
      colors.removeLast();
    }

    rows.add(GraphRow(lane: lane, color: nodeColor, lines: lines, width: width));
  }

  return rows;
}
