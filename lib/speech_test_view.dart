import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import 'model.dart';
import 'main.dart';
import 'text_sanitizer.dart';

int globalCurrentChunkIndex = 0;
int globalCurrentWordIndex = 0;
bool globalIsAudioBusy = false;
String? globalActiveBookId;
bool globalIsOriginalLayout = false;
int globalCurrentPdfPage = 1;
int globalTotalPdfPages = 1;

class SpeechTestView extends StatefulWidget {
  final BookModel book;
  const SpeechTestView({super.key, required this.book});

  @override
  State<SpeechTestView> createState() => _SpeechTestViewState();
}

class _SpeechTestViewState extends State<SpeechTestView> {
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();
  final PdfViewerController _pdfViewerController = PdfViewerController();
  final ValueNotifier<HighlightData> _highlightNotifier = ValueNotifier<HighlightData>(HighlightData(sentenceRects: []));
  final FocusNode _keyboardFocusNode = FocusNode();

  StreamSubscription? _playbackStateSubscription;
  StreamSubscription? _positionSubscription;

  sf.PdfDocument? _loadedDocument;
  Size _pdfViewerSize = Size.zero;
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

  final SanitizerOptions _sanitizerOptions = SanitizerOptions();

  double _textZoomFactor = 1.0;
  double _pdfZoomFactor = 1.0;
  final double _zoomStep = 0.1;
  final double _minZoom = 0.1;
  final double _maxZoom = 5.0;

  double _playbackSpeed = 1.0;
  double _volume = 1.0;
  double _preMuteVolume = 1.0;
  bool _isFullscreen = false;
  double _parsingProgress = 0.0;

