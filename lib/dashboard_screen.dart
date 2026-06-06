import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:url_launcher/url_launcher.dart';

import 'model.dart';
import 'speech_test_view.dart';
import 'main.dart';
import 'update_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<BookModel> _books = [];
  bool _isLoadingHistory = true;
  bool _isImporting = false;
  String _importStatus = '';
  double _importProgress = 0.0;

  // Speed overlay state for AudioPlayerBar
  final LayerLink _speedLayerLink = LayerLink();
  bool _speedOpen = false;
  OverlayEntry? _speedOverlay;
  double _playbackSpeed = 1.0;

  bool get _isDark {
    final mode = appThemeNotifier.value;
    if (mode == 2) return true;
    if (mode == 1) return false;
    return WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
  }

  @override
  void initState() {
    super.initState();
    _loadHistory();
    appThemeNotifier.addListener(_onThemeChanged);
    // Load saved playback speed
    SharedPreferences.getInstance().then((prefs) {
      // Prefer the active book's speed over the generic dashboard speed
      final activeId = globalActiveBookId;
      double s;
      if (activeId != null) {
        s = prefs.getDouble('speed_$activeId') ?? prefs.getDouble('dashboard_speed') ?? 1.0;
      } else {
        s = prefs.getDouble('dashboard_speed') ?? 1.0;
      }
      if (mounted) setState(() => _playbackSpeed = s);
    });
    // Check for updates after the first frame so the UI renders first
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) checkForUpdates(context);
      });
    });
  }

  @override
  void dispose() {
    appThemeNotifier.removeListener(_onThemeChanged);
    _speedOverlay?.remove();
    super.dispose();
  }

  void _onThemeChanged() => setState(() {});

  // ─── Data ──────────────────────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    setState(() => _isLoadingHistory = true);
    final prefs = await SharedPreferences.getInstance();
    final String? booksJson = prefs.getString('saved_books');
    if (booksJson != null) {
      final List<dynamic> decoded = jsonDecode(booksJson);
      setState(() { _books = decoded.map((item) => BookModel.fromMap(item)).toList(); });
    }
    setState(() => _isLoadingHistory = false);
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_books', jsonEncode(_books.map((b) => b.toMap()).toList()));
  }

  Future<String?> _generatePdfCover(String pdfPath, String bookId) async {
    try {
      final ext = pdfPath.toLowerCase();
      if (ext.endsWith('.txt') || ext.endsWith('.doc') || ext.endsWith('.docx')) return null;
      final document = await pdfx.PdfDocument.openFile(pdfPath);
      final page = await document.getPage(1);
      final pageImage = await page.render(
        width: page.width * 2, height: page.height * 2,
        format: pdfx.PdfPageImageFormat.png,
      );
      await page.close();
      await document.close();
      if (pageImage != null) {
        final appDir = await getApplicationSupportDirectory();
        final coverFolder = Directory(p.join(appDir.path, 'covers'));
        if (!coverFolder.existsSync()) await coverFolder.create(recursive: true);
        final coverFile = File(p.join(coverFolder.path, '$bookId.png'));
        await coverFile.writeAsBytes(pageImage.bytes, flush: true);
        return coverFile.path;
      }
    } catch (e) { debugPrint('[COVER_ERROR] $e'); }
    return null;
  }

  Future<void> _smoothProgress(double target, {int ms = 400}) async {
    final start = _importProgress;
    final steps = (ms / 16).ceil();
    for (int i = 1; i <= steps; i++) {
      if (!mounted) return;
      setState(() { _importProgress = start + (target - start) * i / steps; });
      await Future.delayed(const Duration(milliseconds: 16));
    }
  }

  Future<void> _importNewBook() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'txt', 'doc', 'docx'],
      );
      if (result == null || result.files.single.path == null) return;
      setState(() { _isImporting = true; _importStatus = 'Čtu soubor...'; _importProgress = 0.0; });
      await _smoothProgress(0.08);
      final filePath = result.files.single.path!;
      final file = File(filePath);
      final ext = filePath.toLowerCase();
      int wordCount = 0; int chunkCount = 0;

      if (ext.endsWith('.txt')) {
        setState(() { _importStatus = 'Analyzuji text...'; });
        await _smoothProgress(0.25);
        final content = await file.readAsString();
        final sentences = content.split(RegExp(r'(?<=[.!?])\s+'));
        for (var s in sentences) {
          if (s.trim().isNotEmpty) { wordCount += s.trim().split(RegExp(r'\s+')).length; chunkCount++; }
        }
        await _smoothProgress(0.72);
      } else if (ext.endsWith('.doc') || ext.endsWith('.docx')) {
        // docx: treat as text — SpeechTestView handles actual parsing
        setState(() { _importStatus = 'Čtu Word dokument...'; });
        await _smoothProgress(0.60);
        wordCount = 100; chunkCount = 10; // placeholder; real count done on open
        await _smoothProgress(0.90);
      } else {
        setState(() { _importStatus = 'Čtu PDF...'; });
        await _smoothProgress(0.12);
        final bytes = await file.readAsBytes();
        setState(() { _importStatus = 'Analyzuji strukturu...'; });
        await _smoothProgress(0.20);
        final document = sf.PdfDocument(inputBytes: bytes);
        final extractor = sf.PdfTextExtractor(document);
        final int pageCount = document.pages.count;
        for (int i = 0; i < pageCount; i++) {
          final lines = extractor.extractTextLines(startPageIndex: i, endPageIndex: i);
          for (var line in lines) { wordCount += line.wordCollection.length; chunkCount++; }
          if (i % 3 == 0 || i == pageCount - 1) {
            final prog = 0.20 + 0.50 * ((i + 1) / pageCount);
            setState(() { _importStatus = 'Stránka ${i + 1} / $pageCount'; _importProgress = prog; });
            await Future.delayed(Duration.zero);
          }
        }
        document.dispose();
      }
      setState(() { _importStatus = 'Generuji náhled...'; });
      await _smoothProgress(0.80);
      final bookId = DateTime.now().millisecondsSinceEpoch.toString();
      final String? coverPath = await _generatePdfCover(filePath, bookId);
      setState(() { _importStatus = 'Ukládám...'; });
      await _smoothProgress(0.95);
      final newBook = BookModel(
        id: bookId, filePath: filePath, title: p.basename(filePath),
        totalChunks: chunkCount > 0 ? chunkCount : 1, totalWords: wordCount,
        coverPath: coverPath, lastModelId: null,
      );
      await _smoothProgress(1.0, ms: 150);
      setState(() { _books.insert(0, newBook); _isImporting = false; _importStatus = ''; _importProgress = 0.0; });
      await _saveHistory();
      _openBook(newBook);
    } catch (e) {
      setState(() { _isImporting = false; _importStatus = ''; _importProgress = 0.0; });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import error: $e')));
    }
  }

  void _openBook(BookModel book) async {
    if (!File(book.filePath).existsSync()) { _showFileMissingDialog(book); return; }
    final int targetIdx = _books.indexWhere((b) => b.id == book.id);
    if (targetIdx != -1) {
      setState(() { _books.removeAt(targetIdx); _books.insert(0, book); });
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_books', jsonEncode(_books.map((b) => b.toMap()).toList()));
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => SpeechTestView(book: book)),
    ).then((_) async {
      // Only stop if audio is NOT globally busy (i.e. user stopped in SpeechTestView)
      // If still busy, let it continue — the dashboard AudioPlayerBar will show controls
      if (!globalIsAudioBusy && !Platform.isAndroid && !Platform.isIOS) {
        try { await windowsPlayer.stop(); } catch (_) {}
      }
      // Sync speed from whatever SpeechTestView last used
      if (mounted) {
        final prefs = await SharedPreferences.getInstance();
        final activeId = globalActiveBookId;
        if (activeId != null) {
          final s = prefs.getDouble('speed_$activeId') ?? 1.0;
          setState(() => _playbackSpeed = s);
        } else {
          setState(() {});
        }
      }
    });
  }

  void _showFileMissingDialog(BookModel book) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.folder_off_rounded, color: Colors.orange),
          SizedBox(width: 8),
          Text('Soubor nenalezen'),
        ]),
        content: Text('Soubor „${book.title}" byl přesunut nebo smazán.\n\nCo chcete udělat?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Zrušit')),
          TextButton(
            onPressed: () async { Navigator.pop(ctx); _deleteBook(book); },
            child: Text('Odstranit', style: TextStyle(color: Colors.red.shade600)),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.folder_open_rounded, size: 16),
            label: const Text('Dohledat'),
            onPressed: () async { Navigator.pop(ctx); _showRelinkDialog(book); },
          ),
        ],
      ),
    );
  }

  void _showRelinkDialog(BookModel book) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(children: [Icon(Icons.warning_amber_rounded, color: Colors.amber), SizedBox(width: 8), Text('Soubor nenalezen')]),
        content: Text('Soubor "${book.title}" byl přesunut nebo smazán. Chcete jej znovu dohledat?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Zrušit')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'txt', 'doc', 'docx']);
              if (result != null && result.files.single.path != null) {
                final newPath = result.files.single.path!;
                final String? newCover = await _generatePdfCover(newPath, book.id);
                setState(() { book.filePath = newPath; if (newCover != null) book.coverPath = newCover; });
                await _saveHistory();
                _openBook(book);
              }
            },
            child: const Text('Najít soubor'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(BookModel book) {
    final controller = TextEditingController(text: book.title);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Přejmenovat dokument'),
        content: TextField(controller: controller, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Název')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Zrušit')),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.trim().isNotEmpty) { setState(() { book.title = controller.text.trim(); }); await _saveHistory(); }
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Uložit'),
          ),
        ],
      ),
    );
  }

  Future<void> _openFileLocation(BookModel book) async {
    if (!File(book.filePath).existsSync()) { _showFileMissingDialog(book); return; }
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', book.filePath]);
    } else if (Platform.isAndroid) {
      final folderPath = p.dirname(book.filePath);
      final Uri uri = Uri.parse("content://com.android.externalstorage.documents/document/primary:${p.relative(folderPath, from: '/storage/emulated/0')}");
      if (await canLaunchUrl(uri)) { await launchUrl(uri); return; }
      final Uri backupUri = Uri.parse("file://$folderPath");
      if (await canLaunchUrl(backupUri)) { await launchUrl(backupUri); return; }
    }
    _showLocationFallback(book.filePath);
  }

  void _showLocationFallback(String path) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cesta k souboru'),
        content: SelectableText(path),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Zavřít'))],
      ),
    );
  }

  void _deleteBook(BookModel book) async {
    if (globalActiveBookId == book.id && globalIsAudioBusy) {
      globalIsAudioBusy = false; globalActiveBookId = null;
      if (Platform.isAndroid || Platform.isIOS) { await audioHandler.stop(); } else { await windowsPlayer.stop(); }
    }
    if (book.coverPath != null) { final f = File(book.coverPath!); if (f.existsSync()) f.deleteSync(); }
    try {
      final appDir = await getApplicationSupportDirectory();
      final cacheFile = File(p.join(appDir.path, 'book_cache', '${book.id}.cache'));
      if (cacheFile.existsSync()) cacheFile.deleteSync();
    } catch (e) { debugPrint('Error deleting: $e'); }
    setState(() { _books.removeWhere((b) => b.id == book.id); });
    await _saveHistory();
  }

  void _seekRelative(int seconds) async {
    if (!globalIsAudioBusy) return;
    final player = (Platform.isAndroid || Platform.isIOS) ? audioHandler.player : windowsPlayer;
    final currentPos = player.position;
    final targetPos = currentPos + Duration(seconds: seconds);
    final duration = player.duration;
    if (duration != null) {
      if (targetPos < Duration.zero) { player.seek(Duration.zero); }
      else if (targetPos > duration) { /* let it naturally complete */ }
      else { player.seek(targetPos); }
    }
  }

  // Speed overlay — reuse same pattern as SpeechTestView
  void _toggleSpeedOverlay(BuildContext context) {
    if (_speedOpen) { _closeSpeedOverlay(); } else { _openSpeedOverlay(context); }
  }

  void _openSpeedOverlay(BuildContext context) {
    _speedOverlay?.remove();
    _speedOpen = true;
    if (mounted) setState(() {});
    _speedOverlay = OverlayEntry(builder: (ctx) {
      const List<double> presets = [0.8, 1.0, 1.2, 1.5, 2.0, 2.5];
      return Stack(fit: StackFit.expand, children: [
        SizedBox.expand(child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _closeSpeedOverlay)),
        UnconstrainedBox(child: CompositedTransformFollower(
          link: _speedLayerLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(0, -6),
          child: Material(
            color: Colors.transparent,
            child: StatefulBuilder(builder: (_, setLocal) {
              final bool dm = _isDark;
              return Container(
                width: 192,
                decoration: BoxDecoration(
                  color: dm ? const Color(0xFF2C2C2C) : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 18, offset: const Offset(0, 4))],
                  border: Border.all(color: dm ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade200),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                    child: Row(children: [
                      Icon(Icons.speed_rounded, size: 13, color: dm ? Colors.white54 : const Color(0xFF5F6368)),
                      const SizedBox(width: 5),
                      Expanded(child: Text('Rychlost čtení',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: dm ? Colors.white : const Color(0xFF1F1F1F)))),
                    ]),
                  ),
                  const Divider(height: 1, thickness: 0.5),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                    child: GridView.count(
                      crossAxisCount: 3, shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 2.2,
                      children: presets.map((spd) {
                        final bool active = (_playbackSpeed - spd).abs() < 0.01;
                        return GestureDetector(
                          onTap: () {
                            setState(() => _playbackSpeed = spd);
                            setLocal(() {});
                            SharedPreferences.getInstance().then((p) => p.setDouble('dashboard_speed', spd));
                            if (globalIsAudioBusy) {
                              if (Platform.isAndroid || Platform.isIOS) { audioHandler.player.setSpeed(spd); }
                              else { windowsPlayer.setSpeed(spd); }
                            }
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 100),
                            decoration: BoxDecoration(
                              color: active ? const Color(0xFF1A73E8) : (dm ? const Color(0xFF3C3C3C) : const Color(0xFFF1F3F4)),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            alignment: Alignment.center,
                            child: Text(spd % 1 == 0 ? '${spd.toInt()}x' : '${spd}x',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                                    color: active ? Colors.white : (dm ? Colors.white70 : Colors.black87))),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ]),
              );
            }),
          ),
        )),
      ]);
    });
    Overlay.of(context).insert(_speedOverlay!);
  }

  void _closeSpeedOverlay() {
    _speedOverlay?.remove();
    _speedOverlay = null;
    _speedOpen = false;
    if (mounted) setState(() {});
  }

  void _setTheme(int mode) {
    appThemeNotifier.value = mode;
    SharedPreferences.getInstance().then((p) => p.setInt('theme_mode', mode));
    setState(() {});
  }

  Widget _buildAppBarTitle() {
    return Row(children: [
      Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFF164063),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Image.asset('assets/icon/fg.png', width: 32, height: 32, fit: BoxFit.contain),
      ),
      const SizedBox(width: 10),
      Text('Open Voice Reader', style: TextStyle(
        fontWeight: FontWeight.w700, fontSize: 18, letterSpacing: -0.5,
        color: _isDark ? Colors.white : const Color(0xFF164063),
      )),
    ]);
  }

  // ─── File type icon helper ──────────────────────────────────────────────────
  IconData _fileIcon(String path) {
    final ext = path.toLowerCase();
    if (ext.endsWith('.txt')) return Icons.description_rounded;
    if (ext.endsWith('.doc') || ext.endsWith('.docx')) return Icons.article_rounded;
    return Icons.picture_as_pdf_rounded;
  }
  Color _fileIconColor(String path, bool exists) {
    if (!exists) return Colors.grey;
    final ext = path.toLowerCase();
    if (ext.endsWith('.txt')) return Colors.blue.shade600;
    if (ext.endsWith('.doc') || ext.endsWith('.docx')) return Colors.indigo.shade600;
    return Colors.red.shade600;
  }

  @override
  Widget build(BuildContext context) {
    final cardBg = _isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final scaffoldBg = _isDark ? const Color(0xFF121212) : const Color(0xFFF8F9FA);
    final textPrimary = _isDark ? Colors.white : const Color(0xFF1F1F1F);
    final textSecondary = _isDark ? Colors.white60 : const Color(0xFF5F6368);
    final dividerColor = _isDark ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade200;
    final badgeBg = _isDark ? Colors.white.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.9);

    BookModel? activeBook;
    bool isCompleted = false;
    if (globalActiveBookId != null) {
      final found = _books.where((b) => b.id == globalActiveBookId).toList();
      if (found.isNotEmpty && File(found.first.filePath).existsSync()) {
        activeBook = found.first;
        isCompleted = globalCurrentChunkIndex >= activeBook.totalChunks;
      } else {
        globalActiveBookId = null;
        globalIsAudioBusy = false;
      }
    }
    final double progress = activeBook != null && activeBook.totalChunks > 0
        ? (globalCurrentChunkIndex / activeBook.totalChunks).clamp(0.0, 1.0)
        : 0.0;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: _isDark ? const Color(0xFF1E1E1E) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: Border(bottom: BorderSide(color: dividerColor, width: 1)),
        title: _buildAppBarTitle(),
        actions: [
          // Sponsor button
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SponsorButton(),
          ),
          const SizedBox(width: 4),
          PopupMenuButton<int>(
            tooltip: 'Vzhled',
            icon: Icon(
              appThemeNotifier.value == 0 ? Icons.brightness_auto_rounded
                  : appThemeNotifier.value == 1 ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
              color: appThemeNotifier.value != 0 ? const Color(0xFF1A73E8) : textSecondary,
            ),
            onSelected: _setTheme,
            itemBuilder: (_) => [
              PopupMenuItem(value: 0, child: Row(children: [
                Icon(Icons.brightness_auto_rounded, size: 18, color: appThemeNotifier.value == 0 ? const Color(0xFF1A73E8) : null),
                const SizedBox(width: 10), const Text('Systémový'),
                if (appThemeNotifier.value == 0) ...[const Spacer(), const Icon(Icons.check_rounded, size: 16, color: Color(0xFF1A73E8))],
              ])),
              PopupMenuItem(value: 1, child: Row(children: [
                Icon(Icons.light_mode_rounded, size: 18, color: appThemeNotifier.value == 1 ? const Color(0xFF1A73E8) : null),
                const SizedBox(width: 10), const Text('Světlý'),
                if (appThemeNotifier.value == 1) ...[const Spacer(), const Icon(Icons.check_rounded, size: 16, color: Color(0xFF1A73E8))],
              ])),
              PopupMenuItem(value: 2, child: Row(children: [
                Icon(Icons.dark_mode_rounded, size: 18, color: appThemeNotifier.value == 2 ? const Color(0xFF1A73E8) : null),
                const SizedBox(width: 10), const Text('Tmavý'),
                if (appThemeNotifier.value == 2) ...[const Spacer(), const Icon(Icons.check_rounded, size: 16, color: Color(0xFF1A73E8))],
              ])),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: IgnorePointer(
        ignoring: _isImporting,
        child: Opacity(
          opacity: _isImporting ? 0.5 : 1.0,
          child: CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Import button — dark-mode aware
                  Material(
                    color: _isDark ? const Color(0xFF1E1E1E) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      onTap: _isImporting ? null : _importNewBook,
                      borderRadius: BorderRadius.circular(16),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: double.infinity,
                        height: _isImporting ? 118 : 110,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: _isDark ? const Color(0xFF1A73E8).withValues(alpha: 0.5) : Colors.blue.shade200,
                            width: 1.5,
                          ),
                        ),
                        child: _isImporting
                            ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Row(children: [
                              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1A73E8))),
                              const SizedBox(width: 10),
                              Expanded(child: Text(_importStatus, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Color(0xFF1A73E8)))),
                              Text('${(_importProgress * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: textSecondary)),
                            ]),
                            const SizedBox(height: 8),
                            ClipRRect(borderRadius: BorderRadius.circular(3),
                                child: LinearProgressIndicator(
                                  value: _importProgress, minHeight: 4,
                                  backgroundColor: _isDark ? const Color(0xFF3A3A3A) : Colors.blue.shade50,
                                  color: const Color(0xFF1A73E8),
                                )),
                          ]),
                        )
                            : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: _isDark ? const Color(0xFF1A73E8).withValues(alpha: 0.15) : Colors.blue.shade50,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.add_rounded, size: 28, color: Color(0xFF1A73E8)),
                          ),
                          const SizedBox(height: 10),
                          Text('Otevřít PDF, TXT nebo Word dokument',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14,
                                  color: _isDark ? const Color(0xFF1A73E8) : const Color(0xFF1A73E8))),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Nedávné dokumenty', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: textPrimary)),
                  const SizedBox(height: 10),
                ]),
              ),
            ),
            if (_isLoadingHistory)
              const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
            else if (_books.isEmpty)
              SliverFillRemaining(child: Center(child: Text('Žádné dokumenty k zobrazení.', style: TextStyle(color: textSecondary, fontWeight: FontWeight.w500))))
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 280, mainAxisSpacing: 20, crossAxisSpacing: 20, childAspectRatio: 0.85,
                  ),
                  delegate: SliverChildBuilderDelegate(
                        (context, index) {
                      final book = _books[index];
                      final double bookProgress = book.totalChunks > 0 ? book.lastChunkIndex / book.totalChunks : 0.0;
                      final bool hasCover = book.coverPath != null && File(book.coverPath!).existsSync();

                      return FutureBuilder<bool>(
                        future: File(book.filePath).exists(),
                        builder: (context, snapshot) {
                          final bool exists = snapshot.data ?? true;
                          return Container(
                            decoration: BoxDecoration(
                              color: cardBg,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: _isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE0E0E0), width: 1),
                              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: _isDark ? 0.3 : 0.02), blurRadius: 8, offset: const Offset(0, 2))],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: InkWell(
                                onTap: () => _openBook(book),
                                borderRadius: BorderRadius.circular(16),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Expanded(
                                    child: Stack(children: [
                                      Positioned.fill(
                                        child: !exists
                                            ? Container(
                                          color: _isDark ? const Color(0xFF2C2C2C) : Colors.grey.shade100,
                                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                            Icon(Icons.folder_off_rounded, size: 48, color: Colors.orange.shade400),
                                            const SizedBox(height: 8),
                                            Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 12),
                                              child: Text('Soubor přesunut\nnebo smazán',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.orange.shade600),
                                              ),
                                            ),
                                          ]),
                                        )
                                            : hasCover
                                            ? Image.file(File(book.coverPath!), fit: BoxFit.cover, alignment: Alignment.topCenter)
                                            : Container(
                                          color: _isDark ? const Color(0xFF2A2A2A) : Colors.grey.shade100,
                                          child: Icon(_fileIcon(book.filePath),
                                              color: _fileIconColor(book.filePath, exists), size: 48),
                                        ),
                                      ),
                                      // Type badge — dark bg
                                      Positioned(top: 8, left: 8,
                                        child: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(color: badgeBg, borderRadius: BorderRadius.circular(8)),
                                          child: Icon(_fileIcon(book.filePath),
                                              color: _fileIconColor(book.filePath, exists), size: 16),
                                        ),
                                      ),
                                      // Options menu — dark bg
                                      Positioned(top: 8, right: 8,
                                        child: Container(
                                          decoration: BoxDecoration(color: badgeBg, shape: BoxShape.circle),
                                          child: PopupMenuButton<String>(
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                            icon: Icon(Icons.more_vert_rounded, size: 18,
                                                color: _isDark ? Colors.white70 : const Color(0xFF5F6368)),
                                            onSelected: (value) {
                                              if (value == 'open') _openBook(book);
                                              if (value == 'rename') _showRenameDialog(book);
                                              if (value == 'location') _openFileLocation(book);
                                              if (value == 'relink') _showRelinkDialog(book);
                                              if (value == 'delete') _deleteBook(book);
                                            },
                                            itemBuilder: (context) => [
                                              const PopupMenuItem(value: 'open', child: Row(children: [Icon(Icons.book_outlined, size: 18), SizedBox(width: 10), Text('Otevřít')])),
                                              const PopupMenuItem(value: 'rename', child: Row(children: [Icon(Icons.edit_outlined, size: 18), SizedBox(width: 10), Text('Přejmenovat')])),
                                              const PopupMenuItem(value: 'location', child: Row(children: [Icon(Icons.folder_open_outlined, size: 18), SizedBox(width: 10), Text('Zobrazit umístění')])),
                                              if (!exists) const PopupMenuItem(value: 'relink', child: Row(children: [Icon(Icons.link_outlined, size: 18), SizedBox(width: 10), Text('Dohledat')])),
                                              PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red.shade600), SizedBox(width: 10), Text('Smazat', style: TextStyle(color: Colors.red.shade600, fontWeight: FontWeight.w600))])),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ]),
                                  ),
                                  // Bottom info
                                  Container(
                                    color: cardBg,
                                    padding: const EdgeInsets.all(12.0),
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: exists ? textPrimary : textSecondary)),
                                      const SizedBox(height: 8),
                                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                        Expanded(child: ClipRRect(
                                          borderRadius: BorderRadius.circular(4),
                                          child: LinearProgressIndicator(value: bookProgress.clamp(0.0, 1.0),
                                              backgroundColor: _isDark ? Colors.white.withValues(alpha: 0.1) : Colors.grey.shade100,
                                              color: const Color(0xFF1A73E8), minHeight: 5),
                                        )),
                                        const SizedBox(width: 10),
                                        Text('${(bookProgress * 100).toStringAsFixed(0)}%',
                                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: textSecondary)),
                                      ]),
                                    ]),
                                  ),
                                ]),
                              ),
                            ),
                          );
                        },
                      );
                    },
                    childCount: _books.length,
                  ),
                ),
              ),
          ]),
        ),
      ),
      // Bottom player — uses the same AudioPlayerBar as SpeechTestView
      bottomNavigationBar: activeBook == null ? null : Container(
        decoration: BoxDecoration(
          color: _isDark ? const Color(0xFF1E1E1E) : Colors.white,
          border: Border(top: BorderSide(color: dividerColor, width: 1)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, -3))],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Book title
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(children: [
                Icon(Icons.menu_book_rounded, size: 13, color: const Color(0xFF1A73E8)),
                const SizedBox(width: 6),
                Expanded(child: Text(activeBook.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: textPrimary))),
              ]),
            ),
            // Identical AudioPlayerBar
            AudioPlayerBar(
              isReady: true,
              isBusy: globalIsAudioBusy,
              isCompleted: isCompleted,
              showJumpButton: false,
              progress: progress,
              volume: 1.0,
              playbackSpeed: _playbackSpeed,
              speedOpen: _speedOpen,
              currentChunkIndex: globalCurrentChunkIndex,
              totalChunks: activeBook.totalChunks,
              currentPdfPage: globalCurrentPdfPage,
              totalPdfPages: globalTotalPdfPages,
              isPdfLayout: globalIsOriginalLayout,
              isTxtFile: activeBook.filePath.toLowerCase().endsWith('.txt'),
              etaRead: '',
              etaLeft: '',
              onPlay: () {
                setState(() => globalIsAudioBusy = true);
                if (Platform.isAndroid || Platform.isIOS) { audioHandler.play(); } else { windowsPlayer.play(); }
              },
              onPause: () {
                setState(() => globalIsAudioBusy = false);
                if (Platform.isAndroid || Platform.isIOS) { audioHandler.pause(); } else { windowsPlayer.stop(); }
              },
              onRestart: () {
                setState(() { globalIsAudioBusy = true; globalCurrentChunkIndex = 0; globalCurrentWordIndex = 0; });
                if (Platform.isAndroid || Platform.isIOS) { audioHandler.play(); } else { windowsPlayer.play(); }
              },
              onJump: null,
              onSeekBack: () => _seekRelative(-10),
              onSeekForward: () => _seekRelative(10),
              onMute: null,
              onVolumeChanged: (_) {},
              speedLayerLink: _speedLayerLink,
              onSpeedTap: _toggleSpeedOverlay,
              isDark: _isDark,
            ),
          ]),
        ),
      ),
    );
  }
}