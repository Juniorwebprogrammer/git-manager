/// Domain failures that any use case in the app can produce.
sealed class AppFailure {
  final String message;

  const AppFailure(this.message);
}

class InvalidTokenFailure extends AppFailure {
  const InvalidTokenFailure()
      : super('The token is invalid or does not have enough permissions.');
}

class AccountAlreadyExistsFailure extends AppFailure {
  const AccountAlreadyExistsFailure(String login)
      : super('The "$login" account has already been added.');
}

class AccountNotFoundFailure extends AppFailure {
  const AccountNotFoundFailure() : super('The requested account was not found.');
}

class NetworkFailure extends AppFailure {
  const NetworkFailure([super.message = 'Could not connect to GitHub.']);
}

class StorageFailure extends AppFailure {
  const StorageFailure(super.message);
}

class GitConfigFailure extends AppFailure {
  const GitConfigFailure(super.message);
}

class GitCommandFailure extends AppFailure {
  const GitCommandFailure(super.message);
}

class UnknownFailure extends AppFailure {
  const UnknownFailure([super.message = 'An unexpected error occurred.']);
}