  bool _isMaxZoomReached = false;
  bool _isMinZoomReached = false;

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
      globalActiveBookId = widget.book.id;
      _currentChunkIndex = widget.book.lastChunkIndex;
      _currentWordIndex = 0;
      _isBusy = false;
      globalCurrentChunkIndex = _currentChunkIndex;
      globalCurrentWordIndex = _currentWordIndex;
      globalIsAudioBusy = _isBusy;
      globalIsOriginalLayout = false;
      globalCurrentPdfPage = 1;
      globalTotalPdfPages = 1;
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
    _itemPositionsListener.itemPositions.removeListener(_scrollListener);
    _playbackStateSubscription?.cancel();
    _positionSubscription?.cancel();
    _highlightNotifier.dispose();
    _keyboardFocusNode.dispose();
    _pdfViewerController.dispose();
    super.dispose();
  }

  void _scrollListener() {
    if (_chunksMetadata.isEmpty || _isParsingPdf || _isProgrammaticScrolling || globalIsOriginalLayout) return;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    bool currentVisible = positions.any((position) => position.index == _currentChunkIndex);
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

  List<PdfChunkMetadata> globalCachedChunks = [];
  sf.PdfDocument? globalCachedDocument;

  Future<void> _initEngineAndLoadPdf() async {
    // RECEPT: Pokud otevíráme stejný soubor, okamžitě naplníme lokální stav z globální cache
    if (globalActiveBookId == widget.book.id && globalCachedChunks.isNotEmpty) {
      _chunksMetadata.clear();
      _chunksMetadata.addAll(globalCachedChunks);
      _loadedDocument = globalCachedDocument;

      setState(() {
        _currentChunkIndex = globalCurrentChunkIndex;
        _currentWordIndex = globalCurrentWordIndex;
        _isReady = true;
        _isParsingPdf = false;
      });

      _recenterToCurrentChunk();
      return;
    }

    // Pokud otevíráme jiný soubor, vyčistíme starou cache a stopneme audio
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
    });

    globalActiveBookId = widget.book.id;

    await _initEngine();

    try {
      final file = File(widget.book.filePath);
      if (!await file.exists()) throw Exception("File does not exist.");

      if (_isTxtFile) {
        final content = await file.readAsString();
        _parseTxtWithProgress(content).listen(
              (progressValue) {
            if (!mounted) return;
            setState(() { _parsingProgress = progressValue; });
          },
          onDone: () {
            if (!mounted) return;

            globalCachedChunks = List.from(_chunksMetadata);
            globalCachedDocument = null;

            setState(() {
              globalTotalPdfPages = 1;
              _isParsingPdf = false;
              if (_chunksMetadata.isEmpty) {
                _chunksMetadata.add(PdfChunkMetadata(text: "Soubor neobsahuje žádný text.", pageNumber: 1, pdfWords: []));
                globalCachedChunks = List.from(_chunksMetadata);
              }
              _recenterToCurrentChunk();
            });
          },
        );
      } else {
        final bytes = await file.readAsBytes();
        _loadedDocument = sf.PdfDocument(inputBytes: bytes);
        globalTotalPdfPages = _loadedDocument!.pages.count;
        globalCachedDocument = _loadedDocument;

        TextSanitizer.parsePdfWithProgress(
          bytes: bytes,
          chunksTarget: _chunksMetadata,
          options: _sanitizerOptions,
          onChunkReady: () {
            if (mounted && _chunksMetadata.isNotEmpty && _currentChunkIndex < _chunksMetadata.length) {
              setState(() {
                globalCurrentPdfPage = _chunksMetadata[_currentChunkIndex].pageNumber;
              });
            }
          },
        ).listen(
              (progressValue) {
            if (!mounted) return;
            setState(() { _parsingProgress = progressValue; });
          },
          onDone: () {
            if (!mounted) return;

            globalCachedChunks = List.from(_chunksMetadata);

            setState(() {
              _isParsingPdf = false;
              if (_chunksMetadata.isEmpty) {
                _chunksMetadata.add(PdfChunkMetadata(text: "PDF neobsahuje žádný text.", pageNumber: 1, pdfWords: []));
                globalCachedChunks = List.from(_chunksMetadata);
              }
              _recenterToCurrentChunk();
            });
          },
        );
      }
    } catch (e) {
      if (mounted) setState(() { _isParsingPdf = false; });
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
      if (globalIsOriginalLayout && !_isTxtFile) _updatePdfVisualHighlights();
    }
  }

  void _handleTrackComplete() async {
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
      if (mounted) setState(() => _isReady = true);
      return;
    }

    try {
      final directory = await getApplicationSupportDirectory();
      const esSub = 'shared-espeak-ng-data';
      final esAssetDir = 'assets/models/kokoro-en-v0_19/espeak-ng-data';

      await _prepareFile('$esAssetDir/phontab', targetPath: '$esSub/phontab');
      await _prepareFile('$esAssetDir/phondata', targetPath: '$esSub/phondata');
      await _prepareFile('$esAssetDir/phondata-manifest', targetPath: '$esSub/phondata-manifest');
      await _prepareFile('$esAssetDir/phonindex', targetPath: '$esSub/phonindex');
      await _prepareFile('$esAssetDir/intonations', targetPath: '$esSub/intonations');

      if (_selectedModel.id == 'en_alan') {
        await _prepareFile('assets/models/vits-piper-en_GB-alan-medium/espeak-ng-data/en_dict', targetPath: '$esSub/en_dict');
      } else {
        await _prepareFile('$esAssetDir/en_dict', targetPath: '$esSub/en_dict');
      }

      await _prepareFile('assets/models/vits-piper-cs_CZ-jirka-medium/espeak-ng-data/cs_dict', targetPath: '$esSub/cs_dict');
      await _prepareFile('$esAssetDir/lang/gmw/en', targetPath: '$esSub/lang/gmw/en');
      await _prepareFile('$esAssetDir/lang/gmw/en-US', targetPath: '$esSub/lang/gmw/en-US');

      final voicesDir = Directory('${directory.path}/$esSub/voices');
      if (!await voicesDir.exists()) await voicesDir.create(recursive: true);
      await File('${voicesDir.path}/cs').writeAsString("name cs\nlanguage cs\n");
      await File('${voicesDir.path}/en-us').writeAsString("name en-us\nlanguage en-us\n");

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
      globalTts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: modelConfig, maxNumSenetences: 1));
      globalCurrentModelId = _selectedModel.id;
      if (mounted) setState(() => _isReady = true);
    } catch (e) {
      debugPrint('TTS setup error: $e');
    }
  }

  void _scrollToCurrentChunk(int index) {
    if (_chunksMetadata.isEmpty || index >= _chunksMetadata.length) return;
    if (globalIsOriginalLayout) {
      if (_isUserScrolling) return;
      if (!_isTxtFile) {
        _isProgrammaticScrolling = true;
        final chunk = _chunksMetadata[index];

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _pdfViewerController.jumpToPage(chunk.pageNumber);
        });

        _isProgrammaticScrolling = false;
      }
    } else {
      if (_itemScrollController.isAttached && !_isUserScrolling) {
        _isProgrammaticScrolling = true;
        _itemScrollController
            .scrollTo(index: index, alignment: 0.1, duration: const Duration(milliseconds: 250), curve: Curves.easeInOutCubic)
            .then((_) => _isProgrammaticScrolling = false);
      }
    }
  }

  void _updatePdfVisualHighlights() {
    if (_isTxtFile || _loadedDocument == null || !globalIsOriginalLayout || _currentChunkIndex >= _chunksMetadata.length || _pdfViewerSize == Size.zero) {
      _clearPdfHighlights();
      return;
    }
    final currentChunk = _chunksMetadata[_currentChunkIndex];
    final int targetPage = currentChunk.pageNumber;
    final sf.PdfPage nativePage = _loadedDocument!.pages[targetPage - 1];
    final double scaleFactor = (_pdfViewerSize.width / nativePage.size.width) * (_pdfZoomFactor < 1.0 ? 1.0 : _pdfZoomFactor);
    List<Rect> adjustedSentenceRects = [];
    Rect? adjustedWordRect;
    for (int i = 0; i < currentChunk.pdfWords.length; i++) {
      final pdfWord = currentChunk.pdfWords[i];
      final scaledRect = Rect.fromLTWH(
        pdfWord.bounds.left * scaleFactor,
        pdfWord.bounds.top * scaleFactor,
        pdfWord.bounds.width * scaleFactor,
        pdfWord.bounds.height * scaleFactor,
      );
      adjustedSentenceRects.add(scaledRect);
      if (_isBusy && i == _currentWordIndex) adjustedWordRect = scaledRect;
    }
    _highlightNotifier.value = HighlightData(sentenceRects: adjustedSentenceRects, wordRect: adjustedWordRect);
  }

  void _clearPdfHighlights() {
    _highlightNotifier.value = HighlightData(sentenceRects: []);
  }

  void _handlePdfTap(TapUpDetails d) {
    if (_isTxtFile || !globalIsOriginalLayout || _chunksMetadata.isEmpty || _pdfViewerSize == Size.zero) return;
    final int currentPage = _pdfViewerController.pageNumber;
    final sf.PdfPage nativePage = _loadedDocument!.pages[currentPage - 1];
    final double scaleFactor = (_pdfViewerSize.width / nativePage.size.width) * (_pdfZoomFactor < 1.0 ? 1.0 : _pdfZoomFactor);

    double actualX = d.localPosition.dx;
    double actualY = d.localPosition.dy;
    if (_pdfZoomFactor < 1.0) {
      actualX /= _pdfZoomFactor;
      actualY /= _pdfZoomFactor;
    }

    final Offset pdfPointsPos = Offset(actualX / scaleFactor, actualY / scaleFactor);
    for (int chunkIdx = 0; chunkIdx < _chunksMetadata.length; chunkIdx++) {
      final chunk = _chunksMetadata[chunkIdx];
      if (chunk.pageNumber != currentPage) continue;
      for (int wordIdx = 0; wordIdx < chunk.pdfWords.length; wordIdx++) {
        final word = chunk.pdfWords[wordIdx];
        if (word.bounds.contains(pdfPointsPos)) {
          setState(() {
            _currentChunkIndex = chunkIdx;
            _currentWordIndex = wordIdx;
            _isUserScrolling = false;
          });
          _saveCurrentProgress();
          if (_isBusy) _executeChunkReading(); else _startPdfReading();
          return;
        }
      }
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

  void _recenterToCurrentChunk() {
    setState(() { _isUserScrolling = false; });
    _scrollToCurrentChunk(_currentChunkIndex);
    if (globalIsOriginalLayout && !_isTxtFile) _updatePdfVisualHighlights();
  }

  void _startPdfReading() {
    if (_chunksMetadata.isEmpty || globalTts == null) return;
    setState(() { _isBusy = true; });
    _executeChunkReading();
  }

  void _stopPdfReading() async {
    setState(() { _isBusy = false; });
    if (Platform.isAndroid || Platform.isIOS) await audioHandler.stop(); else await windowsPlayer.stop();
    _updatePdfVisualHighlights();
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
    setState(() {
      _isBusy = true;
      _isUserScrolling = false;
    });
    if (Platform.isAndroid || Platform.isIOS) await audioHandler.stop(); else await windowsPlayer.stop();
    setState(() {
      _currentChunkIndex = _selectedChunkIndex!;
      _currentWordIndex = 0;
      _selectedChunkIndex = null;
    });
    _saveCurrentProgress();
    _executeChunkReading();
  }

  void _executeChunkReading() async {
    if (_currentChunkIndex >= _chunksMetadata.length || !_isBusy) {
      if (mounted) setState(() { _isBusy = false; });
      return;
    }
    try {
      final rawText = _chunksMetadata[_currentChunkIndex].text;
      _scrollToCurrentChunk(_currentChunkIndex);
      if (globalIsOriginalLayout && !_isTxtFile) {
        setState(() { globalCurrentPdfPage = _chunksMetadata[_currentChunkIndex].pageNumber; });
        _updatePdfVisualHighlights();
      }

      String? wavPath = _pregeneratedAudioCache[_currentChunkIndex];
      if (wavPath == null) {
        if (rawText.trim().isEmpty || globalTts == null) {
          _skipToNextFailedChunk();
          return;
        }
        final audio = globalTts!.generate(text: rawText, sid: _selectedModel.sid);
        final tempDir = await getTemporaryDirectory();
        wavPath = p.join(tempDir.path, 'chunk_${_currentChunkIndex}_${DateTime.now().millisecondsSinceEpoch}.wav');
        sherpa.writeWave(filename: wavPath, samples: audio.samples, sampleRate: audio.sampleRate);
      }

      if (_isBusy) {
        if (Platform.isAndroid || Platform.isIOS) {
          await audioHandler.playFile(wavPath, rawText);
        } else {
          await windowsPlayer.setVolume(_volume);
          await windowsPlayer.setSpeed(_playbackSpeed);
          await windowsPlayer.setFilePath(wavPath);
          await Future.delayed(const Duration(milliseconds: 150));
          windowsPlayer.play();
        }
        _bufferNextChunkAsync(_currentChunkIndex + 1);
      }
    } catch (e) {
      _skipToNextFailedChunk();
    }
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
        _pdfViewerController.zoomLevel = _pdfZoomFactor < 1.0 ? 1.0 : _pdfZoomFactor;
        _isMaxZoomReached = _pdfZoomFactor >= _maxZoom;
        _isMinZoomReached = _pdfZoomFactor <= _minZoom;
      } else {
        _textZoomFactor = (_textZoomFactor + delta).clamp(_minZoom, _maxZoom);
        _isMaxZoomReached = _textZoomFactor >= _maxZoom;
        _isMinZoomReached = _textZoomFactor <= _minZoom;
      }
    });
    if (!_isUserScrolling) {
      Future.delayed(const Duration(milliseconds: 50), () { _recenterToCurrentChunk(); });
    } else if (globalIsOriginalLayout && !_isTxtFile) {
      _updatePdfVisualHighlights();
    }
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
    // Ignorujeme jakékoliv zastavování. Audio handler i windowsPlayer běží dál.
    Navigator.of(context).pop();
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
                        onSelected: (ModelConfig newValue) {
                          setState(() {
                            _selectedModel = newValue;
                          });
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
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    model.langCode.toUpperCase(),
                                    style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.grey),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                _buildCpuIndicator(model.cpuLoad),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    model.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF1F1F1F)),
                                  ),
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
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  _selectedModel.langCode.toUpperCase(),
                                  style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.grey),
                                ),
                              ),
                              const SizedBox(width: 4),
                              _buildCpuIndicator(_selectedModel.cpuLoad),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  _selectedModel.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11, color: Color(0xFF1F1F1F), fontWeight: FontWeight.w600),
                                ),
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
                          if (globalIsOriginalLayout) _updatePdfVisualHighlights(); else _clearPdfHighlights();
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
                      child: Text('${(_currentZoomFactor * 100).toStringAsFixed(0)}%', style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w700)),
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
                    // Nastavením transparentního pozadí a nulových paddingů v splash struktuře zničíme šedé artefakty
                    splashRadius: 20,
                    tooltip: 'Parametry parsování',
                    onSelected: (value) async {
                      setState(() {
                        if (value == 'parentheses') {
                          _sanitizerOptions.readParentheses = !_sanitizerOptions.readParentheses;
                        } else if (value == 'links') {
                          _sanitizerOptions.readLinks = !_sanitizerOptions.readLinks;
                        } else if (value == 'pages') {
                          _sanitizerOptions.readPageNumbers = !_sanitizerOptions.readPageNumbers;
                        }
                      });
                      if (!_isParsingPdf && _isReady) {
                        _initEngineAndLoadPdf();
                      }
                    },
                    itemBuilder: (BuildContext context) => [
                      PopupMenuItem(
                        value: 'parentheses',
                        height: 38,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: Checkbox(
                                value: _sanitizerOptions.readParentheses,
                                activeColor: const Color(0xFF1A73E8),
                                onChanged: (bool? val) {
                                  Navigator.pop(context, 'parentheses');
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text('Číst závorky', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'links',
                        height: 38,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: Checkbox(
                                value: _sanitizerOptions.readLinks,
                                activeColor: const Color(0xFF1A73E8),
                                onChanged: (bool? val) {
                                  Navigator.pop(context, 'links');
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text('Číst odkazy', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'pages',
                        height: 38,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: Checkbox(
                                value: _sanitizerOptions.readPageNumbers,
                                activeColor: const Color(0xFF1A73E8),
                                onChanged: (bool? val) {
                                  Navigator.pop(context, 'pages');
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text('Číst čísla stran', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                    ],
                    // Tímto child parametrem vynutíme čisté vykreslení bez interního IconButton wrapperu z Material knhovny
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
                            child: _isParsingPdf
                                ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const CircularProgressIndicator(strokeWidth: 3),
                                  const SizedBox(height: 24),
                                  Text(
                                    'Načítám text a strukturu dokumentu... (${(_parsingProgress * 100).toStringAsFixed(0)}%)',
                                    style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w600, fontSize: 13),
                                  ),
                                  const SizedBox(height: 16),
                                  Container(
                                    width: 240, height: 4,
                                    decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(2)),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 60),
                                        width: 240 * _parsingProgress, height: 4,
                                        decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(2)),
                                      ),
                                    ),
                                  ),
                                ],
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
                                    itemCount: _chunksMetadata.length,
                                    itemBuilder: (context, index) {
                                      bool isCurrent = index == _currentChunkIndex;
                                      bool isSelected = index == _selectedChunkIndex;
                                      return InkWell(
                                        onTap: () => setState(() { _selectedChunkIndex = index; }),
                                        borderRadius: BorderRadius.circular(8),
                                        child: AnimatedContainer(
                                          duration: const Duration(milliseconds: 150),
                                          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: (_isBusy && isCurrent)
                                                ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3)
                                                : (isSelected ? Colors.orange.shade50 : Colors.transparent),
                                            borderRadius: BorderRadius.circular(8),
                                            border: isCurrent
                                                ? Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5)
                                                : (isSelected ? Border.all(color: Colors.orange.shade400, width: 1.5) : null),
                                          ),
                                          child: (_isBusy && isCurrent)
                                              ? RichText(
                                            text: TextSpan(
                                              style: TextStyle(fontSize: 17 * _textZoomFactor, height: 1.6, color: Colors.black87),
                                              children: _buildHighlightedWords(_chunksMetadata[index].text, context),
                                            ),
                                          )
                                              : Text(
                                            _chunksMetadata[index].text,
                                            style: TextStyle(
                                              fontSize: 16 * _textZoomFactor,
                                              height: 1.6,
                                              color: index < _currentChunkIndex ? Colors.grey.shade400 : Colors.black87,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                if (!_isTxtFile)
                                  Listener(
                                    onPointerSignal: _handlePointerSignal,
                                    child: NotificationListener<ScrollNotification>(
                                      onNotification: (notification) {
                                        if (!_isProgrammaticScrolling && (notification is ScrollUpdateNotification || notification is OverscrollNotification)) {
                                          if (!_isUserScrolling) { setState(() { _isUserScrolling = true; }); }
                                        }
                                        return false;
                                      },
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          _pdfViewerSize = Size(constraints.maxWidth, constraints.maxHeight);
                                          return GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTapUp: _handlePdfTap,
                                            child: FractionallySizedBox(
                                              widthFactor: _pdfZoomFactor < 1.0 ? _pdfZoomFactor : 1.0,
                                              heightFactor: _pdfZoomFactor < 1.0 ? _pdfZoomFactor : 1.0,
                                              alignment: Alignment.topCenter,
                                              child: Stack(
                                                children: [
                                                  SfPdfViewer.file(
                                                    File(widget.book.filePath),
                                                    controller: _pdfViewerController,
                                                    pageLayoutMode: PdfPageLayoutMode.continuous,
                                                    canShowScrollHead: false,
                                                    canShowTextSelectionMenu: false,
                                                    enableDoubleTapZooming: _pdfZoomFactor >= 1.0,
                                                    enableDocumentLinkAnnotation: true,
                                                    onTextSelectionChanged: null,
                                                    onDocumentLoaded: (details) {
                                                      _pdfViewerController.zoomLevel = _pdfZoomFactor < 1.0 ? 1.0 : _pdfZoomFactor;
                                                      _updatePdfVisualHighlights();
                                                    },
                                                    onPageChanged: (details) {
                                                      setState(() { globalCurrentPdfPage = details.newPageNumber; });
                                                    },
                                                    onZoomLevelChanged: (details) {
                                                      setState(() {
                                                        _pdfZoomFactor = details.newZoomLevel;
                                                        _isMaxZoomReached = _pdfZoomFactor >= _maxZoom;
                                                        _isMinZoomReached = _pdfZoomFactor <= _minZoom;
                                                      });
                                                      _updatePdfVisualHighlights();
                                                    },
                                                  ),
                                                  IgnorePointer(
                                                    child: ValueListenableBuilder<HighlightData>(
                                                      valueListenable: _highlightNotifier,
                                                      builder: (context, data, _) => CustomPaint(
                                                        size: Size.infinite,
                                                        painter: PdfHighlightPainter(
                                                          sentenceRects: data.sentenceRects,
                                                          wordRect: data.wordRect,
                                                          primaryColor: _isBusy
                                                              ? Theme.of(context).colorScheme.primary
                                                              : Theme.of(context).colorScheme.primary.withOpacity(0.5),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  )
                                else
                                  const SizedBox.shrink(),
                              ],
                            ),
                          ),
                        ),
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
                      ],
                    ),
                  ),
                  if (!_isParsingPdf && !_isFullscreen) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade200)),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.auto_stories_rounded, size: 14, color: Colors.grey),
                              const SizedBox(width: 6),
                              Text(
                                isCompleted
                                    ? 'Hotovo'
                                    : ((globalIsOriginalLayout && !_isTxtFile)
                                    ? 'Strana: $globalCurrentPdfPage / $globalTotalPdfPages'
                                    : 'Blok: ${_currentChunkIndex + 1} / ${_chunksMetadata.length}'),
                                style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368), fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                          PopupMenuButton<double>(
                            offset: const Offset(0, -220),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            onSelected: (double val) {
                              _changeSpeed(val);
                            },
                            itemBuilder: (BuildContext context) => [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 3.5, 4.0]
                                .map<PopupMenuEntry<double>>((double s) {
                              return PopupMenuItem<double>(
                                value: s,
                                height: 32,
                                child: Text('${s}x', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                              );
                            }).toList(),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              decoration: BoxDecoration(color: const Color(0xFFF1F3F4), borderRadius: BorderRadius.circular(6)),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('${_playbackSpeed}x', style: const TextStyle(fontSize: 11, fontFamily: 'sans-serif', fontWeight: FontWeight.w700, color: Color(0xFF1F1F1F))),
                                  const SizedBox(width: 2),
                                  const Icon(Icons.keyboard_arrow_up_rounded, color: Color(0xFF5F6368), size: 14),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        backgroundColor: Colors.grey.shade200,
                        color: Theme.of(context).colorScheme.primary,
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.replay_10_rounded, size: 28),
                              onPressed: _isBusy ? () => _seekRelative(-10) : null,
                            ),
                            const SizedBox(width: 16),
                            SizedBox(
                              width: 64, height: 64,
                              child: Center(
                                child: Material(
                                  type: MaterialType.transparency,
                                  child: InkWell(
                                    customBorder: const CircleBorder(),
                                    onTap: _isReady
                                        ? (isCompleted
                                        ? _restartAudioFromBeginning
                                        : (_isBusy ? _stopPdfReading : _startPdfReading))
                                        : null,
                                    child: showJumpButton
                                        ? IconButton(
                                      padding: EdgeInsets.zero,
                                      icon: Icon(Icons.play_circle_filled_rounded, color: Colors.orange.shade700, size: 54),
                                      onPressed: _jumpToSelectedAndPlay,
                                    )
                                        : (isCompleted
                                        ? IconButton(
                                      padding: EdgeInsets.zero,
                                      icon: const Icon(Icons.replay_rounded, color: Color(0xFF1A73E8), size: 54),
                                      onPressed: _restartAudioFromBeginning,
                                    )
                                        : IconButton(
                                      padding: EdgeInsets.zero,
                                      icon: Icon(
                                        _isBusy ? Icons.pause_circle_filled_rounded : Icons.play_circle_filled_rounded,
                                        color: _isBusy ? Colors.red.shade600 : const Color(0xFF1A73E8),
                                        size: 54,
                                      ),
                                      onPressed: _isReady
                                          ? (_isBusy ? _stopPdfReading : _startPdfReading)
                                          : null,
                                    )),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            IconButton(
                              icon: const Icon(Icons.forward_10_rounded, size: 28),
                              onPressed: _isBusy ? () => _seekRelative(10) : null,
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
                                  size: 18,
                                  color: const Color(0xFF5F6368),
                                ),
                                onPressed: _toggleMute,
                              ),
                              SizedBox(
                                width: 90,
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 3,
                                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}