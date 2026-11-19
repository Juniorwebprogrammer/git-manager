import 'file_change.dart';

enum ResetMode { soft, mixed, hard }

/// Todas las operaciones de escritura que la UI puede pedir sobre un
/// repositorio. La capa de datos traduce cada una a comandos git.
sealed class GitAction {
  const GitAction();

  /// Etiqueta para la barra de progreso.
  String get label;

  /// Necesita hablar con el remoto (usa el token de la cuenta).
  bool get isNetwork => false;
}

class FetchAction extends GitAction {
  const FetchAction();
  @override
  String get label => 'Fetching…';
  @override
  bool get isNetwork => true;
}

class PullAction extends GitAction {
  /// `pull --rebase` en lugar de merge.
  final bool rebase;
  const PullAction({this.rebase = false});
  @override
  String get label => rebase ? 'Pulling (rebase)…' : 'Pulling…';
  @override
  bool get isNetwork => true;
}

class PushAction extends GitAction {
  /// Rama a publicar; por defecto la actual.
  final String? branch;
  final bool force;
  const PushAction({this.branch, this.force = false});
  @override
  String get label => force ? 'Force pushing…' : 'Pushing…';
  @override
  bool get isNetwork => true;
}

class CheckoutAction extends GitAction {
  final String ref;
  const CheckoutAction(this.ref);
  @override
  String get label => 'Checking out $ref…';
}

/// Checkout de una rama remota: crea la local con seguimiento si no existe.
class CheckoutRemoteAction extends GitAction {
  final String remoteRef;
  final String localName;
  const CheckoutRemoteAction(this.remoteRef, this.localName);
  @override
  String get label => 'Checking out $localName…';
}

class CheckoutDetachedAction extends GitAction {
  final String sha;
  const CheckoutDetachedAction(this.sha);
  @override
  String get label => 'Checking out…';
}

class CreateBranchAction extends GitAction {
  final String name;
  final String? startPoint;
  final bool checkout;
  const CreateBranchAction(this.name, {this.startPoint, this.checkout = true});
  @override
  String get label => 'Creating branch $name…';
}

class DeleteBranchAction extends GitAction {
  final String name;
  final bool force;
  const DeleteBranchAction(this.name, {this.force = false});
  @override
  String get label => 'Deleting $name…';
}

class DeleteRemoteBranchAction extends GitAction {
  final String remote;
  final String branch;
  const DeleteRemoteBranchAction(this.remote, this.branch);
  @override
  String get label => 'Deleting $remote/$branch…';
  @override
  bool get isNetwork => true;
}

class MergeAction extends GitAction {
  final String ref;
  const MergeAction(this.ref);
  @override
  String get label => 'Merging $ref…';
}

class StashAction extends GitAction {
  final String? message;
  const StashAction({this.message});
  @override
  String get label => 'Stashing…';
}

class StashPopAction extends GitAction {
  final String ref;
  const StashPopAction([this.ref = 'stash@{0}']);
  @override
  String get label => 'Popping stash…';
}

class StashApplyAction extends GitAction {
  final String ref;
  const StashApplyAction(this.ref);
  @override
  String get label => 'Applying stash…';
}

class StashDropAction extends GitAction {
  final String ref;
  const StashDropAction(this.ref);
  @override
  String get label => 'Dropping stash…';
}

class StageAction extends GitAction {
  final List<String> paths;
  const StageAction(this.paths);
  @override
  String get label => 'Staging…';
}

class StageAllAction extends GitAction {
  const StageAllAction();
  @override
  String get label => 'Staging all…';
}

class UnstageAction extends GitAction {
  final List<String> paths;
  const UnstageAction(this.paths);
  @override
  String get label => 'Unstaging…';
}

class UnstageAllAction extends GitAction {
  const UnstageAllAction();
  @override
  String get label => 'Unstaging all…';
}

/// Descarta los cambios sin stagear de esos ficheros (y borra los no
/// seguidos).
class DiscardAction extends GitAction {
  final List<FileChange> changes;
  const DiscardAction(this.changes);
  @override
  String get label => 'Discarding…';
}

class CommitAction extends GitAction {
  final String message;
  final bool amend;
  const CommitAction(this.message, {this.amend = false});
  @override
  String get label => 'Committing…';
}

class CherryPickAction extends GitAction {
  final String sha;
  const CherryPickAction(this.sha);
  @override
  String get label => 'Cherry-picking…';
}

class RevertAction extends GitAction {
  final String sha;
  const RevertAction(this.sha);
  @override
  String get label => 'Reverting…';
}

class ResetAction extends GitAction {
  final String sha;
  final ResetMode mode;
  const ResetAction(this.sha, this.mode);
  @override
  String get label => 'Resetting…';
}

class CreateTagAction extends GitAction {
  final String name;
  final String sha;
  const CreateTagAction(this.name, this.sha);
  @override
  String get label => 'Creating tag $name…';
}

class DeleteTagAction extends GitAction {
  final String name;
  const DeleteTagAction(this.name);
  @override
  String get label => 'Deleting tag $name…';
}

class PushTagAction extends GitAction {
  final String name;
  const PushTagAction(this.name);
  @override
  String get label => 'Pushing tag $name…';
  @override
  bool get isNetwork => true;
}

/// Rebase de [branch] (por defecto la rama actual) sobre [onto].
/// Si se indica [branch], git hace checkout de esa rama al terminar.
class RebaseAction extends GitAction {
  final String onto;
  final String? branch;
  const RebaseAction(this.onto, {this.branch});
  @override
  String get label => 'Rebasing onto $onto…';
}

/// Continúa un rebase/cherry-pick/revert/merge tras resolver conflictos.
class ContinueOperationAction extends GitAction {
  const ContinueOperationAction();
  @override
  String get label => 'Continuing…';
}

/// Salta el commit actual de un rebase/cherry-pick/revert.
class SkipOperationAction extends GitAction {
  const SkipOperationAction();
  @override
  String get label => 'Skipping commit…';
}

/// Aborta un merge/cherry-pick/revert/rebase que quedó a medias.
class AbortOperationAction extends GitAction {
  const AbortOperationAction();
  @override
  String get label => 'Aborting…';
}
