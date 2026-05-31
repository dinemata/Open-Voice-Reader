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

  double _playbackSpeed = 1.0;
  double _volume = 1.0;
  double _preMuteVolume = 1.0;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoadingHistory = true);
    final prefs = await SharedPreferences.getInstance();
    final String? booksJson = prefs.getString('saved_books');
    if (booksJson != null) {
      final List<dynamic> decoded = jsonDecode(booksJson);
      setState(() {
        _books = decoded.map((item) => BookModel.fromMap(item)).toList();
      });
    }
    setState(() => _isLoadingHistory = false);
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_books.map((b) => b.toMap()).toList());
    await prefs.setString('saved_books', encoded);
  }

  Future<String?> _generatePdfCover(String pdfPath, String bookId) async {
    try {
      if (pdfPath.toLowerCase().endsWith('.txt')) return null;
      final document = await pdfx.PdfDocument.openFile(pdfPath);
      final page = await document.getPage(1);
      final pageImage = await page.render(
        width: page.width * 2,
        height: page.height * 2,
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
    } catch (e) {
      debugPrint('[COVER_ERROR] Cover generation failed: $e');
    }
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
      final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'txt']);
      if (result == null || result.files.single.path == null) return;

      setState(() { _isImporting = true; _importStatus = 'Čtu soubor...'; _importProgress = 0.0; });
      await _smoothProgress(0.08);

      final filePath = result.files.single.path!;
      final file = File(filePath);
      int wordCount = 0;
      int chunkCount = 0;

      if (filePath.toLowerCase().endsWith('.txt')) {
        setState(() { _importStatus = 'Analyzuji text...'; });
        await _smoothProgress(0.25);
        final content = await file.readAsString();
        final sentences = content.split(RegExp(r'(?<=[.!?])\s+'));
        for (var sentence in sentences) {
          if (sentence.trim().isNotEmpty) {
            wordCount += sentence.trim().split(RegExp(r'\s+')).length;
            chunkCount++;
          }
        }
        await _smoothProgress(0.72);
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import error: $e')));
    }
  }

  void _openBook(BookModel book) async {
    final int targetIdx = _books.indexWhere((b) => b.id == book.id);
    if (targetIdx != -1) {
      setState(() {
        _books.removeAt(targetIdx);
        _books.insert(0, book);
      });
    }

    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_books.map((b) => b.toMap()).toList());
    await prefs.setString('saved_books', encoded);

    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SpeechTestView(book: book),
      ),
    ).then((_) async {
      if (!Platform.isAndroid && !Platform.isIOS) {
        try { await windowsPlayer.stop(); } catch (_) {}
      }
      if (mounted) setState(() {});
    });
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
              final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'txt']);
              if (result != null && result.files.single.path != null) {
                final newPath = result.files.single.path!;
                final String? newCover = await _generatePdfCover(newPath, book.id);
                setState(() {
                  book.filePath = newPath;
                  if (newCover != null) book.coverPath = newCover;
                });
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
              if (controller.text.trim().isNotEmpty) {
                setState(() { book.title = controller.text.trim(); });
                await _saveHistory();
              }
              Navigator.pop(context);
            },
            child: const Text('Uložit'),
          ),
        ],
      ),
    );
  }

  Future<void> _openFileLocation(BookModel book) async {
    final file = File(book.filePath);
    if (!file.existsSync()) {
      _showRelinkDialog(book);
      return;
    }

    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', book.filePath]);
    } else if (Platform.isAndroid) {
      final folderPath = p.dirname(book.filePath);
      final Uri uri = Uri.parse("content://com.android.externalstorage.documents/document/primary:${p.relative(folderPath, from: '/storage/emulated/0')}");
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        final Uri backupUri = Uri.parse("file://$folderPath");
        if (await canLaunchUrl(backupUri)) {
          await launchUrl(backupUri);
        } else {
          _showLocationFallback(book.filePath);
        }
      }
    } else {
      _showLocationFallback(book.filePath);
    }
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
      globalIsAudioBusy = false;
      globalActiveBookId = null;
      if (Platform.isAndroid || Platform.isIOS) { await audioHandler.stop(); } else { await windowsPlayer.stop(); }
    }
    if (book.coverPath != null) {
      final f = File(book.coverPath!);
      if (f.existsSync()) f.deleteSync();
    }
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
      if (targetPos < Duration.zero) {
        player.seek(Duration.zero);
      } else if (targetPos > duration) {
        _skipToNextChunk();
      } else {
        player.seek(targetPos);
      }
    }
  }

  void _skipToNextChunk() async {
    if (Platform.isAndroid || Platform.isIOS) await audioHandler.stop(); else await windowsPlayer.stop();
    setState(() {
      globalCurrentChunkIndex++;
      globalCurrentWordIndex = 0;
    });
  }

  void _changeSpeed(double speed) async {
    setState(() { _playbackSpeed = speed; });
    if (globalIsAudioBusy) {
      if (Platform.isAndroid || Platform.isIOS) {
        await audioHandler.player.setSpeed(speed);
      } else {
        await windowsPlayer.setSpeed(speed);
      }
    }
  }

  void _changeVolume(double vol) async {
    setState(() { _volume = vol; });
    if (Platform.isAndroid || Platform.isIOS) {
      await audioHandler.player.setVolume(vol);
    } else {
      await windowsPlayer.setVolume(vol);
    }
  }

  void _toggleMute() {
    if (_volume > 0.0) {
      _preMuteVolume = _volume;
      _changeVolume(0.0);
    } else {
      _changeVolume(_preMuteVolume);
    }
  }

  void _restartAudioFromBeginning() async {
    if (Platform.isAndroid || Platform.isIOS) await audioHandler.stop(); else await windowsPlayer.stop();
    setState(() {
      globalIsAudioBusy = true;
      globalCurrentChunkIndex = 0;
      globalCurrentWordIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    BookModel? activeBook;
    bool isCompleted = false;
    String statusText = '';

    if (globalActiveBookId != null) {
      final found = _books.where((b) => b.id == globalActiveBookId).toList();
      if (found.isNotEmpty && File(found.first.filePath).existsSync()) {
        activeBook = found.first;
        isCompleted = globalCurrentChunkIndex >= activeBook.totalChunks;
        if (isCompleted) {
          statusText = 'Completed';
        } else {
          final bool isTxt = activeBook.filePath.toLowerCase().endsWith('.txt');
          statusText = (globalIsOriginalLayout && !isTxt)
              ? 'Page: $globalCurrentPdfPage / $globalTotalPdfPages'
              : 'Block: ${globalCurrentChunkIndex + 1} / ${activeBook.totalChunks}';
        }
      } else {
        globalActiveBookId = null;
        globalIsAudioBusy = false;
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Image.asset(
              'assets/icon/fg.png',
              width: 36,
              height: 36,
              fit: BoxFit.contain,
            ),
            const Text(
              'Open Voice Reader',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                letterSpacing: -0.5,
                color: Color(0xFF164063),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: Border(bottom: BorderSide(color: Colors.grey.shade200, width: 1)),
      ),
      body: IgnorePointer(
        ignoring: _isImporting,
        child: Opacity(
          opacity: _isImporting ? 0.5 : 1.0,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Material(
                        color: Colors.white,
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
                              border: Border.all(color: Colors.blue.shade200, width: 1.5),
                            ),
                            child: _isImporting
                                ? Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                Row(children: [
                                  const SizedBox(width: 16, height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1A73E8))),
                                  const SizedBox(width: 10),
                                  Expanded(child: Text(_importStatus,
                                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Color(0xFF1A73E8)))),
                                  Text('${(_importProgress * 100).toStringAsFixed(0)}%',
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF5F6368))),
                                ]),
                                const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: _importProgress, minHeight: 4,
                                    backgroundColor: Colors.blue.shade50,
                                    color: const Color(0xFF1A73E8),
                                  ),
                                ),
                              ]),
                            )
                                : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(color: Colors.blue.shade50, shape: BoxShape.circle),
                                child: const Icon(Icons.add_rounded, size: 28, color: Color(0xFF1A73E8)),
                              ),
                              const SizedBox(height: 10),
                              const Text('Otevřít nový PDF nebo TXT dokument',
                                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF1A73E8))),
                            ]),
                          ),
                        ),
                      ),
                      const SizedBox(height: 36),
                      const Text('Nedávné dokumenty', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: Color(0xFF1F1F1F))),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
              if (_isLoadingHistory)
                const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
              else if (_books.isEmpty)
                const SliverFillRemaining(child: Center(child: Text('Žádné dokumenty k zobrazení.', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500))))
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
                        final double progress = book.totalChunks > 0 ? book.lastChunkIndex / book.totalChunks : 0.0;
                        final bool hasCover = book.coverPath != null && File(book.coverPath!).existsSync();
                        final bool isTxt = book.filePath.toLowerCase().endsWith('.txt');

                        return FutureBuilder<bool>(
                          future: File(book.filePath).exists(),
                          builder: (context, snapshot) {
                            final bool exists = snapshot.data ?? true;
                            return Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: const Color(0xFFE0E0E0), width: 1),
                                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: InkWell(
                                  onTap: () => _openBook(book),
                                  borderRadius: BorderRadius.circular(16),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Stack(
                                          children: [
                                            Positioned.fill(
                                              child: hasCover
                                                  ? Image.file(File(book.coverPath!), fit: BoxFit.cover, alignment: Alignment.topCenter)
                                                  : Container(
                                                color: isTxt ? const Color(0xFFE8F0FE) : Colors.grey.shade100,
                                                child: Icon(
                                                  isTxt ? Icons.description_rounded : Icons.picture_as_pdf_rounded,
                                                  color: exists ? (isTxt ? Colors.blue.shade600 : Colors.red.shade300) : Colors.grey.shade400,
                                                  size: 48,
                                                ),
                                              ),
                                            ),
                                            Positioned(
                                              top: 8, left: 8,
                                              child: Container(
                                                padding: const EdgeInsets.all(6),
                                                decoration: BoxDecoration(color: Colors.white.withOpacity(0.9), borderRadius: BorderRadius.circular(8)),
                                                child: Icon(
                                                  isTxt ? Icons.description_rounded : Icons.picture_as_pdf_rounded,
                                                  color: exists ? (isTxt ? Colors.blue.shade700 : Colors.red.shade600) : Colors.grey,
                                                  size: 16,
                                                ),
                                              ),
                                            ),
                                            if (!exists)
                                              Positioned(
                                                top: 8, left: 40,
                                                child: Container(
                                                  padding: const EdgeInsets.all(4),
                                                  decoration: BoxDecoration(color: Colors.amber.shade50, shape: BoxShape.circle),
                                                  child: Icon(Icons.warning_amber_rounded, color: Colors.amber.shade900, size: 16),
                                                ),
                                              ),
                                            Positioned(
                                              top: 8, right: 8,
                                              child: Container(
                                                decoration: BoxDecoration(color: Colors.white.withOpacity(0.9), shape: BoxShape.circle),
                                                child: PopupMenuButton<String>(
                                                  padding: EdgeInsets.zero,
                                                  constraints: const BoxConstraints(),
                                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                                  icon: const Icon(Icons.more_vert_rounded, size: 18, color: Color(0xFF5F6368)),
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
                                          ],
                                        ),
                                      ),
                                      Container(
                                        color: Colors.white,
                                        padding: const EdgeInsets.all(12.0),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: exists ? const Color(0xFF1F1F1F) : Colors.grey.shade600)),
                                            const SizedBox(height: 8),
                                            Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                              children: [
                                                Expanded(
                                                  child: ClipRRect(
                                                    borderRadius: BorderRadius.circular(4),
                                                    child: LinearProgressIndicator(
                                                      value: progress.clamp(0.0, 1.0),
                                                      backgroundColor: Colors.grey.shade100, color: const Color(0xFF1A73E8),
                                                      minHeight: 5,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Text('${(progress * 100).toStringAsFixed(0)}%', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF757575))),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                      childCount: _books.length,
                    ),
                  ),
                )],
          ),
        ),
      ),
      bottomNavigationBar: activeBook == null
          ? null
          : Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Colors.grey.shade200, width: 1)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, -3))],
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          activeBook.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF1F1F1F)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          statusText,
                          style: const TextStyle(fontSize: 11, color: Color(0xFF5F6368), fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(color: const Color(0xFFF1F3F4), borderRadius: BorderRadius.circular(6)),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<double>(
                        value: _playbackSpeed,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF1F1F1F)),
                        onChanged: (val) {
                          if (val != null) _changeSpeed(val);
                        },
                        items: [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 3.5, 4.0].map((s) => DropdownMenuItem(value: s, child: Text('${s}x'))).toList(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Stack(
                alignment: Alignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.replay_10_rounded, size: 26),
                        onPressed: globalIsAudioBusy ? () => _seekRelative(-10) : null,
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 48, height: 48,
                        child: Center(
                          child: Material(
                            type: MaterialType.transparency,
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () {
                                if (isCompleted) {
                                  _restartAudioFromBeginning();
                                  return;
                                }
                                setState(() {
                                  globalIsAudioBusy = !globalIsAudioBusy;
                                });
                                if (!globalIsAudioBusy) {
                                  if (Platform.isAndroid || Platform.isIOS) audioHandler.stop(); else windowsPlayer.stop();
                                } else {
                                  final file = File(activeBook!.filePath);
                                  if (file.existsSync()) {
                                    if (Platform.isAndroid || Platform.isIOS) audioHandler.play(); else windowsPlayer.play();
                                  }
                                }
                              },
                              child: isCompleted
                                  ? const Icon(Icons.replay_rounded, color: Color(0xFF1A73E8), size: 44)
                                  : Icon(
                                globalIsAudioBusy ? Icons.pause_circle_filled_rounded : Icons.play_circle_filled_rounded,
                                color: globalIsAudioBusy ? Colors.red.shade600 : const Color(0xFF1A73E8),
                                size: 44,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(Icons.forward_10_rounded, size: 26),
                        onPressed: globalIsAudioBusy ? () => _seekRelative(10) : null,
                      ),
                    ],
                  ),
                  Positioned(
                    right: 0,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Icon(
                            _volume == 0.0
                                ? Icons.volume_off_rounded
                                : (_volume < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
                            size: 16,
                            color: const Color(0xFF5F6368),
                          ),
                          onPressed: _toggleMute,
                        ),
                        SizedBox(
                          width: 75,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                              overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
                            ),
                            child: Slider(
                              value: _volume,
                              min: 0.0,
                              max: 1.0,
                              activeColor: Theme.of(context).colorScheme.primary,
                              inactiveColor: Colors.grey.shade300,
                              onChanged: (val) => _changeVolume(val),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}