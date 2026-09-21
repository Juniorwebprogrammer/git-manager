/// Fallos de dominio que puede producir cualquier caso de uso de la app.
sealed class AppFailure {
  final String message;

  const AppFailure(this.message);
}

class InvalidTokenFailure extends AppFailure {
  const InvalidTokenFailure()
      : super('El token no es válido o no tiene permisos suficientes.');
}

class AccountAlreadyExistsFailure extends AppFailure {
  const AccountAlreadyExistsFailure(String login)
      : super('La cuenta "$login" ya está añadida.');
}

class AccountNotFoundFailure extends AppFailure {
  const AccountNotFoundFailure() : super('No se encontró la cuenta solicitada.');
}

class NetworkFailure extends AppFailure {
  const NetworkFailure([super.message = 'No se pudo conectar con GitHub.']);
}

class StorageFailure extends AppFailure {
  const StorageFailure(super.message);
}

class GitConfigFailure extends AppFailure {
  const GitConfigFailure(super.message);
}

class UnknownFailure extends AppFailure {
  const UnknownFailure([super.message = 'Ha ocurrido un error inesperado.']);
}
