import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Version ──────────────────────────────────────────────────────────────────
/// Must match version in pubspec.yaml. Format: "1.0.0"
const String kAppVersion = '1.0.0';

const String _kGithubReleasesUrl =
    'https://api.github.com/repos/dinemata/Open-Voice-Reader/releases/latest';
const String _kSponsorUrl = 'https://github.com/sponsors/dinemata';

// ─── Public entry point ───────────────────────────────────────────────────────

/// Call this after the dashboard loads. Shows an update dialog on Windows if a
/// newer version is available; triggers the Play Store flow on Android.
/// Throttled to once per 24 hours to avoid spamming the GitHub API.
Future<void> checkForUpdates(BuildContext context) async {
  if (kIsWeb) return;
  try {
    // Throttle: only check once per 24h
    final prefs = await SharedPreferences.getInstance();
    final lastChecked = prefs.getInt('update_last_checked') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - lastChecked < const Duration(hours: 24).inMilliseconds) {
      debugPrint('[UPDATE] Skipping check — last checked ${(now - lastChecked) ~/ 3600000}h ago');
      return;
    }
    await prefs.setInt('update_last_checked', now);

    if (Platform.isAndroid) {
      await _handleAndroidUpdate();
    } else if (Platform.isWindows) {
      if (!context.mounted) return;
      await _handleWindowsUpdate(context);
    }
  } catch (e) {
    debugPrint('[UPDATE] checkForUpdates error: $e');
  }
}

// ─── Android ─────────────────────────────────────────────────────────────────

Future<void> _handleAndroidUpdate() async {
  try {
    final info = await InAppUpdate.checkForUpdate();
    if (info.updateAvailability == UpdateAvailability.updateAvailable) {
      // Flexible update so the user can continue using the app while downloading
      if (info.immediateUpdateAllowed) {
        await InAppUpdate.performImmediateUpdate();
      } else if (info.flexibleUpdateAllowed) {
        await InAppUpdate.startFlexibleUpdate();
        await InAppUpdate.completeFlexibleUpdate();
      }
    }
  } catch (e) {
    debugPrint('[UPDATE] Android update check failed: $e');
  }
}

// ─── Windows ─────────────────────────────────────────────────────────────────

class _ReleaseInfo {
  final String version;   // e.g. "1.2.0"
  final String tag;       // e.g. "v1.2.0"
  final String notes;     // release body (truncated)
  final String assetUrl;  // direct download URL for the installer

  const _ReleaseInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.assetUrl,
  });
}

Future<void> _handleWindowsUpdate(BuildContext context) async {
  final release = await _fetchLatestRelease();
  if (release == null) return;

  // Compare semver: split by '.' and compare numerically
  if (!_isNewer(release.version, kAppVersion)) return;

  if (!context.mounted) return;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _WindowsUpdateDialog(release: release),
  );
}

Future<_ReleaseInfo?> _fetchLatestRelease() async {
  try {
    final response = await http
        .get(Uri.parse(_kGithubReleasesUrl),
        headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 12));

    if (response.statusCode != 200) return null;

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = (json['tag_name'] as String? ?? '').trim();
    final version = tag.replaceFirst(RegExp(r'^v'), '');
    final notes = (json['body'] as String? ?? '').trim();

    // Find the first Windows installer asset (.exe or .msix)
    final assets = (json['assets'] as List<dynamic>? ?? []);
    String assetUrl = '';
    for (final asset in assets) {
      final name = (asset['name'] as String? ?? '').toLowerCase();
      if (name.endsWith('.exe') || name.endsWith('.msix') || name.endsWith('.msi')) {
        assetUrl = asset['browser_download_url'] as String? ?? '';
        break;
      }
    }

    if (version.isEmpty || assetUrl.isEmpty) return null;
    return _ReleaseInfo(version: version, tag: tag, notes: notes, assetUrl: assetUrl);
  } catch (e) {
    debugPrint('[UPDATE] Failed to fetch release info: $e');
    return null;
  }
}

/// Returns true if [candidate] is newer than [current].
bool _isNewer(String candidate, String current) {
  try {
    final c = candidate.split('.').map(int.parse).toList();
    final v = current.split('.').map(int.parse).toList();
    for (int i = 0; i < 3; i++) {
      final a = i < c.length ? c[i] : 0;
      final b = i < v.length ? v[i] : 0;
      if (a > b) return true;
      if (a < b) return false;
    }
    return false; // equal
  } catch (_) {
    return false;
  }
}

// ─── Windows update dialog ────────────────────────────────────────────────────

class _WindowsUpdateDialog extends StatefulWidget {
  final _ReleaseInfo release;
  const _WindowsUpdateDialog({required this.release});

  @override
  State<_WindowsUpdateDialog> createState() => _WindowsUpdateDialogState();
}

class _WindowsUpdateDialogState extends State<_WindowsUpdateDialog> {
  _Phase _phase = _Phase.idle;
  double _progress = 0;
  String? _errorMessage;
  String? _installerPath;

