/// Internal data-layer exceptions, caught and translated into
/// [AppFailure] by the repositories.
sealed class AppException implements Exception {
  final String message;

  const AppException(this.message);
}

class InvalidTokenException extends AppException {
  const InvalidTokenException() : super('Invalid or insufficiently scoped token.');
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
  const AccountNotFoundException() : super('Account not found.');
}

class GitCommandException extends AppException {
  const GitCommandException(super.message);
}
