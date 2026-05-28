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

class SpeechTestView extends StatefulWidget {
  final BookModel book;
  const SpeechTestView({super.key, required this.book});
  @override
  State<SpeechTestView> createState() => _SpeechTestViewState();
}

class _SpeechTestViewState extends State<SpeechTestView> {
  sherpa.OfflineTts? _tts;
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();
  final PdfViewerController _pdfViewerController = PdfViewerController();
  final ValueNotifier<HighlightData> _highlightNotifier = ValueNotifier<HighlightData>(HighlightData(sentenceRects: []));
  final FocusNode _keyboardFocusNode = FocusNode();

  sf.PdfDocument? _loadedDocument;
  Size _pdfViewerSize = Size.zero;
  bool _isReady = false;
  bool _isBusy = false;
  bool _isParsingPdf = false;
  bool _isBufferingNext = false;
  bool _needsModelSelection = true;
  ModelConfig _selectedModel = availableModels.first;
  final List<PdfChunkMetadata> _chunksMetadata = [];
  int _currentChunkIndex = 0;
  int _currentWordIndex = 0;
  int _lastProcessedWordIndex = -1;
  int? _selectedChunkIndex;
  bool _showOriginalLayout = false;
  bool _isUserScrolling = false;
  bool _isProgrammaticScrolling = false;
  final Map<int, String> _pregeneratedAudioCache = {};
  final String _cleanupMode = 'chytreParsovani';

  double _currentZoomFactor = 1.0;
  final double _zoomStep = 0.1;
  final double _minZoom = 0.4;
  final double _maxZoom = 4.0;

  bool get _isTxtFile => widget.book.filePath.toLowerCase().endsWith('.txt');

  @override
  void initState() {
    super.initState();
    _currentChunkIndex = widget.book.lastChunkIndex;

    if (widget.book.lastModelId != null) {
      _needsModelSelection = false;
      final found = availableModels.firstWhere((m) => m.id == widget.book.lastModelId, orElse: () => availableModels.first);
      _selectedModel = found;
      _initEngineAndLoadPdf();
    }

    _itemPositionsListener.itemPositions.addListener(() {
      if (_chunksMetadata.isEmpty || _isParsingPdf || _isProgrammaticScrolling || _showOriginalLayout) return;
      final positions = _itemPositionsListener.itemPositions.value;
      if (positions.isEmpty) return;
      bool currentVisible = positions.any((position) => position.index == _currentChunkIndex);
      if (!currentVisible && !_isUserScrolling) setState(() { _isUserScrolling = true; });
    });

    if (Platform.isAndroid || Platform.isIOS) {
      audioHandler.playbackState.listen((state) {
        if (state.processingState == AudioProcessingState.completed && _isBusy) _handleTrackComplete();
      });
      audioHandler.player.positionStream.listen((p) => _updateWordHighlight(p));
    } else {
      windowsPlayer.processingStateStream.listen((state) {
        if (state == ProcessingState.completed && _isBusy) _handleTrackComplete();
      });
      windowsPlayer.positionStream.listen((p) => _updateWordHighlight(p));
    }
  }

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

