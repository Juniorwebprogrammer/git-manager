/// Excepciones internas de la capa de datos, capturadas y traducidas
/// a [AppFailure] por los repositorios.
sealed class AppException implements Exception {
  final String message;

  const AppException(this.message);
}

class InvalidTokenException extends AppException {
  const InvalidTokenException() : super('Token inválido o sin permisos.');
}

class ServerException extends AppException {
  const ServerException(super.message);
}

class StorageException extends AppException {
  const StorageException(super.message);
}

class GitConfigException extends AppException {
  const GitConfigException(super.message);
}

class AccountNotFoundException extends AppException {
  const AccountNotFoundException() : super('Cuenta no encontrada.');
}
