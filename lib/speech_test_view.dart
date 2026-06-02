import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:pdfx/pdfx.dart';

import 'model.dart';
import 'main.dart';
import 'text_sanitizer.dart';
import 'dictionary_jirka.dart';

int globalCurrentChunkIndex = 0;
int globalCurrentWordIndex = 0;
bool globalIsAudioBusy = false;
String? globalActiveBookId;
bool globalIsOriginalLayout = false;
int globalCurrentPdfPage = 1;
int globalTotalPdfPages = 1;

List<PdfChunkMetadata> globalCachedChunks = [];
sf.PdfDocument? globalCachedDocument;

class RenderedPdfPage {
  final int pageNumber;
  final ui.Image image;
  final double widthPt;
  final double heightPt;

  const RenderedPdfPage({
    required this.pageNumber,
    required this.image,
    required this.widthPt,
    required this.heightPt,
  });
}

class PdfRenderService {
  PdfDocument? _doc;

  Future<void> open(String filePath) async {
    _doc = await PdfDocument.openFile(filePath);
  }

  int get pageCount => _doc?.pagesCount ?? 0;

  Future<RenderedPdfPage> renderPage(int pageNumber, double renderWidth) async {
    final page = await _doc!.getPage(pageNumber);
    final scale = renderWidth / page.width;
    final renderHeight = page.height * scale;

    final pageImage = await page.render(
      width: renderWidth,
      height: renderHeight,
      format: PdfPageImageFormat.png,
      backgroundColor: '#FFFFFF',
    );

    final uiImage = await decodeImageFromList(pageImage!.bytes);

    final double widthPt = page.width;
    final double heightPt = page.height;

    await page.close();

    return RenderedPdfPage(
      pageNumber: pageNumber,
      image: uiImage,
      widthPt: widthPt,
      heightPt: heightPt,
    );
  }

  Future<void> dispose() async {
    await _doc?.close();
  }
}

class HighlightPainter extends CustomPainter {
  final List<Rect> sentenceRects;
  final Rect? wordRect;
  final Color sentenceColor;
  final Color wordColor;

  const HighlightPainter({
    required this.sentenceRects,
    this.wordRect,
    this.sentenceColor = const Color(0x331A73E8),
    this.wordColor = const Color(0x881A73E8),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sentencePaint = Paint()..color = sentenceColor;
    for (final r in sentenceRects) {
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)), sentencePaint);
    }
    if (wordRect != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(wordRect!, const Radius.circular(3)),
        Paint()..color = wordColor,
      );
    }
  }

  @override
  bool shouldRepaint(HighlightPainter old) =>
      old.sentenceRects != sentenceRects || old.wordRect != wordRect;
}

class PdfPageWidget extends StatelessWidget {
  final RenderedPdfPage page;
  final double displayWidth;
  final List<PdfChunkMetadata> chunks;
  final int currentChunkIndex;
  final int currentWordIndex;
  final int? pendingChunkIndex;
  final bool isBusy;
  final Color primaryColor;
  final void Function(int chunkIndex, int wordIndex) onTap;

  const PdfPageWidget({
    super.key,
    required this.page,
    required this.displayWidth,
    required this.chunks,
    required this.currentChunkIndex,
    required this.currentWordIndex,
    this.pendingChunkIndex,
    required this.isBusy,
    required this.primaryColor,
    required this.onTap,
  });

