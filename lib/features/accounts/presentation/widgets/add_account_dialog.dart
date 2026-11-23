import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/error/result.dart';
import '../../../../core/hosting/git_provider.dart';
import '../state/accounts_notifier.dart';

class AddAccountDialog extends ConsumerStatefulWidget {
  const AddAccountDialog({super.key});

  @override
  ConsumerState<AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends ConsumerState<AddAccountDialog> {
  final _tokenController = TextEditingController();
  final _orgController = TextEditingController();
  GitProvider _provider = GitProvider.github;
  bool _obscure = true;
  bool _isSubmitting = false;
  String? _errorMessage;
  String? _orgError;

  @override
  void dispose() {
    _tokenController.dispose();
    _orgController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _errorMessage = 'Enter a personal access token.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _orgError = null;
    });

    final notifier = ref.read(accountsNotifierProvider.notifier);
    final result = _provider == GitProvider.azure
        ? await notifier.addAzure(token, organization: _orgController.text)
        : await notifier.add(token);

    if (!mounted) return;

    switch (result) {
      case Success(:final value):
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Account added: ${value.login}')),
        );
      case Failure(:final failure):
        setState(() {
          _isSubmitting = false;
          // Lo que falta es la organización: el error va en ese campo.
          if (failure is AccountSetupFailure) {
            _orgError = failure.message;
          } else {
            _errorMessage = failure.message;
          }
        });
    }
  }

  /// Página para crear el token, con los permisos ya marcados en GitHub.
  Uri get _tokenPage => switch (_provider) {
        GitProvider.github => Uri.parse(
            'https://github.com/settings/tokens/new?scopes=repo,read:user,user:email&description=Git%20Manager'),
        GitProvider.azure => _orgController.text.trim().isEmpty
            ? Uri.parse('https://dev.azure.com/')
            : Uri.parse('https://dev.azure.com/${Uri.encodeComponent(_orgController.text.trim())}/_usersSettings/tokens'),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final azure = _provider == GitProvider.azure;

    return AlertDialog(
      title: const Text('Add account'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<GitProvider>(
                segments: const [
                  ButtonSegment(value: GitProvider.github, label: Text('GitHub'), icon: Icon(Icons.hub_outlined)),
                  ButtonSegment(value: GitProvider.azure, label: Text('Azure DevOps'), icon: Icon(Icons.cloud_outlined)),
                ],
                selected: {_provider},
                onSelectionChanged: _isSubmitting
                    ? null
                    : (s) => setState(() {
                          _provider = s.first;
                          _errorMessage = null;
                          _orgError = null;
                        }),
              ),
              const SizedBox(height: 14),
              Text(
                azure
                    ? 'Create a personal access token in Azure DevOps (User settings → Personal access tokens) '
                        'with Organization "All accessible organizations" and the scopes '
                        '"Code: Read & write" and "User Profile: Read". It is stored encrypted in the '
                        'system\'s secure storage and used for clone, push and pull.'
                    : 'Generate a token at github.com/settings/tokens with the '
                        '"repo" scope (to clone/push) and "read:user" + "user:email" '
                        '(for the profile). It is stored encrypted in the system\'s '
                        'secure storage; pressing Connect also uses it to '
                        'authenticate git over HTTPS.',
                style: theme.textTheme.bodySmall,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => launchUrl(_tokenPage),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(azure ? 'Open Azure DevOps to create a token' : 'Create a token on GitHub'),
                ),
              ),
              const SizedBox(height: 8),
              if (azure) ...[
                TextField(
                  controller: _orgController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Organization (optional)',
                    hintText: 'as in dev.azure.com/<organization>',
                    helperText: 'Leave empty to use every organization the token can access',
                    errorText: _orgError,
                    errorMaxLines: 3,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _tokenController,
                obscureText: _obscure,
                autofocus: true,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Personal Access Token',
                  border: const OutlineInputBorder(),
                  errorText: _errorMessage,
                  errorMaxLines: 6,
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isSubmitting ? null : _submit,
          icon: _isSubmitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_tethering),
          label: Text(_isSubmitting ? 'Checking...' : 'Test & add'),
        ),
      ],
    );
  }
}
