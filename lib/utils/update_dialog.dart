import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.g.dart';
import '../services/update_service.dart';
import '../widgets/dialog_action_button.dart';
import 'device_channel.dart';
import 'dialogs.dart';

Future<void> showUpdateAvailableDialog(
  BuildContext context,
  Map<String, dynamic> updateInfo, {
  required String title,
  required String dismissLabel,
  bool showSkipVersion = false,
}) {
  return showScopedDialog<void>(
    context: context,
    builder: (dialogContext) => _UpdateDialogBody(
      updateInfo: updateInfo,
      title: title,
      dismissLabel: dismissLabel,
      showSkipVersion: showSkipVersion,
    ),
  );
}

class _UpdateDialogBody extends StatefulWidget {
  final Map<String, dynamic> updateInfo;
  final String title;
  final String dismissLabel;
  final bool showSkipVersion;

  const _UpdateDialogBody({
    required this.updateInfo,
    required this.title,
    required this.dismissLabel,
    this.showSkipVersion = false,
  });

  @override
  State<_UpdateDialogBody> createState() => _UpdateDialogBodyState();
}

class _UpdateDialogBodyState extends State<_UpdateDialogBody> {
  bool _isDownloading = false;
  double _progress = 0.0;
  int _downloadedBytes = 0;
  int _totalBytes = 0;
  String? _errorMessage;
  String? _apkDownloadUrl;
  bool _isCheckingApk = true;

  @override
  void initState() {
    super.initState();
    _checkApkAvailability();
  }

  Future<void> _checkApkAvailability() async {
    if (Platform.isAndroid) {
      final assets = (widget.updateInfo['assets'] as List<dynamic>?) ?? [];
      final url = await UpdateService.findApkDownloadUrl(assets);
      if (mounted) {
        setState(() {
          _apkDownloadUrl = url;
          _isCheckingApk = false;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _isCheckingApk = false;
        });
      }
    }
  }

  Future<void> _startDownloadAndInstall() async {
    if (_apkDownloadUrl == null) return;

    setState(() {
      _isDownloading = true;
      _errorMessage = null;
      _progress = 0.0;
      _downloadedBytes = 0;
      _totalBytes = 0;
    });

    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(_apkDownloadUrl!));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('Erreur serveur (${response.statusCode})');
      }

      final total = response.contentLength ?? 0;
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/plezy_update.apk');
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }

      final sink = file.openWrite();
      int downloaded = 0;

      await for (final chunk in response.stream) {
        sink.add(chunk);
        downloaded += chunk.length;
        if (mounted) {
          setState(() {
            _downloadedBytes = downloaded;
            _totalBytes = total;
            if (total > 0) {
              _progress = downloaded / total;
            }
          });
        }
      }

      await sink.flush();
      await sink.close();

      if (!mounted) return;

      // Check unknown sources installation permission on Android 8+
      try {
        final canInstall = await deviceChannel.invokeMethod<bool>('canRequestPackageInstalls') ?? true;
        if (!canInstall) {
          await deviceChannel.invokeMethod('openInstallPermissionSettings');
        }
      } catch (_) {}

      // Trigger native package installer
      final success = await deviceChannel.invokeMethod<bool>('installApk', {'filePath': file.path});
      if (success == true) {
        if (mounted) Navigator.of(context).pop();
      } else {
        throw Exception("Impossible de lancer l'installateur du système");
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _errorMessage = 'Échec du téléchargement : $e';
        });
      }
    }
  }

  Future<void> _openInBrowser() async {
    final releaseUrl = widget.updateInfo['releaseUrl'] as String? ?? '';
    final url = Uri.parse(releaseUrl);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final latestVersion = widget.updateInfo['latestVersion'] as String? ?? '';
    final currentVersion = widget.updateInfo['currentVersion'] as String? ?? '';

    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.update.versionAvailable(version: latestVersion),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            t.update.currentVersion(version: currentVersion),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_isDownloading) ...[
            const SizedBox(height: 20),
            LinearProgressIndicator(value: _totalBytes > 0 ? _progress : null),
            const SizedBox(height: 8),
            Text(
              _totalBytes > 0
                  ? '${(_downloadedBytes / (1024 * 1024)).toStringAsFixed(1)} Mo / ${(_totalBytes / (1024 * 1024)).toStringAsFixed(1)} Mo (${(_progress * 100).toStringAsFixed(0)}%)'
                  : 'Téléchargement en cours...',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13),
            ),
          ],
        ],
      ),
      actions: [
        if (!_isDownloading) ...[
          DialogActionButton(
            onPressed: () => Navigator.pop(context),
            label: widget.dismissLabel,
          ),
          if (widget.showSkipVersion)
            DialogActionButton(
              onPressed: () async {
                await UpdateService.skipVersion(latestVersion);
                if (context.mounted) Navigator.pop(context);
              },
              label: t.update.skipVersion,
            ),
          if (Platform.isAndroid && _apkDownloadUrl != null)
            DialogActionButton(
              onPressed: _startDownloadAndInstall,
              label: 'Mettre à jour',
              isPrimary: true,
            )
          else if (!_isCheckingApk)
            DialogActionButton(
              onPressed: _openInBrowser,
              label: t.update.viewRelease,
              isPrimary: true,
            ),
        ],
      ],
    );
  }
}
