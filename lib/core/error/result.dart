import 'app_failure.dart';

/// Resultado de una operación que puede fallar, sin recurrir a excepciones
/// para el control de flujo entre capas.
sealed class Result<T> {
  const Result();

  R when<R>({
    required R Function(T value) success,
    required R Function(AppFailure failure) failure,
  }) => switch (this) {
        Success<T>(:final value) => success(value),
        Failure<T>(failure: final f) => failure(f),
      };
}

final class Success<T> extends Result<T> {
  final T value;

  const Success(this.value);
}

final class Failure<T> extends Result<T> {
  final AppFailure failure;

  const Failure(this.failure);
}