  Future<void> _download() async {
    setState(() { _phase = _Phase.downloading; _progress = 0; _errorMessage = null; });

    try {
      final dir = await getTemporaryDirectory();
      final ext = widget.release.assetUrl.split('.').last.toLowerCase();
      final dest = File('${dir.path}/ovr_update_${widget.release.tag}.$ext');

      // Stream download with progress
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(widget.release.assetUrl));
      final streamed = await client.send(request);
      final total = streamed.contentLength ?? 0;
      int received = 0;
      final sink = dest.openWrite();
      await streamed.stream.forEach((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && mounted) {
          setState(() => _progress = received / total);
        }
      });
      await sink.close();
      client.close();

      if (!mounted) return;
      setState(() { _phase = _Phase.ready; _installerPath = dest.path; });
    } catch (e) {
      if (mounted) setState(() { _phase = _Phase.error; _errorMessage = e.toString(); });
    }
  }

  Future<void> _install() async {
    if (_installerPath == null) return;
    setState(() => _phase = _Phase.installing);
    try {
      // Run the installer. For .exe/.msi it opens the wizard and exits Flutter.
      // For .msix, PowerShell's Add-AppxPackage is used.
      final path = _installerPath!;
      if (path.endsWith('.msix')) {
        await Process.run(
          'powershell',
          ['-NoProfile', '-Command', 'Add-AppxPackage -Path "$path"'],
        );
      } else {
        // /S for NSIS silent install; /quiet for MSI; raw .exe opens wizard
        await Process.start(path, [], mode: ProcessStartMode.detached);
        // Give the installer a moment to open, then exit so it can replace files
        await Future.delayed(const Duration(seconds: 1));
        exit(0);
      }
    } catch (e) {
      if (mounted) setState(() { _phase = _Phase.error; _errorMessage = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final notes = widget.release.notes.length > 300
        ? '${widget.release.notes.substring(0, 300)}…'
        : widget.release.notes;

    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.system_update_alt_rounded, color: Color(0xFF1A73E8), size: 22),
        const SizedBox(width: 10),
        Text('Nová verze ${widget.release.version}'),
      ]),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_phase == _Phase.idle) ...[
            if (notes.isNotEmpty) ...[
              Text('Co je nového:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey.shade600)),
              const SizedBox(height: 6),
              Text(notes, style: const TextStyle(fontSize: 12)),
            ] else
              const Text('Je dostupná nová verze aplikace.'),
          ],
          if (_phase == _Phase.downloading) ...[
            const Text('Stahování aktualizace…\nNeukončujte aplikaci.',
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 6,
                backgroundColor: Colors.grey.shade200,
                color: const Color(0xFF1A73E8),
              ),
            ),
            const SizedBox(height: 6),
            Text('${(_progress * 100).toStringAsFixed(0)} %',
                style: const TextStyle(fontSize: 11, color: Color(0xFF5F6368))),
          ],
          if (_phase == _Phase.ready)
            const Text('Staženo. Klikněte na Instalovat — aplikace se restartuje.',
                style: TextStyle(fontSize: 13)),
          if (_phase == _Phase.installing)
            const Row(children: [
              SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Expanded(child: Text('Spouštím instalátor…')),
            ]),
          if (_phase == _Phase.error) ...[
            const Icon(Icons.error_outline_rounded, color: Colors.red, size: 32),
            const SizedBox(height: 8),
            Text('Chyba: $_errorMessage', style: const TextStyle(fontSize: 12, color: Colors.red)),
          ],
        ]),
      ),
      actions: [
        if (_phase == _Phase.idle) ...[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Později'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.download_rounded, size: 16),
            label: const Text('Stáhnout'),
            onPressed: _download,
          ),
        ],
        if (_phase == _Phase.ready)
          ElevatedButton.icon(
            icon: const Icon(Icons.install_desktop_rounded, size: 16),
            label: const Text('Instalovat'),
            onPressed: _install,
          ),
        if (_phase == _Phase.error)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zavřít'),
          ),
      ],
    );
  }
}

enum _Phase { idle, downloading, ready, installing, error }

// ─── Sponsor button widget ────────────────────────────────────────────────────

/// A small heart-shaped sponsor button. Drop it anywhere in the UI.
/// Hidden automatically on Android/iOS.
class SponsorButton extends StatefulWidget {
  final bool compact;
  final Color? color;
  const SponsorButton({super.key, this.compact = false, this.color});

  @override
  State<SponsorButton> createState() => _SponsorButtonState();
}

class _SponsorButtonState extends State<SponsorButton> {
  bool _hovered = false;

  // Don't show on mobile — Play Store rules prohibit in-app donation prompts
  static bool get _visible => !kIsWeb && !Platform.isAndroid && !Platform.isIOS;

  void _open() async {
    try {
      final uri = Uri.parse(_kSponsorUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('[SPONSOR] Could not open URL: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final baseColor = widget.color ?? const Color(0xFFDB61A2);
    final color = _hovered ? const Color(0xFFBF4080) : baseColor;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _open,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: widget.compact
              ? const EdgeInsets.all(8)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.favorite_rounded, size: 15, color: color),
            if (!widget.compact) ...[
              const SizedBox(width: 5),
              Text('Sponsor', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
            ],
          ]),
        ),
      ),
    );
  }
}