  Rect _toScreen(Rect ptRect) {
    final scale = displayWidth / page.widthPt;
    return Rect.fromLTWH(
      ptRect.left * scale,
      ptRect.top * scale,
      ptRect.width * scale,
      ptRect.height * scale,
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayHeight = displayWidth * page.heightPt / page.widthPt;

    final List<Rect> sentenceRects = [];
    final List<Rect> pendingRects = [];
    Rect? wordRect;

    for (int ci = 0; ci < chunks.length; ci++) {
      final chunk = chunks[ci];
      if (chunk.pageNumber != page.pageNumber) continue;

      // Active (blue) highlight
      if (ci == currentChunkIndex) {
        for (int wi = 0; wi < chunk.pdfWords.length; wi++) {
          final screenRect = _toScreen(chunk.pdfWords[wi].bounds);
          sentenceRects.add(screenRect);
          if (isBusy && wi == currentWordIndex) wordRect = screenRect;
        }
      }

      // Pending (orange) flash
      if (pendingChunkIndex != null && ci == pendingChunkIndex) {
        for (final w in chunk.pdfWords) {
          pendingRects.add(_toScreen(w.bounds));
        }
      }
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) => _handleTap(details.localPosition),
      child: SizedBox(
        width: displayWidth,
        height: displayHeight,
        child: Stack(
          children: [
            RawImage(
              image: page.image,
              width: displayWidth,
              height: displayHeight,
              fit: BoxFit.fill,
            ),
            if (pendingRects.isNotEmpty)
              CustomPaint(
                size: Size(displayWidth, displayHeight),
                painter: HighlightPainter(
                  sentenceRects: pendingRects,
                  wordRect: null,
                  sentenceColor: Colors.orange.withOpacity(0.35),
                  wordColor: Colors.orange.withOpacity(0.6),
                ),
              ),
            CustomPaint(
              size: Size(displayWidth, displayHeight),
              painter: HighlightPainter(
                sentenceRects: sentenceRects,
                wordRect: wordRect,
                sentenceColor: primaryColor.withOpacity(0.22),
                wordColor: primaryColor.withOpacity(0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleTap(Offset localPos) {
    final scale = displayWidth / page.widthPt;
    final ptPos = Offset(localPos.dx / scale, localPos.dy / scale);

    for (int ci = 0; ci < chunks.length; ci++) {
      final chunk = chunks[ci];
      if (chunk.pageNumber != page.pageNumber) continue;
      for (int wi = 0; wi < chunk.pdfWords.length; wi++) {
        if (chunk.pdfWords[wi].bounds.contains(ptPos)) {
          onTap(ci, wi);
          return;
        }
      }
    }
  }
}

class SpeechTestView extends StatefulWidget {
  final BookModel book;
  const SpeechTestView({super.key, required this.book});

  @override
  State<SpeechTestView> createState() => _SpeechTestViewState();
}

class _SpeechTestViewState extends State<SpeechTestView> {
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();
  final ValueNotifier<HighlightData> _highlightNotifier = ValueNotifier<HighlightData>(HighlightData(sentenceRects: []));
  final FocusNode _keyboardFocusNode = FocusNode();
  final TransformationController _transformationController = TransformationController();
  final ScrollController _pdfVertScrollController = ScrollController();
  final ScrollController _pdfHorizScrollController = ScrollController();

  StreamSubscription? _playbackStateSubscription;
  StreamSubscription? _positionSubscription;

  sf.PdfDocument? _loadedDocument;
  bool _isReady = false;
  bool _isParsingPdf = false;
  bool _isBufferingNext = false;
  bool _needsModelSelection = true;
  bool _stopAtEndOfBlock = false;
  ModelConfig _selectedModel = availableModels.first;
  final List<PdfChunkMetadata> _chunksMetadata = [];
  int? _selectedChunkIndex;
  bool _isUserScrolling = false;
  bool _isProgrammaticScrolling = false;
  final Map<int, String> _pregeneratedAudioCache = {};

  final SanitizerOptions _sanitizerOptions = SanitizerOptions(
    readParentheses: true, readLinks: true, readPageNumbers: true,
  );
  bool _skipParentheses = false;
  bool _skipLinks = false;
  bool _skipPageNumbers = false;

  double _textZoomFactor = 2.0;   // default; 2.0 displays as 100%
  double _textBaselineZoom = 2.0; // "100 %" reference for text view
  double _pdfZoomFactor = 0.5;
  double _pdfBaselineZoom = 0.7; // "100%" reference, computed from screen width in initState
  final double _zoomStep = 0.1;
  final double _minZoom = 0.2;
  final double _maxZoom = 5.0;

  double _playbackSpeed = 1.0;
  double _volume = 1.0;
  double _preMuteVolume = 1.0;
  bool _isFullscreen = false;
  double _parsingProgress = 0.0;

  bool _isMaxZoomReached = false;
  bool _isMinZoomReached = false;
  String _loadingStatusText = "Inicializace...";

  final List<RenderedPdfPage> _renderedPages = [];
  final PdfRenderService _pdfRenderService = PdfRenderService();
  bool _isPagesRendering = false;

  final List<int> _chunkHeadingLevels = [];
  int? _pendingJumpIndex;
  Timer? _pendingJumpTimer;
  bool _tocOpen = false;
  bool _speedOpen = false;
  final LayerLink _speedLayerLink = LayerLink();
  OverlayEntry? _speedOverlay;

  // Auto speed increase feature
  bool _autoSpeedIncrease = false;
  int _wordsReadSinceSpeedIncrease = 0;
  static const int _autoSpeedWordInterval = 650;
  static const double _autoSpeedStep = 0.25;

  bool get _isTxtFile => widget.book.filePath.toLowerCase().endsWith('.txt');
  double get _currentZoomFactor => globalIsOriginalLayout ? _pdfZoomFactor : _textZoomFactor;

  @override
  void initState() {
    super.initState();

    if (globalActiveBookId == widget.book.id) {
      _currentChunkIndex = globalCurrentChunkIndex;
      _currentWordIndex = globalCurrentWordIndex;
      _isBusy = globalIsAudioBusy;
    } else {
      _currentChunkIndex = widget.book.lastChunkIndex;
      _currentWordIndex = 0;
      _isBusy = false;
    }

    if (widget.book.lastModelId != null) {
      _needsModelSelection = false;
      final found = availableModels.firstWhere(
            (m) => m.id == widget.book.lastModelId,
        orElse: () => availableModels.first,
      );
      _selectedModel = found;
      _initEngineAndLoadPdf();
    }

    _itemPositionsListener.itemPositions.addListener(_scrollListener);
    _setupAudioListeners();
    // Load saved speed and PDF scroll listener
    SharedPreferences.getInstance().then((prefs) {
      final savedSpeed = prefs.getDouble('speed_${widget.book.id}');
      final savedAutoSpeed = prefs.getBool('auto_speed_${widget.book.id}') ?? false;
      if (mounted) setState(() {
        if (savedSpeed != null) _playbackSpeed = savedSpeed;
        _autoSpeedIncrease = savedAutoSpeed;
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pdfVertScrollController.addListener(_onPdfScroll);
      _pdfHorizScrollController.addListener(_onPdfScroll);
      // Compute screen-adaptive baseline zoom: ~0.8 on a 400 px wide screen,
      // scaling proportionally so smaller screens get a larger baseline fraction.
      // Formula: baseline = (referenceWidth / screenWidth) * referenceBaseline
      // where referenceWidth=400, referenceBaseline=0.8 → clamped [0.5, 1.0].
      if (mounted) {
        final screenW = MediaQuery.of(context).size.width;
        final baseline = ((400.0 / screenW) * 0.8).clamp(0.5, 1.0);
        setState(() {
          _pdfBaselineZoom = baseline;
          _pdfZoomFactor = baseline; // start at 100 %
        });
      }
    });
  }

  void _onPdfScroll() {
    if (_isProgrammaticScrolling) return;
    if (!_isUserScrolling) setState(() { _isUserScrolling = true; });
  }

  void _setupAudioListeners() {
    _playbackStateSubscription?.cancel();
    _positionSubscription?.cancel();

    if (Platform.isAndroid || Platform.isIOS) {
      _playbackStateSubscription = audioHandler.playbackState.listen((state) {
        if (!mounted) return;
        if (state.processingState == AudioProcessingState.completed && _isBusy) {
          if (_stopAtEndOfBlock) {
            _stopAudioAndPop();
          } else {
            _handleTrackComplete();
          }
        }
      });
      _positionSubscription = audioHandler.player.positionStream.listen((p) => _updateWordHighlight(p));
    } else {
      _playbackStateSubscription = windowsPlayer.processingStateStream.listen((state) {
        if (!mounted) return;
        if (state == ProcessingState.completed && _isBusy) {
          if (_stopAtEndOfBlock) {
            _stopAudioAndPop();
          } else {
            _handleTrackComplete();
          }
        }
      });
      _positionSubscription = windowsPlayer.positionStream.listen((p) => _updateWordHighlight(p));
    }
  }

  void _stopAudioAndPop() async {
    _isBusy = false;
    if (Platform.isAndroid || Platform.isIOS) await audioHandler.stop(); else await windowsPlayer.stop();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _playbackStateSubscription?.cancel();
    _positionSubscription?.cancel();
    _pendingJumpTimer?.cancel();
    _itemPositionsListener.itemPositions.removeListener(_scrollListener);
    _pdfVertScrollController.removeListener(_onPdfScroll);
    _pdfHorizScrollController.removeListener(_onPdfScroll);
    _highlightNotifier.dispose();
    _keyboardFocusNode.dispose();
    _transformationController.dispose();
    _pdfVertScrollController.dispose();
    _pdfHorizScrollController.dispose();
    _speedOverlay?.remove();
    unawaited(_pdfRenderService.dispose());
    super.dispose();
  }

  void _scrollListener() {
    if (_chunksMetadata.isEmpty || _isParsingPdf || _isProgrammaticScrolling || globalIsOriginalLayout) return;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    // Only flag user-scrolling if the current chunk has slipped out of view
    // and we are not in the middle of a programmatic scroll
    final bool currentVisible = positions.any((p) => p.index == _currentChunkIndex);
    if (!currentVisible && !_isUserScrolling) {
      setState(() { _isUserScrolling = true; });
    }
  }

  int get _currentChunkIndex => globalCurrentChunkIndex;
  set _currentChunkIndex(int val) => globalCurrentChunkIndex = val;
  int get _currentWordIndex => globalCurrentWordIndex;
  set _currentWordIndex(int val) => globalCurrentWordIndex = val;
  bool get _isBusy => globalIsAudioBusy;
  set _isBusy(bool val) => globalIsAudioBusy = val;

  Future<void> _selectInitialModel(ModelConfig model) async {
    setState(() {
      _selectedModel = model;
      _needsModelSelection = false;
    });
    widget.book.lastModelId = model.id;
    final prefs = await SharedPreferences.getInstance();
    final String? booksJson = prefs.getString('saved_books');
    if (booksJson != null) {
      final List<dynamic> decoded = jsonDecode(booksJson);
      final List<BookModel> list = decoded.map((item) => BookModel.fromMap(item)).toList();
      final idx = list.indexWhere((b) => b.id == widget.book.id);
      if (idx != -1) {
        list[idx].lastModelId = model.id;
        await prefs.setString('saved_books', jsonEncode(list.map((b) => b.toMap()).toList()));
      }
    }
    _initEngineAndLoadPdf();
  }

  Future<void> _renderAllPages(double displayWidth) async {
    if (_isPagesRendering || _isTxtFile) return;
    _isPagesRendering = true;
    _renderedPages.clear();
    await _pdfRenderService.open(widget.book.filePath);

    for (int i = 1; i <= globalTotalPdfPages; i++) {
      final renderRes = (displayWidth * 1.0).clamp(400.0, 700.0);
      final rendered = await _pdfRenderService.renderPage(i, renderRes);
      if (!mounted) return;
      setState(() => _renderedPages.add(rendered));
    }
    _isPagesRendering = false;
  }

  Future<void> _initEngineAndLoadPdf() async {
    if (globalActiveBookId == widget.book.id && globalCachedChunks.isNotEmpty) {
      setState(() {
        _parsingProgress = 0.9;
        _loadingStatusText = "Přenáším text do čtečky...";
      });

      _chunksMetadata.clear();
      _chunksMetadata.addAll(globalCachedChunks);
      _loadedDocument = globalCachedDocument;

      await _initEngine();

      setState(() {
        _parsingProgress = 1.0;
        _isReady = true;
        _isParsingPdf = false;
      });
      _computeHeadingLevels();
      if (!_isTxtFile && _renderedPages.isEmpty) _renderAllPages(MediaQuery.of(context).size.width - 96.0);
      _recenterToCurrentChunk();
      return;
    }

    if (globalActiveBookId != null && globalActiveBookId != widget.book.id) {
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        await audioHandler.stop();
      } else {
        await windowsPlayer.stop();
      }
      globalIsAudioBusy = false;
      globalCurrentChunkIndex = 0;
      globalCurrentWordIndex = 0;
      _currentChunkIndex = 0;
      _currentWordIndex = 0;

      globalCachedChunks.clear();
      globalCachedDocument = null;
      _chunksMetadata.clear();
    }

    setState(() {
      _isParsingPdf = true;
      _isReady = false;
      _parsingProgress = 0.0;
      _loadingStatusText = "Chystám soubor...";
    });

    globalActiveBookId = widget.book.id;

    await _initEngine();

    final diskCache = await _loadCacheFromDisk(widget.book.id);
    if (diskCache != null && diskCache.isNotEmpty) {
      setState(() {
        _parsingProgress = 0.9;
        _loadingStatusText = "Načítám uloženou strukturu z disku...";
      });

      _chunksMetadata.clear();
      _chunksMetadata.addAll(diskCache);
      globalCachedChunks = List.from(_chunksMetadata);

      if (!_isTxtFile) {
        try {
          final file = File(widget.book.filePath);
          final bytes = await file.readAsBytes();
          _loadedDocument = sf.PdfDocument(inputBytes: bytes);
          globalTotalPdfPages = _loadedDocument!.pages.count;
          globalCachedDocument = _loadedDocument;
        } catch (_) {}
      }

      setState(() {
        _parsingProgress = 1.0;
        _isReady = true;
        _isParsingPdf = false;
      });
      _computeHeadingLevels();
      if (!_isTxtFile && _renderedPages.isEmpty) _renderAllPages(MediaQuery.of(context).size.width - 96.0);
      _recenterToCurrentChunk();
      return;
    }

    try {
      final file = File(widget.book.filePath);
      if (!await file.exists()) throw Exception("File does not exist.");

      if (_isTxtFile) {
        setState(() {
          _loadingStatusText = "Rozřazuji text do odstavců...";
        });
        final content = await file.readAsString();
        final List<PdfChunkMetadata> tempTxtChunks = [];

        _parseTxtWithProgress(content).listen(
              (progressValue) {
            if (!mounted) return;
            setState(() { _parsingProgress = progressValue; });
          },
          onDone: () async {
            if (!mounted) return;

            if (tempTxtChunks.isEmpty) {
              tempTxtChunks.add(PdfChunkMetadata(text: "Soubor neobsahuje žádný text.", pageNumber: 1, pdfWords: []));
            }

            _chunksMetadata.clear();
            _chunksMetadata.addAll(tempTxtChunks);
            globalCachedChunks = List.from(_chunksMetadata);
            globalCachedDocument = null;

            await _saveCacheToDisk(widget.book.id, _chunksMetadata);

            setState(() {
              globalTotalPdfPages = 1;
              _isReady = true;
              _isParsingPdf = false;
            });
            _computeHeadingLevels();
            _recenterToCurrentChunk();
          },
        );
      } else {
        setState(() {
          _loadingStatusText = "Mapuji strukturu stránek...";
        });
        final bytes = await file.readAsBytes();
        _loadedDocument = sf.PdfDocument(inputBytes: bytes);
        globalTotalPdfPages = _loadedDocument!.pages.count;
        globalCachedDocument = _loadedDocument;

        setState(() {
          _loadingStatusText = "Zaměřuji pozici slov pro zvýrazňování textu...";
        });

        final List<PdfChunkMetadata> tempPdfChunks = [];

        TextSanitizer.parsePdfWithProgress(
          bytes: bytes,
          chunksTarget: tempPdfChunks,
          options: _sanitizerOptions,
          onChunkReady: () {},
        ).listen(
              (progressValue) {
            if (!mounted) return;
            setState(() { _parsingProgress = progressValue; });
          },
          onDone: () async {
            if (!mounted) return;

            if (tempPdfChunks.isEmpty) {
              tempPdfChunks.add(PdfChunkMetadata(text: "PDF neobsahuje žádný text.", pageNumber: 1, pdfWords: []));
            }

            _chunksMetadata.clear();
            _chunksMetadata.addAll(tempPdfChunks);
            globalCachedChunks = List.from(_chunksMetadata);

            await _saveCacheToDisk(widget.book.id, _chunksMetadata);

            setState(() {
              _isReady = true;
              _isParsingPdf = false;
            });
            _computeHeadingLevels();
            if (_renderedPages.isEmpty) _renderAllPages(MediaQuery.of(context).size.width - 96.0);
            _recenterToCurrentChunk();
          },
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isParsingPdf = false;
          _isReady = true;
        });
      }
    }
  }

  Stream<double> _parseTxtWithProgress(String content) async* {
    _chunksMetadata.clear();
    _pregeneratedAudioCache.clear();

    final sanitizedContent = TextSanitizer.sanitizeText(content, _sanitizerOptions);
    final List<String> rawSentences = sanitizedContent.split(RegExp(r'(?<=[.!?])\s+'));
    final int total = rawSentences.length;

    for (int i = 0; i < total; i++) {
      final clean = rawSentences[i].trim();
      if (clean.isNotEmpty) {
        _chunksMetadata.add(PdfChunkMetadata(text: clean, pageNumber: 1, pdfWords: []));
      }
      if (i % 5 == 0 || i == total - 1) {
        yield (i + 1) / total;
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }
  }

  void _updateWordHighlight(Duration position) {
    if (!mounted || !_isBusy || _chunksMetadata.isEmpty || _currentChunkIndex >= _chunksMetadata.length) return;
    final currentChunk = _chunksMetadata[_currentChunkIndex];
    List<String> words = currentChunk.text.split(' ');
    if (words.isEmpty) return;
    final totalDuration = (Platform.isAndroid || Platform.isIOS) ? audioHandler.player.duration : windowsPlayer.duration;
    if (totalDuration == null || totalDuration.inMilliseconds == 0) return;
    double progress = position.inMilliseconds / totalDuration.inMilliseconds;
    int calculatedWordIndex = (progress * words.length).floor();
    if (calculatedWordIndex != _currentWordIndex && calculatedWordIndex < words.length) {
      setState(() { _currentWordIndex = calculatedWordIndex; });
    }
  }

  void _handleTrackComplete() async {
    if (_autoSpeedIncrease && _currentChunkIndex < _chunksMetadata.length) {
      final words = _chunksMetadata[_currentChunkIndex].text.trim().split(RegExp(r'\s+')).length;
      _wordsReadSinceSpeedIncrease += words;
      if (_wordsReadSinceSpeedIncrease >= _autoSpeedWordInterval) {
        _wordsReadSinceSpeedIncrease -= _autoSpeedWordInterval;
        final newSpeed = (_playbackSpeed + _autoSpeedStep).clamp(0.5, 4.0);
        if (newSpeed != _playbackSpeed) _changeSpeed(newSpeed);
      }
    }
    _currentWordIndex = 0;
    _currentChunkIndex++;
    _saveCurrentProgress();
    _executeChunkReading();
  }

  void _skipToNextFailedChunk() {
    _currentWordIndex = 0;
    _currentChunkIndex++;
    _saveCurrentProgress();
    _executeChunkReading();
  }

  Future<void> _saveCurrentProgress() async {
    widget.book.lastChunkIndex = _currentChunkIndex;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('speed_${widget.book.id}', _playbackSpeed);
    final String? booksJson = prefs.getString('saved_books');
    if (booksJson != null) {
      final List<dynamic> decoded = jsonDecode(booksJson);
      final List<BookModel> list = decoded.map((item) => BookModel.fromMap(item)).toList();
      final idx = list.indexWhere((b) => b.id == widget.book.id);
      if (idx != -1) {
        list[idx].lastChunkIndex = _currentChunkIndex;
        await prefs.setString('saved_books', jsonEncode(list.map((b) => b.toMap()).toList()));
      }
    }
  }

  Future<String> _prepareFile(String assetPath, {String? targetPath}) async {
    try {
      final byteData = await rootBundle.load(assetPath);
      final directory = await getApplicationSupportDirectory();
      final finalPath = targetPath ?? assetPath;
      final file = File('${directory.path}/$finalPath');
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      final buffer = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
      await file.writeAsBytes(buffer, flush: true);
      return file.path.replaceAll('\\', '/');
    } catch (e) {
      return "";
    }
  }

  Future<void> _initEngine() async {
    if (globalCurrentModelId == _selectedModel.id && globalTts != null) {
      return;
    }

    setState(() {
      _loadingStatusText = "Připravuji hlasový engine...";
    });

    try {
      final directory = await getApplicationSupportDirectory();
      const esSub = 'shared-espeak-ng-data';
      final esAssetDir = 'assets/models/kokoro-en-v0_19/espeak-ng-data';

      final File checkFile = File('${directory.path}/$esSub/phontab');
      if (!await checkFile.exists()) {
        setState(() {
          _loadingStatusText = "Konfiguruji jazykové sady (může trvat chvíli)...";
        });

        await _prepareFile('$esAssetDir/phontab', targetPath: '$esSub/phontab');
        await _prepareFile('$esAssetDir/phondata', targetPath: '$esSub/phondata');
        await _prepareFile('$esAssetDir/phondata-manifest', targetPath: '$esSub/phondata-manifest');
        await _prepareFile('$esAssetDir/phonindex', targetPath: '$esSub/phonindex');
        await _prepareFile('$esAssetDir/intonations', targetPath: '$esSub/intonations');
        await _prepareFile('$esAssetDir/en_dict', targetPath: '$esSub/en_dict');
        await _prepareFile('assets/models/vits-piper-cs_CZ-jirka-medium/espeak-ng-data/cs_dict', targetPath: '$esSub/cs_dict');
        await _prepareFile('$esAssetDir/lang/gmw/en', targetPath: '$esSub/lang/gmw/en');
        await _prepareFile('$esAssetDir/lang/gmw/en-US', targetPath: '$esSub/lang/gmw/en-US');

        final voicesDir = Directory('${directory.path}/$esSub/voices');
        if (!await voicesDir.exists()) await voicesDir.create(recursive: true);
        await File('${voicesDir.path}/cs').writeAsString("name cs\nlanguage cs\n");
        await File('${voicesDir.path}/en-us').writeAsString("name en-us\nlanguage en-us\n");
      }

      // Always copy model-specific files so switching models always gets correct data
      const alanAssetDir = 'assets/models/vits-piper-en_GB-alan-medium/espeak-ng-data';
      if (_selectedModel.id == 'en_alan') {
        await _prepareFile('$alanAssetDir/en_dict', targetPath: '$esSub/en_dict');
        await _prepareFile('$alanAssetDir/lang/gmw/en', targetPath: '$esSub/lang/gmw/en');
        await _prepareFile('$alanAssetDir/lang/gmw/en-GB', targetPath: '$esSub/lang/gmw/en-GB');
        await _prepareFile('$alanAssetDir/lang/gmw/en-GB-x-rp', targetPath: '$esSub/lang/gmw/en-GB-x-rp');
        final voicesDir = Directory('${directory.path}/$esSub/voices');
        if (!await voicesDir.exists()) await voicesDir.create(recursive: true);
        await File('${voicesDir.path}/en-gb').writeAsString("name en-gb\nlanguage en-gb\n");
        await File('${voicesDir.path}/en-gb-x-rp').writeAsString("name en-gb-x-rp\nlanguage en-gb-x-rp\n");
      }

      setState(() {
        _loadingStatusText = "Spouštím hlas: ${_selectedModel.name}...";
      });

      final espeakDataPath = '${directory.path}/$esSub'.replaceAll('\\', '/');
      sherpa.OfflineTtsModelConfig modelConfig;

      final modelPath = await _prepareFile('${_selectedModel.assetDir}/${_selectedModel.modelFile}', targetPath: '${_selectedModel.id}_model.onnx');
      final tokensPath = await _prepareFile('${_selectedModel.assetDir}/tokens.txt', targetPath: '${_selectedModel.id}_tokens.txt');

      if (modelPath.isEmpty || tokensPath.isEmpty) throw Exception("Error loading assets.");

      if (_selectedModel.id == 'en_kokoro') {
        final extraPath = await _prepareFile('${_selectedModel.assetDir}/${_selectedModel.configFile}', targetPath: _selectedModel.configFile);
        modelConfig = sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(model: modelPath, voices: extraPath, tokens: tokensPath, dataDir: espeakDataPath),
          numThreads: 4,
          debug: true,
        );
      } else {
        await _prepareFile('${_selectedModel.assetDir}/${_selectedModel.configFile}', targetPath: '${_selectedModel.id}_config.json');
        modelConfig = sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(model: modelPath, tokens: tokensPath, dataDir: espeakDataPath, noiseScale: 0.667, noiseScaleW: 0.8, lengthScale: 1.0),
          numThreads: 4,
          debug: true,
        );
      }

      globalTts?.free();
      globalTts = null;
      await Future.delayed(const Duration(milliseconds: 50));
      globalTts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: modelConfig));
      globalCurrentModelId = _selectedModel.id;
    } catch (e) {
      debugPrint('TTS setup error: $e');
    }
  }

  Future<void> _saveCacheToDisk(String bookId, List<PdfChunkMetadata> chunks) async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final cacheFolder = Directory(p.join(appDir.path, 'book_cache'));
      if (!cacheFolder.existsSync()) await cacheFolder.create(recursive: true);

      final cacheFile = File(p.join(cacheFolder.path, '$bookId.cache'));
      final List<Map<String, dynamic>> mapped = chunks.map((c) => c.toMap()).toList();
      await cacheFile.writeAsString(jsonEncode(mapped), flush: true);
    } catch (e) {
      debugPrint('Error saving cache to disk: $e');
    }
  }

  Future<List<PdfChunkMetadata>?> _loadCacheFromDisk(String bookId) async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final cacheFile = File(p.join(appDir.path, 'book_cache', '$bookId.cache'));
      if (await cacheFile.exists()) {
        final String content = await cacheFile.readAsString();
        final List<dynamic> decoded = jsonDecode(content);
        return decoded.map((item) => PdfChunkMetadata.fromMap(item)).toList();
      }
    } catch (e) {
      debugPrint('Error loading cache from disk: $e');
    }
    return null;
  }

  void _scrollToCurrentChunk(int index) {
    if (_chunksMetadata.isEmpty || index >= _chunksMetadata.length) return;
    if (globalIsOriginalLayout) {
      if (_isTxtFile || _renderedPages.isEmpty) return;
      _isProgrammaticScrolling = true; // set before scheduling, not inside callback
      final chunk = _chunksMetadata[index];

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        try {
          if (_pdfVertScrollController.hasClients) {
            final double viewportH = _pdfVertScrollController.position.viewportDimension;
            final double viewportW = _pdfHorizScrollController.hasClients
                ? _pdfHorizScrollController.position.viewportDimension
                : viewportH;
            final double dw = viewportW - 96.0;

            // Accumulate height of all pages before the target page
            double pageTopY = 16.0;
            for (final rp in _renderedPages) {
              if (rp.pageNumber == chunk.pageNumber) break;
              pageTopY += (dw * rp.heightPt / rp.widthPt) + 16.0;
            }

            // Find the vertical centre of the first word in this chunk on its page
            double wordFracY = 0.1; // fallback: 10% down the page
            if (chunk.pdfWords.isNotEmpty) {
              final targetRp = _renderedPages.firstWhere(
                    (rp) => rp.pageNumber == chunk.pageNumber,
                orElse: () => _renderedPages.first,
              );
              final double wordMidPt = chunk.pdfWords[0].bounds.top +
                  chunk.pdfWords[0].bounds.height / 2;
              wordFracY = (wordMidPt / targetRp.heightPt).clamp(0.0, 1.0);
            }

            final double pageH = dw *
                (_renderedPages.firstWhere(
                      (rp) => rp.pageNumber == chunk.pageNumber,
                  orElse: () => _renderedPages.first,
                ).heightPt /
                    _renderedPages.firstWhere(
                          (rp) => rp.pageNumber == chunk.pageNumber,
                      orElse: () => _renderedPages.first,
                    ).widthPt);

            final double wordAbsY = pageTopY + (pageH * wordFracY);
            final double scaledWordY = wordAbsY * _pdfZoomFactor;
            final double scrollTarget = scaledWordY - (viewportH / 2);

            // Await the animation so _isProgrammaticScrolling stays true for its full duration
            await _pdfVertScrollController.animateTo(
              scrollTarget.clamp(0.0, _pdfVertScrollController.position.maxScrollExtent),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOutCubic,
            );
          }
        } catch (_) {}
        if (mounted) _isProgrammaticScrolling = false;
      });
    } else {
      if (_itemScrollController.isAttached) {
        _isProgrammaticScrolling = true;
        _itemScrollController
            .scrollTo(index: index, alignment: 0.1, duration: const Duration(milliseconds: 250), curve: Curves.easeInOutCubic)
            .then((_) { if (mounted) _isProgrammaticScrolling = false; });
      }
    }
  }

  void _recenterToCurrentChunk() {
    _isProgrammaticScrolling = true; // set immediately, before postFrameCallback gap
    setState(() { _isUserScrolling = false; });
    _scrollToCurrentChunk(_currentChunkIndex);
  }

  void _startPdfReading() {
    if (_chunksMetadata.isEmpty || globalTts == null) return;
    setState(() { _isBusy = true; });
    _executeChunkReading();
  }

  void _stopPdfReading() async {
    setState(() { _isBusy = false; });
    if (Platform.isAndroid || Platform.isIOS) await audioHandler.stop(); else await windowsPlayer.stop();
  }

  void _restartAudioFromBeginning() async {
    setState(() {
      _isBusy = true;
      _isUserScrolling = false;
      _currentChunkIndex = 0;
      _currentWordIndex = 0;
    });
    if (Platform.isAndroid || Platform.isIOS) await audioHandler.stop(); else await windowsPlayer.stop();
    _saveCurrentProgress();
    _executeChunkReading();
  }

  void _jumpToSelectedAndPlay() async {
    if (_selectedChunkIndex == null || _selectedChunkIndex! >= _chunksMetadata.length) return;
    final int targetIdx = _selectedChunkIndex!;
    if (Platform.isAndroid || Platform.isIOS) await audioHandler.stop(); else await windowsPlayer.stop();
    setState(() {
      _isBusy = true;
      _isUserScrolling = false;
      _currentChunkIndex = targetIdx;
      _currentWordIndex = 0;
      _selectedChunkIndex = null;
      _pendingJumpIndex = null;
    });
    _saveCurrentProgress();
    _executeChunkReading();
  }

  void _executeChunkReading() async {
    if (!await File(widget.book.filePath).exists()) {
      _stopPdfReading();
      globalIsAudioBusy = false;
      globalActiveBookId = null;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Document was deleted, moved or renamed. Reading stopped.',
            ),
          ),
        );
      }

      return;
    }

    if (_currentChunkIndex >= _chunksMetadata.length || !_isBusy) {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
      return;
    }

    try {
      String rawText = _chunksMetadata[_currentChunkIndex].text;
      if (_skipPageNumbers && RegExp(r'^\d{1,4}$').hasMatch(rawText.trim())) { _skipToNextFailedChunk(); return; }
      if (_skipLinks && RegExp(r'^https?://\S+$|^www\.\S+$').hasMatch(rawText.trim())) { _skipToNextFailedChunk(); return; }
      if (_skipParentheses) {
        rawText = rawText.replaceAll(RegExp(r'\([^)]*\)'), ' ').replaceAll(RegExp(r'\s{2,}'), ' ').trim();
        if (rawText.isEmpty) { _skipToNextFailedChunk(); return; }
      }
      // Add a natural pause prefix for bullet-point chunks
      if (TextSanitizer.isBulletLine(rawText)) rawText = '... $rawText';

      _scrollToCurrentChunk(_currentChunkIndex);

      if (globalIsOriginalLayout && !_isTxtFile) {
        setState(() { globalCurrentPdfPage = _chunksMetadata[_currentChunkIndex].pageNumber; });
      }

      // When skip flags are active, always regenerate rather than use cached wav
      // (cached wav was generated from original text and would ignore skip settings)
      final bool skipActive = _skipParentheses || _skipLinks || _skipPageNumbers;
      String? wavPath = skipActive ? null : _pregeneratedAudioCache[_currentChunkIndex];
      if (wavPath == null) {
        if (rawText.trim().isEmpty || globalTts == null) {
          _skipToNextFailedChunk();
          return;
        }
        // Apply model dictionary at speak-time so cached chunks also benefit
        String ttsText = rawText;
        // Colon mid-sentence → period so intonation drops naturally
        ttsText = ttsText.replaceAll(RegExp(r':\s+'), '. ');
        // End-of-chunk colon (no following space) → period
        ttsText = ttsText.replaceAll(RegExp(r':$'), '.');
        // tzv. / Tzv. → takzvaně (must run before DictionaryJirka to avoid split chunks)
        ttsText = ttsText.replaceAll(RegExp(r'\btzv\.\s*', caseSensitive: false), 'takzvaně ');
        ttsText = ttsText.replaceAll(RegExp(r'\btzv$', caseSensitive: false), 'takzvaně');
        ttsText = DictionaryJirka.apply(ttsText);
        final audio = globalTts!.generate(text: ttsText, sid: _selectedModel.sid);
        final tempDir = await getTemporaryDirectory();
        wavPath = p.join(tempDir.path, 'chunk_${_currentChunkIndex}_${DateTime.now().millisecondsSinceEpoch}.wav');
        sherpa.writeWave(filename: wavPath, samples: audio.samples, sampleRate: audio.sampleRate);
      }

      if (_isBusy) {
        if (Platform.isAndroid || Platform.isIOS) {
          await audioHandler.playFile(wavPath, rawText);
          await audioHandler.player.setSpeed(_playbackSpeed);
          await audioHandler.player.setVolume(_volume);
          // Re-apply speed after a short delay in case playFile resets it
          Future.delayed(const Duration(milliseconds: 80), () async {
            if (mounted && _isBusy) await audioHandler.player.setSpeed(_playbackSpeed);
          });
        } else {
          await windowsPlayer.setVolume(_volume);
          await windowsPlayer.setSpeed(_playbackSpeed);
          await windowsPlayer.setFilePath(wavPath);
          if (!mounted || !_isBusy) return;
          await Future.delayed(const Duration(milliseconds: 150));
          if (!mounted || !_isBusy) return;
          await windowsPlayer.play();
          await windowsPlayer.setSpeed(_playbackSpeed);
        }
        _bufferNextChunkAsync(_currentChunkIndex + 1);
      }
    } catch (e) {
      _skipToNextFailedChunk();
    }
  }

  Future<void> _bufferNextChunkAsync(int nextIndex) async {
    if (nextIndex >= _chunksMetadata.length || _pregeneratedAudioCache.containsKey(nextIndex) || _isBufferingNext) return;
    _isBufferingNext = true;
    try {
      final rawText = _chunksMetadata[nextIndex].text;
      if (rawText.trim().isEmpty || globalTts == null) return;

      final audio = globalTts!.generate(text: rawText, sid: _selectedModel.sid);
      final tempDir = await getTemporaryDirectory();
      final wavPath = p.join(tempDir.path, 'chunk_${nextIndex}_${DateTime.now().millisecondsSinceEpoch}.wav');
      if (sherpa.writeWave(filename: wavPath, samples: audio.samples, sampleRate: audio.sampleRate)) {
        _pregeneratedAudioCache[nextIndex] = wavPath;
      }
    } catch (_) {}
    _isBufferingNext = false;
  }

  void _seekRelative(int seconds) async {
    if (!_isBusy) return;
    final player = (Platform.isAndroid || Platform.isIOS) ? audioHandler.player : windowsPlayer;
    final currentPos = player.position;
    final targetPos = currentPos + Duration(seconds: seconds);
    final duration = player.duration;
    if (duration != null) {
      if (targetPos < Duration.zero) {
        player.seek(Duration.zero);
      } else if (targetPos > duration) {
        if (_stopAtEndOfBlock) _stopAudioAndPop(); else _handleTrackComplete();
      } else {
        player.seek(targetPos);
      }
    }
  }

  void _changeSpeed(double speed) async {
    setState(() { _playbackSpeed = speed; });
    // Persist speed immediately so it survives chunk transitions and app restarts
    SharedPreferences.getInstance().then((prefs) => prefs.setDouble('speed_${widget.book.id}', speed));
    if (_isBusy) {
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

  void _changeZoom(double delta) {
    setState(() {
      if (globalIsOriginalLayout) {
        _pdfZoomFactor = (_pdfZoomFactor + delta).clamp(_minZoom, _maxZoom);
        _isMaxZoomReached = _pdfZoomFactor >= _maxZoom;
        _isMinZoomReached = _pdfZoomFactor <= _minZoom;
      } else {
        _textZoomFactor = (_textZoomFactor + delta).clamp(_minZoom, _maxZoom);
        _isMaxZoomReached = _textZoomFactor >= _maxZoom;
        _isMinZoomReached = _textZoomFactor <= _minZoom;
      }
    });
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
      if (event.scrollDelta.dy < 0) _changeZoom(_zoomStep); else if (event.scrollDelta.dy > 0) _changeZoom(-_zoomStep);
    }
  }

  void _showFileNameDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Název dokumentu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: Text(widget.book.title, style: const TextStyle(fontSize: 14)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Zavřít'))],
      ),
    );
  }

  void _handlePopAction() {
    Navigator.of(context).pop(); // reading continues in background
  }

  Widget _buildCpuIndicator(int load) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        Color color = Colors.transparent;
        if (i < load) color = load == 1 ? Colors.green : (load == 2 ? Colors.orange : Colors.red);
        return Container(
          width: 3, height: 10,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: color.withOpacity(color == Colors.transparent ? 0.15 : 1),
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }

  List<TextSpan> _buildHighlightedWords(String text, BuildContext context) {
    List<String> words = text.split(' ');
    List<TextSpan> spans = [];
    for (int i = 0; i < words.length; i++) {
      bool isCurrent = i == _currentWordIndex;
      spans.add(
        TextSpan(
          text: words[i] + (i == words.length - 1 ? "" : " "),
          style: TextStyle(
            fontWeight: i == _currentWordIndex ? FontWeight.bold : FontWeight.normal,
            backgroundColor: isCurrent ? Theme.of(context).colorScheme.primary.withOpacity(0.2) : Colors.transparent,
            color: isCurrent ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      );
    }
    return spans;
  }


  void _computeHeadingLevels() {
    _chunkHeadingLevels.clear();
    if (_chunksMetadata.isEmpty) return;

    if (_isTxtFile) {
      for (final chunk in _chunksMetadata) {
        final t = chunk.text.trim();
        final wordCount = t.split(' ').length;
        final endsWithPunct = t.endsWith('.') || t.endsWith('?') || t.endsWith('!');
        final isBoldLabel = t.endsWith(':') && wordCount <= 10;
        if (isBoldLabel) {
          _chunkHeadingLevels.add(3);
        } else if (wordCount <= 6 && !endsWithPunct && t.length > 2) {
          _chunkHeadingLevels.add(wordCount <= 3 ? 1 : 2);
        } else {
          _chunkHeadingLevels.add(0);
        }
      }
      return;
    }

    final List<double> avgHeights = [];
    for (final chunk in _chunksMetadata) {
      if (chunk.pdfWords.isEmpty) { avgHeights.add(0); continue; }
      final avg = chunk.pdfWords.map((w) => w.bounds.height).reduce((a, b) => a + b) / chunk.pdfWords.length;
      avgHeights.add(avg);
    }
    final nonZero = avgHeights.where((h) => h > 0).toList()..sort();
    if (nonZero.isEmpty) {
      _chunkHeadingLevels.addAll(List.filled(_chunksMetadata.length, 0));
      return;
    }
    final double bodyHeight = nonZero[(nonZero.length * 0.5).floor()];
    final double h1Threshold = bodyHeight * 1.6;
    final double h2Threshold = bodyHeight * 1.25;
    final double h3Threshold = bodyHeight * 1.1;

    for (int i = 0; i < _chunksMetadata.length; i++) {
      final h = avgHeights[i];
      final text = _chunksMetadata[i].text.trim();
      final wordCount = text.split(' ').length;
      // Short phrase ending with ':' is a bold label/title — treat as h3 regardless of font size
      final bool isBoldLabel = text.endsWith(':') && wordCount <= 10;
      if (h >= h1Threshold && wordCount <= 12) {
        _chunkHeadingLevels.add(1);
      } else if (h >= h2Threshold && wordCount <= 14) {
        _chunkHeadingLevels.add(2);
      } else if ((h >= h3Threshold && wordCount <= 16) || isBoldLabel) {
        _chunkHeadingLevels.add(3);
      } else {
        _chunkHeadingLevels.add(0);
      }
    }
  }

  int _headingLevel(int index) {
    if (index < 0 || index >= _chunkHeadingLevels.length) return 0;
    return _chunkHeadingLevels[index];
  }

  List<({int index, String text, int level})> get _tocEntries {
    final result = <({int index, String text, int level})>[];
    for (int i = 0; i < _chunksMetadata.length; i++) {
      final lvl = _headingLevel(i);
      if (lvl > 0) result.add((index: i, text: _chunksMetadata[i].text.trim(), level: lvl));
    }
    return result;
  }

  // Returns the index of the heading chunk that is the active chapter
  // (last heading at or before _currentChunkIndex)
  int get _activeChapterIndex {
    int active = -1;
    for (int i = 0; i <= _currentChunkIndex && i < _chunksMetadata.length; i++) {
      if (_headingLevel(i) > 0) active = i;
    }
    return active;
  }

  void _previewThenJump(int chunkIndex) {
    _pendingJumpTimer?.cancel();
    setState(() {
      _pendingJumpIndex = chunkIndex;
      _tocOpen = false;
    });
    _pendingJumpTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() {
        _selectedChunkIndex = chunkIndex;
        _pendingJumpIndex = null;
        _isUserScrolling = false; // allow programmatic scroll in both layout modes
      });
      if (globalIsOriginalLayout && !_isTxtFile) {
        _scrollToCurrentChunk(chunkIndex);
      } else {
        if (_itemScrollController.isAttached) {
          _isProgrammaticScrolling = true;
          _itemScrollController
              .scrollTo(index: chunkIndex, alignment: 0.2,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic)
              .then((_) { if (mounted) _isProgrammaticScrolling = false; });
        }
      }
    });
  }

  Widget _buildTocButton(BuildContext context) {
    final entries = _tocEntries;
    if (entries.isEmpty) return const SizedBox.shrink();

    // Find which list index corresponds to the active chapter
    final int activeListIndex = entries.indexWhere((e) => e.index == _activeChapterIndex);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FloatingActionButton.small(
          heroTag: 'toc_fab',
          onPressed: () => setState(() => _tocOpen = !_tocOpen),
          backgroundColor: _tocOpen ? Colors.orange.shade700 : Colors.white,
          foregroundColor: _tocOpen ? Colors.white : Colors.black87,
          elevation: 3,
          child: const Icon(Icons.format_list_bulleted_rounded),
        ),
        if (_tocOpen)
          Builder(builder: (ctx) {
            final sc = ScrollController();
            // Scroll to active item after the list is laid out
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!sc.hasClients || activeListIndex < 0) return;
              const itemH = 42.0;
              final maxScroll = sc.position.maxScrollExtent;
              final target = (activeListIndex * itemH - 100).clamp(0.0, maxScroll);
              sc.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
            });
            return Container(
              constraints: const BoxConstraints(maxWidth: 280, maxHeight: 320),
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 16, offset: const Offset(0, 4))],
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ListView.builder(
                  controller: sc,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  shrinkWrap: true,
                  itemCount: entries.length,
                  itemBuilder: (ctx, i) {
                    final e = entries[i];
                    final bool isPending = e.index == _pendingJumpIndex;
                    final bool isActiveChapter = e.index == _activeChapterIndex;
                    return InkWell(
                      onTap: () => _previewThenJump(e.index),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        color: isPending
                            ? Colors.orange.shade50
                            : isActiveChapter
                            ? Theme.of(ctx).colorScheme.primary.withOpacity(0.1)
                            : Colors.transparent,
                        padding: EdgeInsets.fromLTRB(12.0 + (e.level - 1) * 10.0, 9, 12, 9),
                        child: Row(children: [
                          Container(
                            width: isActiveChapter ? 3.5 : 2.5,
                            height: 14,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              color: isActiveChapter
                                  ? Theme.of(ctx).colorScheme.primary
                                  : e.level == 1
                                  ? Theme.of(ctx).colorScheme.primary
                                  : e.level == 2
                                  ? Theme.of(ctx).colorScheme.primary.withOpacity(0.55)
                                  : Theme.of(ctx).colorScheme.primary.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          Expanded(child: Text(
                            e.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: e.level == 1 ? 13 : 12,
                              fontWeight: isActiveChapter
                                  ? FontWeight.w800
                                  : e.level == 1 ? FontWeight.w700 : FontWeight.w500,
                              color: isActiveChapter
                                  ? Theme.of(ctx).colorScheme.primary
                                  : Colors.black87,
                            ),
                          )),
                          if (isActiveChapter)
                            Icon(Icons.volume_up_rounded, size: 12, color: Theme.of(ctx).colorScheme.primary),
                        ]),
                      ),
                    );
                  },
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildPdfViewer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double availableWidth = constraints.maxWidth;
        final double availableHeight = constraints.maxHeight;
        final double displayWidth = availableWidth - 96.0;

        if (_renderedPages.isEmpty && !_isPagesRendering) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _renderedPages.isEmpty && !_isPagesRendering) {
              _renderAllPages(displayWidth);
            }
          });
        }

        const double pageGap = 16.0;

        final double totalContentHeight = _renderedPages.fold(0.0, (sum, p) {
          return sum + (displayWidth * p.heightPt / p.widthPt) + pageGap;
        }) + 32.0;

        final double scaledW = availableWidth * _pdfZoomFactor;
        final bool needsHorizScroll = scaledW > availableWidth;

        return Listener(
          onPointerSignal: _handlePointerSignal,
          child: NotificationListener<ScrollStartNotification>(
            onNotification: (n) {
              // dragDetails is non-null only for touch/pointer-initiated scrolls
              if (n.dragDetails != null && !_isUserScrolling) {
                setState(() { _isUserScrolling = true; });
                _isProgrammaticScrolling = false; // user took over
              }
              return false;
            },
            child: Container(
              color: const Color(0xFF3A3A3A),
              child: RawScrollbar(
                controller: _pdfVertScrollController,
                thumbVisibility: true,
                trackVisibility: true,
                thumbColor: Colors.white38,
                trackColor: Colors.white12,
                radius: const Radius.circular(4),
                thickness: 8,
                child: RawScrollbar(
                  controller: _pdfHorizScrollController,
                  thumbVisibility: needsHorizScroll,
                  trackVisibility: needsHorizScroll,
                  thumbColor: Colors.white38,
                  trackColor: Colors.white12,
                  radius: const Radius.circular(4),
                  thickness: 8,
                  notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
                  child: SingleChildScrollView(
                    controller: _pdfVertScrollController,
                    physics: const ClampingScrollPhysics(),
                    child: SingleChildScrollView(
                      controller: _pdfHorizScrollController,
                      scrollDirection: Axis.horizontal,
                      physics: needsHorizScroll
                          ? const ClampingScrollPhysics()
                          : const NeverScrollableScrollPhysics(),
                      child: SizedBox(
                        width: needsHorizScroll ? scaledW : availableWidth,
                        height: (totalContentHeight * _pdfZoomFactor).clamp(availableHeight, double.infinity),
                        child: _renderedPages.isEmpty
                            ? const Center(
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                        )
                            : Align(
                          alignment: Alignment.topCenter,
                          child: Transform.scale(
                            scale: _pdfZoomFactor,
                            alignment: Alignment.topCenter,
                            child: SizedBox(
                              width: availableWidth,
                              height: totalContentHeight,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  const SizedBox(height: 16),
                                  for (final renderedPage in _renderedPages)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: pageGap),
                                      child: Container(
                                        margin: const EdgeInsets.symmetric(horizontal: 48.0),
                                        decoration: BoxDecoration(
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(0.5),
                                              blurRadius: 18,
                                              spreadRadius: 2,
                                              offset: const Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: PdfPageWidget(
                                          page: renderedPage,
                                          displayWidth: displayWidth,
                                          chunks: _chunksMetadata,
                                          currentChunkIndex: _currentChunkIndex,
                                          currentWordIndex: _currentWordIndex,
                                          pendingChunkIndex: _pendingJumpIndex,
                                          isBusy: _isBusy,
                                          primaryColor: Theme.of(context).colorScheme.primary,
                                          onTap: (ci, wi) {
                                            setState(() {
                                              _pendingJumpIndex = ci;
                                              _selectedChunkIndex = ci;
                                            });
                                          },
                                        ),
                                      ),
                                    ),
                                  const SizedBox(height: 16),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSpeedButton(BuildContext context) {
    final spd = _playbackSpeed;
    final label = spd % 1 == 0 ? '${spd.toInt()}x' : '${spd}x';
    return CompositedTransformTarget(
      link: _speedLayerLink,
      child: Tooltip(
        message: 'Rychlost čtení',
        child: GestureDetector(
          onTap: () => _toggleSpeedOverlay(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: _speedOpen ? const Color(0xFF1A73E8) : const Color(0xFFF1F3F4),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.speed_rounded, size: 15, color: _speedOpen ? Colors.white : const Color(0xFF5F6368)),
              const SizedBox(width: 3),
              Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _speedOpen ? Colors.white : const Color(0xFF1F1F1F))),
            ]),
          ),
        ),
      ),
    );
  }

  void _toggleSpeedOverlay(BuildContext context) {
    if (_speedOpen) {
      _closeSpeedOverlay();
    } else {
      _openSpeedOverlay(context);
    }
  }

  void _openSpeedOverlay(BuildContext context) {
    _speedOverlay?.remove();
    _speedOpen = true;
    if (mounted) setState(() {});

    _speedOverlay = OverlayEntry(builder: (ctx) {
      const List<double> allSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 3.5, 4.0];
      const double rangeMin = 0.5;
      const double rangeMax = 4.0;
      const double chipH = 28.0;
      const double chipGap = 5.0;
      // 11 chips, 10 gaps — avoid allSpeeds.length in const expression
      const double chipsAreaH = 11 * chipH + 10 * chipGap;
      const double thumbR = 8.0;

      double fracFor(double spd) => ((spd - rangeMin) / (rangeMax - rangeMin)).clamp(0.0, 1.0);

      return Stack(children: [
        Positioned.fill(child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _closeSpeedOverlay,
        )),
        CompositedTransformFollower(
          link: _speedLayerLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(0, -6),
          child: Material(
            color: Colors.transparent,
            child: StatefulBuilder(builder: (_, setLocal) {
              return Container(
                width: 148,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.16), blurRadius: 18, offset: const Offset(0, 4))],
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  // Header — label only
                  Padding(
                    padding: const EdgeInsets.fromLTRB(11, 10, 11, 8),
                    child: Row(children: [
                      const Icon(Icons.speed_rounded, size: 13, color: Color(0xFF5F6368)),
                      const SizedBox(width: 5),
                      const Text('Rychlost čtení',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF1F1F1F))),
                    ]),
                  ),
                  const Divider(height: 1, thickness: 0.5),
                  // Slider + chips
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                    child: SizedBox(
                      height: chipsAreaH,
                      child: Stack(clipBehavior: Clip.none, children: [
                        // Vertical slider on the left
                        Positioned(
                          left: 0, top: 0, bottom: 0, width: 44,
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: SliderTheme(
                              data: SliderThemeData(
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: thumbR),
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 15),
                                activeTrackColor: const Color(0xFF1A73E8),
                                thumbColor: const Color(0xFF1A73E8),
                                inactiveTrackColor: Colors.grey.shade200,
                                overlayColor: const Color(0xFF1A73E8).withOpacity(0.15),
                              ),
                              child: Slider(
                                value: _playbackSpeed.clamp(rangeMin, rangeMax),
                                min: rangeMin, max: rangeMax, divisions: 28,
                                onChanged: (v) {
                                  final snapped = (v * 4).round() / 4.0;
                                  _changeSpeed(snapped);
                                  setLocal(() {});
                                },
                              ),
                            ),
                          ),
                        ),
                        // Speed chips — evenly spaced, fastest at top
                        for (int i = 0; i < allSpeeds.length; i++)
                          Builder(builder: (_) {
                            final spd = allSpeeds[allSpeeds.length - 1 - i];
                            final bool active = (_playbackSpeed - spd).abs() < 0.01;
                            return Positioned(
                              right: 0, top: i * (chipH + chipGap),
                              width: 90, height: chipH,
                              child: GestureDetector(
                                onTap: () { _changeSpeed(spd); setLocal(() {}); },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 100),
                                  decoration: BoxDecoration(
                                    color: active ? const Color(0xFF1A73E8) : Colors.transparent,
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    spd % 1 == 0 ? '${spd.toInt()}x' : '${spd}x',
                                    style: TextStyle(
                                      fontSize: 12, fontWeight: FontWeight.w700,
                                      color: active ? Colors.white : Colors.black87,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                      ]),
                    ),
                  ),
                  const Divider(height: 1, thickness: 0.5),
                  // Auto-speed-increase toggle
                  InkWell(
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
                    onTap: () {
                      _autoSpeedIncrease = !_autoSpeedIncrease;
                      _wordsReadSinceSpeedIncrease = 0;
                      SharedPreferences.getInstance().then(
                              (p) => p.setBool('auto_speed_${widget.book.id}', _autoSpeedIncrease));
                      setLocal(() {});
                      setState(() {});
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
                      child: Row(children: [
                        SizedBox(
                          width: 20, height: 20,
                          child: Radio<bool>(
                            value: true,
                            groupValue: _autoSpeedIncrease,
                            onChanged: (_) {
                              _autoSpeedIncrease = !_autoSpeedIncrease;
                              _wordsReadSinceSpeedIncrease = 0;
                              SharedPreferences.getInstance().then(
                                      (p) => p.setBool('auto_speed_${widget.book.id}', _autoSpeedIncrease));
                              setLocal(() {});
                              setState(() {});
                            },
                            activeColor: const Color(0xFF1A73E8),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text('Zvýšit rychlost\nkaždých 650 slov',
                              style: TextStyle(fontSize: 10, height: 1.35, fontWeight: FontWeight.w500, color: Color(0xFF3C4043))),
                        ),
                      ]),
                    ),
                  ),
                ]),
              );
            }),
          ),
        ),
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

  @override
  Widget build(BuildContext context) {
    bool isCompleted = _chunksMetadata.isNotEmpty && _currentChunkIndex >= _chunksMetadata.length;
    double progress = _chunksMetadata.isEmpty ? 0.0 : (isCompleted ? 1.0 : _currentChunkIndex / _chunksMetadata.length);
    bool showJumpButton = _selectedChunkIndex != null;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_keyboardFocusNode.canRequestFocus) _keyboardFocusNode.requestFocus();
    });

    final filteredModels = availableModels.where((m) => m.id != _selectedModel.id).toList();

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowUp, control: true): () => _changeZoom(_zoomStep),
        const SingleActivator(LogicalKeyboardKey.arrowDown, control: true): () => _changeZoom(-_zoomStep),
      },
      child: Focus(
        focusNode: _keyboardFocusNode,
        child: Scaffold(
          backgroundColor: const Color(0xFFF8F9FA),
          appBar: (_needsModelSelection || _isFullscreen)
              ? null
              : AppBar(
            automaticallyImplyLeading: false,
            elevation: 0,
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: Border(bottom: BorderSide(color: Colors.grey.shade200, width: 1)),
            titleSpacing: 0,
            title: Row(
              children: [
                const SizedBox(width: 4),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.black87),
                  onPressed: _handlePopAction,
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 14),
                  label: const Text('Zpět', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: InkWell(
                    onTap: _showFileNameDialog,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
                      child: Text(
                        widget.book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF1F1F1F)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (!_isParsingPdf) ...[
                  PopupMenuButton<ModelConfig>(
                    enabled: !_isBusy && _isReady,
                    offset: const Offset(0, 40),
                    constraints: const BoxConstraints(minWidth: 140, maxWidth: 200),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    onSelected: (ModelConfig newValue) {
                      setState(() { _selectedModel = newValue; });
                      _initEngineAndLoadPdf();
                    },
                    itemBuilder: (BuildContext context) => filteredModels.map<PopupMenuEntry<ModelConfig>>((ModelConfig model) {
                      return PopupMenuItem<ModelConfig>(
                        value: model,
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(3)),
                              child: Text(model.langCode.toUpperCase(), style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.grey)),
                            ),
                            const SizedBox(width: 4),
                            _buildCpuIndicator(model.cpuLoad),
                            const SizedBox(width: 4),
                            Expanded(child: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                          ],
                        ),
                      );
                    }).toList(),
                    child: Container(
                      width: 140,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F0FE),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: PopupMenuButton<ModelConfig>(
                        enabled: !_isBusy && _isReady,
                        offset: const Offset(0, 40),
                        constraints: const BoxConstraints(minWidth: 140, maxWidth: 140),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: EdgeInsets.zero,
                        onOpened: () { if (_isBusy) _stopPdfReading(); },
                        onSelected: (ModelConfig newValue) {
                          setState(() { _selectedModel = newValue; });
                          _initEngineAndLoadPdf();
                        },
                        itemBuilder: (BuildContext context) => filteredModels.map<PopupMenuEntry<ModelConfig>>((ModelConfig model) {
                          return PopupMenuItem<ModelConfig>(
                            value: model,
                            height: 36,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(3)),
                                  child: Text(model.langCode.toUpperCase(), style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.grey)),
                                ),
                                const SizedBox(width: 4),
                                _buildCpuIndicator(model.cpuLoad),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF1F1F1F))),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3)),
                                child: Text(_selectedModel.langCode.toUpperCase(), style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.grey)),
                              ),
                              const SizedBox(width: 4),
                              _buildCpuIndicator(_selectedModel.cpuLoad),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(_selectedModel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Color(0xFF1F1F1F), fontWeight: FontWeight.w600)),
                              ),
                              const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF1A73E8), size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (!_isTxtFile)
                    SizedBox(
                      height: 36,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF1A73E8),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: () {
                          setState(() => globalIsOriginalLayout = !globalIsOriginalLayout);
                          _scrollToCurrentChunk(_currentChunkIndex);
                        },
                        icon: Icon(globalIsOriginalLayout ? Icons.picture_as_pdf : Icons.text_fields_rounded, size: 18),
                        label: Text(globalIsOriginalLayout ? 'PDF' : 'Text', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                    )
                  else
                    Container(
                      height: 36, padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.center,
                      child: const Text('Text', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1A73E8))),
                    ),
                ],
              ],
            ),
            actions: [
              if (!_isParsingPdf) ...[
                const VerticalDivider(width: 12, indent: 16, endIndent: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
                      onPressed: (_currentZoomFactor <= _minZoom || _isMinZoomReached) ? null : () => _changeZoom(-_zoomStep),
                    ),
                    Container(
                      constraints: const BoxConstraints(minWidth: 36),
                      alignment: Alignment.center,
                      child: Text(
                        '${((_currentZoomFactor / (globalIsOriginalLayout ? _pdfBaselineZoom : _textBaselineZoom)) * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                      onPressed: (_currentZoomFactor >= _maxZoom || _isMaxZoomReached) ? null : () => _changeZoom(_zoomStep),
                    ),
                  ],
                ),
                PopupMenuButton<String>(
                  offset: const Offset(0, 40),
                  constraints: const BoxConstraints(minWidth: 180, maxWidth: 220),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  splashRadius: 20,
                  tooltip: 'Parametry',
                  onSelected: (_) {},
                  itemBuilder: (BuildContext ctx2) {
                    void toggle(String v) {
                      setState(() {
                        if (v == 'parentheses') _skipParentheses = !_skipParentheses;
                        else if (v == 'links') _skipLinks = !_skipLinks;
                        else if (v == 'pages') _skipPageNumbers = !_skipPageNumbers;
                        // Invalidate pre-buffered audio so next chunks regenerate with new settings
                        _pregeneratedAudioCache.clear();
                      });
                    }
                    PopupMenuEntry<String> row(String val, bool active, String label, Color dot) =>
                        PopupMenuItem<String>(
                          value: val, height: 40,
                          onTap: () => toggle(val),
                          child: Row(children: [
                            Container(width: 4, height: 22, margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                    color: active ? dot : Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(2))),
                            SizedBox(width: 22, height: 22, child: Checkbox(
                              value: active, activeColor: dot,
                              onChanged: (_) { toggle(val); },
                            )),
                            const SizedBox(width: 6),
                            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          ]),
                        );
                    return <PopupMenuEntry<String>>[
                      row('parentheses', _skipParentheses, 'Přeskočit závorky', Colors.purple.shade400),
                      row('links', _skipLinks, 'Přeskočit odkazy', Colors.blue.shade400),
                      row('pages', _skipPageNumbers, 'Přeskočit čísla stran', Colors.orange.shade400),
                    ];
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Icon(Icons.tune_rounded, color: Color(0xFF5F6368), size: 20),
                  ),
                ),
                IconButton(
                  icon: Icon(_isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
                  onPressed: () => setState(() => _isFullscreen = !_isFullscreen),
                ),
                const SizedBox(width: 4),
              ],
            ],
          ),
          body: SafeArea(
            child: _needsModelSelection
                ? Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 400),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: Colors.grey.shade200)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.voice_over_off_rounded, size: 48, color: Color(0xFF1A73E8)),
                    const SizedBox(height: 16),
                    const Text('Vyberte hlas pro tento dokument', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF1F1F1F))),
                    const SizedBox(height: 8),
                    const Text('Tento dokument nemá přiřazený model. Zvolte výchozí formát čtení:', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey)),
                    const SizedBox(height: 24),
                    ...availableModels.map((model) => Padding(
                      padding: const EdgeInsets.only(bottom: 10.0),
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          side: BorderSide(color: Colors.grey.shade300),
                        ),
                        onPressed: () => _selectInitialModel(model),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: const Color(0xFFE8F0FE), borderRadius: BorderRadius.circular(4)),
                              child: Text(model.langCode.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF1A73E8))),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(model.name, style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF1F1F1F)))),
                            _buildCpuIndicator(model.cpuLoad),
                          ],
                        ),
                      ),
                    )),
                  ],
                ),
              ),
            )
                : Padding(
              padding: _isFullscreen ? EdgeInsets.zero : const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: _isFullscreen ? BorderRadius.zero : BorderRadius.circular(16),
                            border: _isFullscreen ? null : Border.all(color: Colors.grey.shade200),
                            boxShadow: _isFullscreen ? [] : [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 12, offset: const Offset(0, 4))],
                          ),
                          child: ClipRRect(
                            borderRadius: _isFullscreen ? BorderRadius.zero : BorderRadius.circular(16),
                            child: (_isParsingPdf || !_isReady)
                                ? ExcludeSemantics(
                              excluding: _isParsingPdf || !_isReady,
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const CircularProgressIndicator(strokeWidth: 3),
                                    const SizedBox(height: 24),
                                    Text(
                                      '$_loadingStatusText (${(_parsingProgress * 100).toStringAsFixed(0)}%)',
                                      style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w600, fontSize: 13),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 16),
                                    Container(
                                      width: 240, height: 4,
                                      decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(2)),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Container(
                                          width: 240 * _parsingProgress, height: 4,
                                          decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(2)),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                                : IndexedStack(
                              index: (globalIsOriginalLayout && !_isTxtFile) ? 1 : 0,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: ScrollablePositionedList.builder(
                                    itemScrollController: _itemScrollController,
                                    itemPositionsListener: _itemPositionsListener,
                                    padding: const EdgeInsets.only(top: 52),
                                    itemCount: _chunksMetadata.length,
                                    itemBuilder: (context, index) {
                                      final bool isCurrent = index == _currentChunkIndex;
                                      final bool isSelected = index == _selectedChunkIndex;
                                      final bool isPending = index == _pendingJumpIndex;
                                      final int lvl = _headingLevel(index);
                                      final bool isHeading = lvl > 0;

                                      double fontSize;
                                      FontWeight fontWeight;
                                      EdgeInsets extraPad;
                                      switch (lvl) {
                                        case 1: fontSize = 22 * _textZoomFactor; fontWeight = FontWeight.w800; extraPad = const EdgeInsets.only(top: 12, bottom: 4);
                                        case 2: fontSize = 18 * _textZoomFactor; fontWeight = FontWeight.w700; extraPad = const EdgeInsets.only(top: 8, bottom: 2);
                                        case 3: fontSize = 15 * _textZoomFactor; fontWeight = FontWeight.w600; extraPad = const EdgeInsets.only(top: 4);
                                        default: fontSize = 16 * _textZoomFactor; fontWeight = FontWeight.normal; extraPad = EdgeInsets.zero;
                                      }

                                      Color bgColor = Colors.transparent;
                                      Border? border;
                                      if (isPending) {
                                        bgColor = Colors.orange.shade50;
                                        border = Border.all(color: Colors.orange.shade400, width: 2);
                                      } else if (_isBusy && isCurrent) {
                                        bgColor = Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3);
                                        border = Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5);
                                      } else if (isSelected) {
                                        bgColor = Colors.orange.shade50;
                                        border = Border.all(color: Colors.orange.shade400, width: 1.5);
                                      } else if (isCurrent && !_isBusy) {
                                        border = Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.4), width: 1);
                                      }

                                      final Widget textWidget = (_isBusy && isCurrent)
                                          ? RichText(text: TextSpan(
                                        style: TextStyle(fontSize: fontSize, height: 1.6, color: Colors.black87, fontWeight: fontWeight),
                                        children: _buildHighlightedWords(_chunksMetadata[index].text, context),
                                      ))
                                          : Text(_chunksMetadata[index].text, style: TextStyle(
                                        fontSize: fontSize,
                                        height: isHeading ? 1.3 : 1.6,
                                        fontWeight: fontWeight,
                                        color: index < _currentChunkIndex
                                            ? (isHeading ? Colors.grey.shade500 : Colors.grey.shade400)
                                            : (isHeading ? Colors.black : Colors.black87),
                                      ));

                                      return Padding(
                                        padding: extraPad,
                                        child: Container(
                                          margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                                          child: InkWell(
                                            onTap: () => setState(() { _selectedChunkIndex = index; }),
                                            borderRadius: BorderRadius.circular(8),
                                            child: AnimatedContainer(
                                              duration: const Duration(milliseconds: 150),
                                              padding: EdgeInsets.fromLTRB(isHeading ? 10 : 12, 10, 12, 10),
                                              decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(8), border: border),
                                              child: isHeading
                                                  ? Row(children: [
                                                Container(
                                                  width: 3, height: fontSize * 1.1,
                                                  margin: const EdgeInsets.only(right: 8),
                                                  decoration: BoxDecoration(
                                                    color: lvl == 1 ? Theme.of(context).colorScheme.primary
                                                        : lvl == 2 ? Theme.of(context).colorScheme.primary.withOpacity(0.6)
                                                        : Theme.of(context).colorScheme.primary.withOpacity(0.35),
                                                    borderRadius: BorderRadius.circular(2),
                                                  ),
                                                ),
                                                Expanded(child: textWidget),
                                              ])
                                                  : textWidget,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                if (!_isTxtFile)
                                  _buildPdfViewer()
                                else
                                  const SizedBox.shrink(),
                              ],
                            ),
                          ),
                        ),
                        if (!_isFullscreen && _tocEntries.isNotEmpty)
                          Positioned(top: 12, left: 12, child: _buildTocButton(context)),
                        if (_isUserScrolling && !_isFullscreen)
                          Positioned(
                            bottom: 16, right: 16,
                            child: FloatingActionButton.small(
                              onPressed: _recenterToCurrentChunk,
                              backgroundColor: const Color(0xFF1A73E8),
                              foregroundColor: Colors.white,
                              child: const Icon(Icons.center_focus_strong_rounded),
                            ),
                          ),
                        if (_isFullscreen)
                          Positioned(
                            top: 16, right: 16,
                            child: Container(
                              decoration: BoxDecoration(color: Colors.white.withOpacity(0.9), shape: BoxShape.circle),
                              child: IconButton(
                                icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.black87),
                                onPressed: () => setState(() => _isFullscreen = false),
                              ),
                            ),
                          ),
                        if (_isFullscreen)
                          Positioned(
                            bottom: 20, right: 16,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (_isUserScrolling) ...[
                                  FloatingActionButton.small(
                                    onPressed: _recenterToCurrentChunk,
                                    backgroundColor: const Color(0xFF1A73E8),
                                    foregroundColor: Colors.white,
                                    child: const Icon(Icons.center_focus_strong_rounded),
                                  ),
                                  const SizedBox(height: 10),
                                ],
                                // Mini playback island — black on white, slightly larger
                                Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(28),
                                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 12, offset: const Offset(0, 3))],
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    IconButton(
                                      icon: const Icon(Icons.replay_10_rounded, size: 26, color: Colors.black87),
                                      onPressed: _isBusy ? () => _seekRelative(-10) : null,
                                      padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                    ),
                                    IconButton(
                                      icon: Icon(
                                        _isBusy ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                        size: 28, color: Colors.black87,
                                      ),
                                      onPressed: _isReady ? (_isBusy ? _stopPdfReading : _startPdfReading) : null,
                                      padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.forward_10_rounded, size: 26, color: Colors.black87),
                                      onPressed: _isBusy ? () => _seekRelative(10) : null,
                                      padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                    ),
                                  ]),
                                ),
                              ],
                            ),
                          ),
                        if (_isFullscreen && _tocEntries.isNotEmpty)
                          Positioned(top: 16, left: 16, child: _buildTocButton(context)),
                      ],
                    ),
                  ),
                  if (!_isParsingPdf && !_isFullscreen) ...[
                    const SizedBox(height: 4),
                    ClipRRect(borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(value: progress,
                            backgroundColor: Colors.grey.shade200,
                            color: Theme.of(context).colorScheme.primary, minHeight: 4)),
                    const SizedBox(height: 2),
                    SizedBox(height: 48, child: Stack(alignment: Alignment.center, children: [
                      // Left: counter
                      Positioned(left: 0, child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.article_rounded, size: 12, color: Colors.grey),
                        const SizedBox(width: 3),
                        Text(
                            isCompleted ? 'Hotovo'
                                : (globalIsOriginalLayout && !_isTxtFile
                                ? 'Strana\u00A0$globalCurrentPdfPage/$globalTotalPdfPages'
                                : 'Blok\u00A0${_currentChunkIndex + 1}/${_chunksMetadata.length}'),
                            style: const TextStyle(fontSize: 10, color: Color(0xFF5F6368), fontWeight: FontWeight.w600)),
                      ])),
                      // Center: controls
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        IconButton(icon: const Icon(Icons.replay_10_rounded, size: 26),
                            onPressed: _isBusy ? () => _seekRelative(-10) : null,
                            padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36)),
                        const SizedBox(width: 6),
                        SizedBox(width: 48, height: 48, child: Material(type: MaterialType.transparency,
                            child: InkWell(customBorder: const CircleBorder(),
                                onTap: _isReady ? (showJumpButton ? _jumpToSelectedAndPlay
                                    : (isCompleted ? _restartAudioFromBeginning
                                    : (_isBusy ? _stopPdfReading : _startPdfReading))) : null,
                                child: showJumpButton
                                    ? Container(
                                  width: 44, height: 44,
                                  decoration: BoxDecoration(color: Colors.orange.shade700, shape: BoxShape.circle),
                                  child: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 28),
                                )
                                    : (isCompleted
                                    ? const Icon(Icons.replay_rounded, color: Color(0xFF1A73E8), size: 44)
                                    : Icon(_isBusy ? Icons.pause_circle_filled_rounded : Icons.play_circle_filled_rounded,
                                    color: _isBusy ? Colors.red.shade600 : const Color(0xFF1A73E8), size: 44))))),
                        const SizedBox(width: 6),
                        IconButton(icon: const Icon(Icons.forward_10_rounded, size: 26),
                            onPressed: _isBusy ? () => _seekRelative(10) : null,
                            padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36)),
                      ]),
                      // Right: speed + vol
                      Positioned(right: 0, child: Row(mainAxisSize: MainAxisSize.min, children: [
                        _buildSpeedButton(context),
                        const SizedBox(width: 4),
                        IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                            icon: Icon(_volume == 0.0 ? Icons.volume_off_rounded
                                : (_volume < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
                                size: 18, color: const Color(0xFF5F6368)),
                            onPressed: _toggleMute),
                        SizedBox(width: 76, child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10)),
                            child: Slider(value: _volume, min: 0.0, max: 1.0,
                                activeColor: Theme.of(context).colorScheme.primary,
                                inactiveColor: Colors.grey.shade300,
                                onChanged: (val) => _changeVolume(val)))),
                      ])),
                    ])),
                  ],                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}