  Future<void> _initEngineAndLoadPdf() async {
    setState(() {
      _isParsingPdf = true;
      _isReady = false;
    });

    await _initEngine();

    try {
      final file = File(widget.book.filePath);
      if (!await file.exists()) throw Exception("Soubor neexistuje.");

      if (_isTxtFile) {
        final content = await file.readAsString();
        final parsedChunks = await compute(_parseTxtInBackground, {'content': content});
        setState(() {
          _chunksMetadata.clear();
          _pregeneratedAudioCache.clear();
          _chunksMetadata.addAll(parsedChunks);
          if (_chunksMetadata.isEmpty) {
            _chunksMetadata.add(PdfChunkMetadata(text: "Soubor neobsahuje text.", pageNumber: 1, pdfWords: []));
          }
          _isParsingPdf = false;
        });
      } else {
        final bytes = await file.readAsBytes();
        _loadedDocument = sf.PdfDocument(inputBytes: bytes);

        final parsedChunks = await compute(_parsePdfInBackground, {
          'bytes': bytes,
          'cleanupMode': _cleanupMode,
        });

        setState(() {
          _chunksMetadata.clear();
          _pregeneratedAudioCache.clear();
          _chunksMetadata.addAll(parsedChunks);
          if (_chunksMetadata.isEmpty) {
            _chunksMetadata.add(PdfChunkMetadata(text: "PDF neobsahuje text.", pageNumber: 1, pdfWords: []));
          }
          _isParsingPdf = false;
        });
      }

      Future.delayed(const Duration(milliseconds: 300), () {
        _scrollToCurrentChunk(_currentChunkIndex);
      });
    } catch (e) {
      setState(() { _isParsingPdf = false; });
    }
  }

  static List<PdfChunkMetadata> _parseTxtInBackground(Map<String, dynamic> args) {
    final String content = args['content'];
    final List<PdfChunkMetadata> localChunks = [];
    final List<String> rawSentences = content.split(RegExp(r'(?<=[.!?])\s+'));

    for (var sentence in rawSentences) {
      final clean = sentence.trim();
      if (clean.isNotEmpty) {
        localChunks.add(PdfChunkMetadata(text: clean, pageNumber: 1, pdfWords: []));
      }
    }
    return localChunks;
  }

  static List<PdfChunkMetadata> _parsePdfInBackground(Map<String, dynamic> args) {
    final Uint8List bytes = args['bytes'];
    final String cleanupMode = args['cleanupMode'];
    final List<PdfChunkMetadata> localChunks = [];

    final sf.PdfDocument document = sf.PdfDocument(inputBytes: bytes);
    final sf.PdfTextExtractor extractor = sf.PdfTextExtractor(document);

    for (int pageIdx = 0; pageIdx < document.pages.count; pageIdx++) {
      final List<sf.TextLine> textLines = extractor.extractTextLines(startPageIndex: pageIdx, endPageIndex: pageIdx);
      List<PdfWordGeometry> sentenceWordsCollector = [];
      StringBuffer sentenceTextCollector = StringBuffer();
      StringBuffer reconstructedWordText = StringBuffer();
      Rect? reconstructedWordBounds;

      for (final sf.TextLine line in textLines) {
        if (line.wordCollection.isEmpty) continue;
        for (final sf.TextWord word in line.wordCollection) {
          String part = word.text;
          if (reconstructedWordText.isEmpty) {
            reconstructedWordBounds = word.bounds;
          } else if (reconstructedWordBounds != null) {
            reconstructedWordBounds = reconstructedWordBounds.expandToInclude(word.bounds);
          }
          reconstructedWordText.write(part);
          if (part.endsWith(' ') || part == '\n' || part == '\r' || word == line.wordCollection.last) {
            String cleanWord = reconstructedWordText.toString().trim();
            reconstructedWordText.clear();
            if (cleanWord.isEmpty) continue;
            if (cleanupMode == 'chytreParsovani') {
              if (cleanWord.contains(RegExp(r'https?://\S+|www\.\S+'))) continue;
              if (RegExp(r'^\d+$').hasMatch(cleanWord) || RegExp(r'^\[\d+\]$').hasMatch(cleanWord)) continue;
            }
            if (sentenceTextCollector.isEmpty) {
              sentenceTextCollector.write(cleanWord);
            } else {
              sentenceTextCollector.write(" $cleanWord");
            }
            if (reconstructedWordBounds != null) {
              sentenceWordsCollector.add(PdfWordGeometry(bounds: reconstructedWordBounds, text: cleanWord));
            }
            bool isEndOfSentence = cleanWord.endsWith('.') || cleanWord.endsWith('?') || cleanWord.endsWith('!');
            if (isEndOfSentence || sentenceTextCollector.length > 140) {
              final formattedText = sentenceTextCollector.toString().trim();
              if (formattedText.isNotEmpty) {
                localChunks.add(PdfChunkMetadata(text: formattedText, pageNumber: pageIdx + 1, pdfWords: List.from(sentenceWordsCollector)));
              }
              sentenceTextCollector.clear();
              sentenceWordsCollector.clear();
            }
          }
        }
      }
      if (sentenceTextCollector.isNotEmpty) {
        final formattedText = sentenceTextCollector.toString().trim();
        if (formattedText.isNotEmpty) {
          localChunks.add(PdfChunkMetadata(text: formattedText, pageNumber: pageIdx + 1, pdfWords: List.from(sentenceWordsCollector)));
        }
      }
    }
    document.dispose();
    return localChunks;
  }

