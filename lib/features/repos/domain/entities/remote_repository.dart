/// Un repositorio de GitHub accesible con el token de la cuenta.
class RemoteRepository {
  final String fullName;
  final String name;
  final String description;
  final String cloneUrl;
  final bool isPrivate;
  final DateTime? updatedAt;

  const RemoteRepository({
    required this.fullName,
    required this.name,
    required this.description,
    required this.cloneUrl,
    required this.isPrivate,
    this.updatedAt,
  });
}