  void _updateWordHighlight(Duration position) {
    if (!_isBusy || _chunksMetadata.isEmpty || _currentChunkIndex >= _chunksMetadata.length) return;
    final currentChunk = _chunksMetadata[_currentChunkIndex];
    List<String> words = currentChunk.text.split(' ');
    if (words.isEmpty) return;
    final totalDuration = (Platform.isAndroid || Platform.isIOS) ? audioHandler.player.duration : windowsPlayer.duration;
    if (totalDuration == null || totalDuration.inMilliseconds == 0) return;
    double progress = position.inMilliseconds / totalDuration.inMilliseconds;
    int calculatedWordIndex = (progress * words.length).floor();
    if (calculatedWordIndex != _currentWordIndex && calculatedWordIndex < words.length) {
      _currentWordIndex = calculatedWordIndex;
      if (_showOriginalLayout && !_isTxtFile) {
        _updatePdfVisualHighlights();
      } else {
        setState(() {});
      }
    }
  }

  void _handleTrackComplete() async {
    _currentWordIndex = 0;
    _lastProcessedWordIndex = -1;
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

      if (modelPath.isEmpty || tokensPath.isEmpty) throw Exception("Chyba načítání souborů.");

      if (_selectedModel.id == 'en_kokoro') {
        final extraPath = await _prepareFile('${_selectedModel.assetDir}/${_selectedModel.configFile}', targetPath: _selectedModel.configFile);
        modelConfig = sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
              model: modelPath, voices: extraPath, tokens: tokensPath, dataDir: espeakDataPath
          ),
          numThreads: 4, debug: true,
        );
      } else {
        await _prepareFile('${_selectedModel.assetDir}/${_selectedModel.configFile}', targetPath: '${_selectedModel.id}_config.json');
        modelConfig = sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: modelPath, tokens: tokensPath, dataDir: espeakDataPath,
            noiseScale: 0.667, noiseScaleW: 0.8, lengthScale: 1.0,
          ),
          numThreads: 4, debug: true,
        );
      }

      _tts?.free();
      _tts = null;
      await Future.delayed(const Duration(milliseconds: 50));
      _tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: modelConfig, maxNumSenetences: 1));
      if (mounted) setState(() => _isReady = true);
    } catch (e) {
      debugPrint('TTS setup error: $e');
    }
  }

  void _scrollToCurrentChunk(int index) {
    if (_itemScrollController.isAttached && _chunksMetadata.isNotEmpty && !_isUserScrolling && !_showOriginalLayout) {
      _isProgrammaticScrolling = true;
      _itemScrollController.scrollTo(index: index, alignment: 0.1, duration: const Duration(milliseconds: 250), curve: Curves.easeInOutCubic).then((_) => _isProgrammaticScrolling = false);
    }
    if (_chunksMetadata.isNotEmpty && index < _chunksMetadata.length && _showOriginalLayout && !_isTxtFile) {
      _isProgrammaticScrolling = true;
      _pdfViewerController.jumpToPage(_chunksMetadata[index].pageNumber);
      _isProgrammaticScrolling = false;
    }
  }

  void _updatePdfVisualHighlights() {
    if (_isTxtFile || _loadedDocument == null || !_showOriginalLayout || !_isBusy || _currentChunkIndex >= _chunksMetadata.length || _pdfViewerSize == Size.zero) {
      _clearPdfHighlights();
      return;
    }
    if (_currentWordIndex == _lastProcessedWordIndex) return;
    _lastProcessedWordIndex = _currentWordIndex;
    final currentChunk = _chunksMetadata[_currentChunkIndex];
    final int targetPage = currentChunk.pageNumber;
    final sf.PdfPage nativePage = _loadedDocument!.pages[targetPage - 1];
    final double scaleFactor = (_pdfViewerSize.width / nativePage.size.width) * _currentZoomFactor;
    List<Rect> adjustedSentenceRects = [];
    Rect? adjustedWordRect;
    for (int i = 0; i < currentChunk.pdfWords.length; i++) {
      final pdfWord = currentChunk.pdfWords[i];
      final scaledRect = Rect.fromLTWH(pdfWord.bounds.left * scaleFactor, pdfWord.bounds.top * scaleFactor, pdfWord.bounds.width * scaleFactor, pdfWord.bounds.height * scaleFactor);
      adjustedSentenceRects.add(scaledRect);
      if (i == _currentWordIndex) adjustedWordRect = scaledRect;
    }
    _highlightNotifier.value = HighlightData(sentenceRects: adjustedSentenceRects, wordRect: adjustedWordRect);
  }

  void _clearPdfHighlights() {
    _highlightNotifier.value = HighlightData(sentenceRects: []);
    _lastProcessedWordIndex = -1;
  }

  void _handlePdfTap(TapUpDetails d) {
    if (_isTxtFile || !_showOriginalLayout || _chunksMetadata.isEmpty || _pdfViewerSize == Size.zero) return;
    final int currentPage = _pdfViewerController.pageNumber;
    final sf.PdfPage nativePage = _loadedDocument!.pages[currentPage - 1];
    final double scaleFactor = (_pdfViewerSize.width / nativePage.size.width) * _currentZoomFactor;
    final Offset pdfPointsPos = Offset(d.localPosition.dx / scaleFactor, d.localPosition.dy / scaleFactor);
    for (int chunkIdx = 0; chunkIdx < _chunksMetadata.length; chunkIdx++) {
      final chunk = _chunksMetadata[chunkIdx];
      if (chunk.pageNumber != currentPage) continue;
      for (int wordIdx = 0; wordIdx < chunk.pdfWords.length; wordIdx++) {
        final word = chunk.pdfWords[wordIdx];
        if (word.bounds.contains(pdfPointsPos)) {
          setState(() { _currentChunkIndex = chunkIdx; _currentWordIndex = wordIdx; _lastProcessedWordIndex = -1; _isUserScrolling = false; });
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
      if (rawText.trim().isEmpty || _tts == null) return;

      final audio = _tts!.generate(text: rawText, sid: _selectedModel.sid);
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
    if (_showOriginalLayout && !_isTxtFile) _updatePdfVisualHighlights();
  }

  void _startPdfReading() {
    if (_chunksMetadata.isEmpty || _tts == null) return;
    setState(() { _isBusy = true; });
    _executeChunkReading();
  }

  void _stopPdfReading() async {
    setState(() { _isBusy = false; });
    if (Platform.isAndroid || Platform.isIOS) await audioHandler.stop(); else await windowsPlayer.stop();
    _clearPdfHighlights();
  }

  void _jumpToSelectedAndPlay() async {
    if (_selectedChunkIndex == null || _selectedChunkIndex! >= _chunksMetadata.length) return;
    setState(() { _isBusy = true; _isUserScrolling = false; });
    if (Platform.isAndroid || Platform.isIOS) await audioHandler.stop(); else await windowsPlayer.stop();
    setState(() { _currentChunkIndex = _selectedChunkIndex!; _currentWordIndex = 0; _lastProcessedWordIndex = -1; _selectedChunkIndex = null; });
    _saveCurrentProgress();
    _executeChunkReading();
  }

  void _executeChunkReading() async {
    if (_currentChunkIndex >= _chunksMetadata.length || !_isBusy) {
      setState(() { _isBusy = false; });
      return;
    }
    try {
      final rawText = _chunksMetadata[_currentChunkIndex].text;
      _scrollToCurrentChunk(_currentChunkIndex);
      if (_showOriginalLayout && !_isTxtFile) _updatePdfVisualHighlights();

      String? wavPath = _pregeneratedAudioCache[_currentChunkIndex];
      if (wavPath == null) {
        if (rawText.trim().isEmpty || _tts == null) { _skipToNextFailedChunk(); return; }
        final audio = _tts!.generate(text: rawText, sid: _selectedModel.sid);
        final tempDir = await getTemporaryDirectory();
        wavPath = p.join(tempDir.path, 'chunk_${_currentChunkIndex}_${DateTime.now().millisecondsSinceEpoch}.wav');
        sherpa.writeWave(filename: wavPath, samples: audio.samples, sampleRate: audio.sampleRate);
      }

      if (_isBusy) {
        if (Platform.isAndroid || Platform.isIOS) {
          await audioHandler.playFile(wavPath, rawText);
        } else {
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

  void _skipToNextFailedChunk() {
    _currentWordIndex = 0;
    _lastProcessedWordIndex = -1;
    _currentChunkIndex++;
    _saveCurrentProgress();
    _executeChunkReading();
  }

  void _changeZoom(double delta) {
    setState(() {
      _currentZoomFactor = (_currentZoomFactor + delta).clamp(_minZoom, _maxZoom);
      _pdfViewerController.zoomLevel = _currentZoomFactor;
      if (_showOriginalLayout && !_isTxtFile) _updatePdfVisualHighlights();
    });
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
      if (event.scrollDelta.dy < 0) _changeZoom(_zoomStep); else if (event.scrollDelta.dy > 0) _changeZoom(-_zoomStep);
    }
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
          decoration: BoxDecoration(color: color.withOpacity(color == Colors.transparent ? 0.15 : 1), borderRadius: BorderRadius.circular(1)),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    double progress = _chunksMetadata.isEmpty ? 0.0 : _currentChunkIndex / _chunksMetadata.length;
    bool showJumpButton = _selectedChunkIndex != null;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_keyboardFocusNode.canRequestFocus) _keyboardFocusNode.requestFocus();
    });

    return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp, control: true): () => _changeZoom(_zoomStep),
          const SingleActivator(LogicalKeyboardKey.arrowDown, control: true): () => _changeZoom(-_zoomStep),
        },
        child: Focus(
          focusNode: _keyboardFocusNode,
          child: Scaffold(
            backgroundColor: const Color(0xFFF8F9FA),
            appBar: _needsModelSelection
                ? null
                : AppBar(
              automaticallyImplyLeading: true,
              elevation: 0,
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              shape: Border(bottom: BorderSide(color: Colors.grey.shade200, width: 1)),
              titleSpacing: 0,
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF1F1F1F)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 190,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: const Color(0xFFE8F0FE), borderRadius: BorderRadius.circular(8)),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<ModelConfig>(
                        value: _selectedModel,
                        isExpanded: true,
                        icon: _isParsingPdf || !_isReady
                            ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey))
                            : const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.grey, size: 18),
                        style: const TextStyle(fontSize: 12, color: Color(0xFF1F1F1F), fontWeight: FontWeight.w600),
                        onChanged: !_isBusy && !_isParsingPdf && _isReady ? (ModelConfig? newValue) {
                          if (newValue != null) {
                            setState(() { _selectedModel = newValue; });
                            _initEngineAndLoadPdf();
                          }
                        } : null,
                        items: availableModels.map<DropdownMenuItem<ModelConfig>>((ModelConfig model) {
                          return DropdownMenuItem<ModelConfig>(
                            value: model,
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3)),
                                  child: Text(model.langCode.toUpperCase(), style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.grey)),
                                ),
                                const SizedBox(width: 6),
                                _buildCpuIndicator(model.cpuLoad),
                                const SizedBox(width: 6),
                                Expanded(child: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
              actions: [
                if (!_isTxtFile)
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFF1A73E8)),
                    onPressed: () {
                      setState(() => _showOriginalLayout = !_showOriginalLayout);
                      _scrollToCurrentChunk(_currentChunkIndex);
                      if (_showOriginalLayout) _updatePdfVisualHighlights(); else _clearPdfHighlights();
                    },
                    icon: Icon(_showOriginalLayout ? Icons.picture_as_pdf : Icons.text_fields_rounded, size: 20),
                    label: Text(_showOriginalLayout ? 'Původní PDF' : 'Čistý text', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12.0),
                    child: Center(child: Text('Čistý text', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1A73E8)))),
                  ),
                const VerticalDivider(width: 16, indent: 16, endIndent: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(right: 2.0),
                      child: Icon(Icons.search_rounded, size: 16, color: Color(0xFF1A73E8)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
                      onPressed: () => _changeZoom(-_zoomStep),
                    ),
                    Container(
                      constraints: const BoxConstraints(minWidth: 42),
                      alignment: Alignment.center,
                      child: Text(
                        '${(_currentZoomFactor * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                      onPressed: () => _changeZoom(_zoomStep),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
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
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                  Expanded(
                  child: Stack(
                  children: [
                    Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white, borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade200),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 12, offset: const Offset(0, 4))],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: _isParsingPdf
                          ? const Center(child: DynamicPositionsParserIndicator())
                          : IndexedStack(
                        index: (_showOriginalLayout && !_isTxtFile) ? 1 : 0,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: ScrollablePositionedList.builder(
                              itemScrollController: _itemScrollController,
                              itemPositionsListener: _itemPositionsListener,
                              itemCount: _chunksMetadata.length,
                              itemBuilder: (context, index) {
                                bool isCurrent = _isBusy && index == _currentChunkIndex;
                                bool isSelected = index == _selectedChunkIndex;
                                return InkWell(
                                  onTap: () => setState(() { _selectedChunkIndex = index; }),
                                  borderRadius: BorderRadius.circular(8),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 150),
                                    margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: isCurrent
                                          ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3)
                                          : (isSelected ? Colors.orange.shade50 : Colors.transparent),
                                      borderRadius: BorderRadius.circular(8),
                                      border: isSelected ? Border.all(color: Colors.orange.shade400, width: 1.5) : null,
                                    ),
                                    child: isCurrent
                                        ? RichText(
                                      text: TextSpan(
                                        style: TextStyle(fontSize: 17 * _currentZoomFactor, height: 1.6, color: Colors.black87),
                                        children: _buildHighlightedWords(_chunksMetadata[index].text, context),
                                      ),
                                    )
                                        : Text(
                                      _chunksMetadata[index].text,
                                      style: TextStyle(
                                        fontSize: 16 * _currentZoomFactor, height: 1.6,
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
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  _pdfViewerSize = Size(constraints.maxWidth, constraints.maxHeight);
                                  return GestureDetector(
                                    onTapUp: _handlePdfTap,
                                    child: Stack(
                                      children: [
                                        SfPdfViewer.file(
                                          File(widget.book.filePath),
                                          controller: _pdfViewerController,
                                          pageLayoutMode: PdfPageLayoutMode.single,
                                          canShowScrollHead: false, canShowTextSelectionMenu: false,
                                          enableDoubleTapZooming: true, enableDocumentLinkAnnotation: true,
                                          onDocumentLoaded: (details) {
                                            _pdfViewerController.zoomLevel = _currentZoomFactor;
                                          },
                                        ),
                                        IgnorePointer(
                                          child: ValueListenableBuilder<HighlightData>(
                                            valueListenable: _highlightNotifier,
                                            builder: (context, data, _) => CustomPaint(
                                              size: Size.infinite,
                                              painter: PdfHighlightPainter(
                                                sentenceRects: data.sentenceRects, wordRect: data.wordRect,
                                                primaryColor: Theme.of(context).colorScheme.primary,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            )
                          else
                            const SizedBox.shrink(),
                        ],
                      ),
                    ),
                  ),
                  if (_isUserScrolling)
              Positioned(
              bottom: 16, right: 16,
              child: FloatingActionButton.small(
                onPressed: _recenterToCurrentChunk,
                backgroundColor: const Color(0xFF1A73E8),
                foregroundColor: Colors.white,
                child: const Icon(Icons.center_focus_strong_rounded),
              ),
            ),
            ],
          ),
        ),
        if (!_isParsingPdf) ...[
    const SizedBox(height: 16),
    Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade200)),
    child: Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
    Row(
    children: [
    const Icon(Icons.grid_view_rounded, size: 14, color: Colors.grey),
    const SizedBox(width: 6),
    Text('Blok: ${_currentChunkIndex + 1} / ${_chunksMetadata.length}', style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368), fontWeight: FontWeight.w600)),
    ],
    ),
    ],
    ),
    ),
    const SizedBox(height: 12),
    ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: LinearProgressIndicator(value: progress, backgroundColor: Colors.grey.shade200, color: Theme.of(context).colorScheme.primary, minHeight: 6),
    ),
    const SizedBox(height: 16),
    Row(
    children: [
    Expanded(
    child: SizedBox(
    height: 54,
    child: showJumpButton
    ? FilledButton.icon(
    onPressed: _jumpToSelectedAndPlay,
    style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    icon: const Icon(Icons.play_circle_filled_rounded), label: const Text('SPUSTIT OD VYBRANÉHO MÍSTA', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.2)),
    )
        : FilledButton.icon(
    onPressed: _isReady ? (_isBusy ? _stopPdfReading : _startPdfReading) : null,
    style: FilledButton.styleFrom(backgroundColor: _isBusy ? Colors.red.shade600 : const Color(0xFF1A73E8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    icon: Icon(_isBusy ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 22),
    label: Text(_isBusy ? 'ZASTAVIT ČTENÍ' : 'SPUSTIT PŘEHRÁVÁNÍ', style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.2)),
    ),
    ),
    ),
    ],
    ),
    ],
    ]),
    ),
    ),
    )));
    }

  List<TextSpan> _buildHighlightedWords(String text, BuildContext context) {
    List<String> words = text.split(' ');
    List<TextSpan> spans = [];
    for (int i = 0; i < words.length; i++) {
      bool isCurrent = i == _currentWordIndex;
      spans.add(TextSpan(text: words[i] + (i == words.length - 1 ? "" : " "), style: TextStyle(fontWeight: i == _currentWordIndex ? FontWeight.bold : FontWeight.normal, backgroundColor: isCurrent ? Theme.of(context).colorScheme.primary.withOpacity(0.2) : Colors.transparent, color: isCurrent ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onPrimaryContainer)));
    }
    return spans;
  }
}

class DynamicPositionsParserIndicator extends StatelessWidget {
  const DynamicPositionsParserIndicator({super.key});
  @override
  Widget build(BuildContext context) {
    return const Column(mainAxisAlignment: MainAxisAlignment.center, children: [CircularProgressIndicator(strokeWidth: 3), SizedBox(height: 20), Text('Načítám text a strukturu dokumentu...', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600, fontSize: 13))]);
  }
}