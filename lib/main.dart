import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';

late MyAudioHandler _audioHandler;
late AudioPlayer _windowsPlayer;
final bool _isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  sherpa.initBindings();

  if (_isMobile) {
    _audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.free_voice_reader.channel.audio',
        androidNotificationChannelName: 'Čtečka knih',
        androidNotificationOngoing: true,
        androidShowNotificationBadge: true,
      ),
    );
  } else {
    _windowsPlayer = AudioPlayer();
  }

  runApp(const MyApp());
}

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();

  MyAudioHandler() {
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
  }

  AudioPlayer get player => _player;

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  Future<void> playFile(String path, String title) async {
    mediaItem.add(MediaItem(
      id: path,
      album: "free_voice_reader",
      title: title,
      artist: "AI Hlas",
    ));
    await _player.setFilePath(path);
    _player.play();
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    final stateMap = const {
      ProcessingState.idle: AudioProcessingState.idle,
      ProcessingState.loading: AudioProcessingState.loading,
      ProcessingState.buffering: AudioProcessingState.buffering,
      ProcessingState.ready: AudioProcessingState.ready,
      ProcessingState.completed: AudioProcessingState.completed,
    };

    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [1],
      processingState: stateMap[_player.processingState] ?? AudioProcessingState.idle,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFFF8F9FA),
      ),
      home: const SpeechTestScreen(),
    );
  }
}

class SpeechTestScreen extends StatelessWidget {
  const SpeechTestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SpeechTestView();
  }
}

class SpeechTestView extends StatefulWidget {
  const SpeechTestView({super.key});

  @override
  State<SpeechTestView> createState() => _SpeechTestViewState();
}

class _SpeechTestViewState extends State<SpeechTestView> {
  sherpa.OfflineTts? _tts;
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();
  final PdfViewerController _pdfViewerController = PdfViewerController();

  sf.PdfDocument? _loadedDocument;
  HighlightAnnotation? _currentHighlight;
  String? _pdfFilePath;

  bool _isReady = false;
  bool _isBusy = false;
  bool _isParsingPdf = false;
  String _currentLang = 'cs';
  String _appSupportDir = "";

  List<String> _textChunks = [];
  List<int> _chunkPageMapping = [];
  int _currentChunkIndex = 0;
  int _currentWordIndex = 0;
  int? _selectedChunkIndex;
  bool _isPdfLoaded = false;
  bool _showOriginalLayout = false;
  bool _isUserScrolling = false;
  bool _isProgrammaticScrolling = false;

  final String _cleanupMode = 'chytreParsovani';

  final Map<String, String> _testTexts = {
    'cs': 'Ahoj! Já jsem Jirka a tohle je test přirozené češtiny přímo v tvém mobilu.',
    'en': 'Hello! This is a test of the Kokoro voice model.',
  };

  @override
  void initState() {
    super.initState();
    _initEngine();

    _itemPositionsListener.itemPositions.addListener(() {
      if (_textChunks.isEmpty || _isParsingPdf || _isProgrammaticScrolling || _showOriginalLayout) return;
      final positions = _itemPositionsListener.itemPositions.value;
      if (positions.isEmpty) return;
      bool currentVisible = positions.any((position) => position.index == _currentChunkIndex);
      if (!currentVisible && !_isUserScrolling) {
        setState(() { _isUserScrolling = true; });
      }
    });

    if (_isMobile) {
      _audioHandler.playbackState.listen((state) {
        if (state.processingState == AudioProcessingState.completed && _isPdfLoaded && _isBusy) {
          _handleTrackComplete();
        }
      });
      _audioHandler.player.positionStream.listen((position) {
        _updateWordHighlight(position);
      });
    } else {
      _windowsPlayer.processingStateStream.listen((state) {
        if (state == ProcessingState.completed && _isPdfLoaded && _isBusy) {
          _handleTrackComplete();
        }
      });
      _windowsPlayer.positionStream.listen((position) {
        _updateWordHighlight(position);
      });
    }
  }

  void _updateWordHighlight(Duration position) {
    if (!_isBusy || _textChunks.isEmpty || _currentChunkIndex >= _textChunks.length) return;

    final currentText = _textChunks[_currentChunkIndex];
    List<String> words = currentText.split(' ');
    if (words.isEmpty) return;

    final totalDuration = _isMobile ? _audioHandler.player.duration : _windowsPlayer.duration;
    if (totalDuration == null || totalDuration.inMilliseconds == 0) return;

    double progress = position.inMilliseconds / totalDuration.inMilliseconds;
    int calculatedWordIndex = (progress * words.length).floor();

    if (calculatedWordIndex != _currentWordIndex && calculatedWordIndex < words.length) {
      setState(() {
        _currentWordIndex = calculatedWordIndex;
      });
    }
  }

  void _handleTrackComplete() {
    _currentWordIndex = 0;
    _currentChunkIndex++;
    _executeChunkReading();
  }

  @override
  void dispose() {
    _pdfViewerController.dispose();
    _loadedDocument?.dispose();
    _tts?.free();
    super.dispose();
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
      return file.path;
    } catch (e) {
      return "";
    }
  }

  Future<void> _initEngine() async {
    if (_isBusy) return;
    setState(() { _isReady = false; });

    try {
      final dir = await getApplicationSupportDirectory();
      _appSupportDir = dir.path;

      final kokoroBaseAsset = 'assets/models/kokoro-en-v0_19';
      final jirkaBaseAsset = 'assets/models/vits-piper-cs_CZ-jirka-medium';
      const espeakDirName = 'shared-espeak-ng-data';
      final esAssetDir = '$kokoroBaseAsset/espeak-ng-data';

      await _prepareFile('$esAssetDir/phontab', targetPath: '$espeakDirName/phontab');
      await _prepareFile('$esAssetDir/phondata', targetPath: '$espeakDirName/phondata');
      await _prepareFile('$esAssetDir/phondata-manifest', targetPath: '$espeakDirName/phondata-manifest');
      await _prepareFile('$esAssetDir/phonindex', targetPath: '$espeakDirName/phonindex');
      await _prepareFile('$esAssetDir/intonations', targetPath: '$espeakDirName/intonations');
      await _prepareFile('$esAssetDir/en_dict', targetPath: '$espeakDirName/en_dict');
      await _prepareFile('$jirkaBaseAsset/espeak-ng-data/cs_dict', targetPath: '$espeakDirName/cs_dict');
      await _prepareFile('$esAssetDir/lang/gmw/en', targetPath: '$espeakDirName/lang/gmw/en');
      await _prepareFile('$esAssetDir/lang/gmw/en-US', targetPath: '$espeakDirName/lang/gmw/en-US');

      sherpa.OfflineTtsModelConfig modelConfig;

      if (_currentLang == 'cs') {
        final modelPath = await _prepareFile('$jirkaBaseAsset/cs_CZ-jirka-medium.onnx');
        final tokensPath = await _prepareFile('$jirkaBaseAsset/tokens.txt');
        modelConfig = sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(model: modelPath, tokens: tokensPath, dataDir: '$_appSupportDir/$espeakDirName'),
          numThreads: 4,
          debug: false,
        );
      } else {
        final modelPath = await _prepareFile('$kokoroBaseAsset/model.onnx');
        final voicesPath = await _prepareFile('$kokoroBaseAsset/voices.bin');
        final tokensPath = await _prepareFile('$kokoroBaseAsset/tokens.txt');
        modelConfig = sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(model: modelPath, voices: voicesPath, tokens: tokensPath, dataDir: '$_appSupportDir/$espeakDirName'),
          numThreads: 4,
          debug: false,
        );
      }

      _tts?.free();
      _tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: modelConfig, maxNumSenetences: 1));
      if (mounted) setState(() => _isReady = true);
    } catch (e) {
      if (mounted) setState(() { _isReady = false; });
    }
  }

  void _parsePdfByPages(sf.PdfDocument document) {
    _textChunks.clear();
    _chunkPageMapping.clear();
    final sf.PdfTextExtractor extractor = sf.PdfTextExtractor(document);

    for (int pageIdx = 0; pageIdx < document.pages.count; pageIdx++) {
      String pageText = extractor.extractText(startPageIndex: pageIdx, endPageIndex: pageIdx);
      List<String> rawLines = pageText.split('\n');
      List<String> cleanedWords = [];

      for (var line in rawLines) {
        String word = line.trim();
        if (word.isEmpty) continue;
        if (_cleanupMode == 'chytreParsovani') {
          if (word.contains(RegExp(r'https?://\S+|www\.\S+'))) continue;
          if (RegExp(r'^\d+$').hasMatch(word) || RegExp(r'^\[\d+\]$').hasMatch(word) || RegExp(r'^(page|strana)\s*\d+', caseSensitive: false).hasMatch(word)) continue;
        }
        cleanedWords.add(word);
      }

      StringBuffer currentSentence = StringBuffer();
      for (var word in cleanedWords) {
        if (currentSentence.isEmpty) {
          currentSentence.write(word);
        } else {
          currentSentence.write(" $word");
        }

        bool isEndOfSentence = word.endsWith('.') || word.endsWith('?') || word.endsWith('!');
        if (isEndOfSentence || currentSentence.length > 180) {
          _textChunks.add(currentSentence.toString().trim());
          _chunkPageMapping.add(pageIdx + 1);
          currentSentence.clear();
        }
      }
      if (currentSentence.isNotEmpty) {
        _textChunks.add(currentSentence.toString().trim());
        _chunkPageMapping.add(pageIdx + 1);
      }
    }
  }

  Future<void> _pickAndParsePdf() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
      if (result == null || result.files.single.path == null) return;

      setState(() { _isParsingPdf = true; _isBusy = true; _isPdfLoaded = false; });
      final filePath = result.files.single.path!;
      final file = File(filePath);
      final Uint8List bytes = await file.readAsBytes();

      final sf.PdfDocument document = await compute((Uint8List data) {
        return sf.PdfDocument(inputBytes: data);
      }, bytes);

      _parsePdfByPages(document);
      document.dispose();

      setState(() {
        _pdfFilePath = filePath;
        if (_textChunks.isEmpty) {
          _textChunks = ["PDF neobsahuje text."];
          _chunkPageMapping = [1];
        }
        _currentChunkIndex = 0;
        _currentWordIndex = 0;
        _selectedChunkIndex = null;
        _isPdfLoaded = true;
        _isParsingPdf = false;
        _isBusy = false;
      });
    } catch (e) {
      setState(() { _isParsingPdf = false; _isBusy = false; });
    }
  }

  void _scrollToCurrentChunk(int index) {
    if (_itemScrollController.isAttached && _textChunks.isNotEmpty && !_isUserScrolling && !_showOriginalLayout) {
      _isProgrammaticScrolling = true;
      _itemScrollController.scrollTo(
        index: index,
        alignment: 0.1,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOutCubic,
      ).then((_) {
        _isProgrammaticScrolling = false;
      });
    }

    if (_chunkPageMapping.isNotEmpty && index < _chunkPageMapping.length && _showOriginalLayout && _loadedDocument != null) {
      int targetPage = _chunkPageMapping[index];
      _pdfViewerController.jumpToPage(targetPage);

      if (_currentHighlight != null) {
        _pdfViewerController.removeAnnotation(_currentHighlight!);
        _currentHighlight = null;
      }

      final sf.PdfTextExtractor textExtractor = sf.PdfTextExtractor(_loadedDocument!);
      final List<sf.TextLine> textLines = textExtractor.extractTextLines(startPageIndex: targetPage - 1);
      final String targetChunkText = _textChunks[index].trim();
      final List<sf.TextLine> toHighlight = [];

      for (final sf.TextLine textLine in textLines) {
        if (textLine.text.contains(targetChunkText) || targetChunkText.contains(textLine.text)) {
          toHighlight.add(textLine);
        }
      }

      if (toHighlight.isNotEmpty) {
        _currentHighlight = HighlightAnnotation(
          textBoundsCollection: toHighlight
              .map((line) => PdfTextLine(line.bounds, line.text, targetPage))
              .toList(),
        );
        _currentHighlight!.color = Colors.yellow.withOpacity(0.4);
        _pdfViewerController.addAnnotation(_currentHighlight!);
      }
    }
  }

  void _recenterToCurrentChunk() {
    setState(() { _isUserScrolling = false; });
    _scrollToCurrentChunk(_currentChunkIndex);
  }

  void _startPdfReading() {
    if (_textChunks.isEmpty || _tts == null) return;
    setState(() { _isBusy = true; });
    _executeChunkReading();
  }

  void _stopPdfReading() async {
    if (_isMobile) {
      await _audioHandler.stop();
    } else {
      await _windowsPlayer.stop();
    }
    setState(() { _isBusy = false; });
  }

  void _jumpToSelectedAndPlay() async {
    if (_selectedChunkIndex == null || _selectedChunkIndex! >= _textChunks.length) return;
    setState(() { _isBusy = true; _isUserScrolling = false; });

    if (_isMobile) {
      await _audioHandler.stop();
    } else {
      await _windowsPlayer.stop();
    }

    setState(() {
      _currentChunkIndex = _selectedChunkIndex!;
      _currentWordIndex = 0;
      _selectedChunkIndex = null;
    });
    _executeChunkReading();
  }

  void _executeChunkReading() async {
    if (_currentChunkIndex >= _textChunks.length || !_isBusy) {
      setState(() { _isBusy = false; });
      return;
    }
    try {
      final text = _textChunks[_currentChunkIndex];
      final sid = (_currentLang == 'en') ? 9 : 0;

      _scrollToCurrentChunk(_currentChunkIndex);

      await Future.delayed(const Duration(milliseconds: 30));

      final audio = _tts!.generate(text: text, sid: sid);
      final tempDir = await getTemporaryDirectory();
      final wavPath = '${tempDir.path}/chunk_$_currentChunkIndex.wav';
      final success = sherpa.writeWave(filename: wavPath, samples: audio.samples, sampleRate: audio.sampleRate);

      if (success) {
        if (_isMobile) {
          await _audioHandler.playFile(wavPath, text);
        } else {
          await _windowsPlayer.setFilePath(wavPath);
          _windowsPlayer.play();
        }
      } else {
        _skipToNextFailedChunk();
      }
    } catch (e) {
      _skipToNextFailedChunk();
    }
  }

  void _skipToNextFailedChunk() {
    _currentWordIndex = 0;
    _currentChunkIndex++;
    _executeChunkReading();
  }

  void _speakTest() async {
    if (_tts == null || _isBusy) return;
    setState(() { _isBusy = true; });
    try {
      final text = _testTexts[_currentLang]!;
      final audio = _tts!.generate(text: text, sid: (_currentLang == 'en') ? 9 : 0);
      final tempDir = await getTemporaryDirectory();
      final wavPath = '${tempDir.path}/output.wav';
      if (sherpa.writeWave(filename: wavPath, samples: audio.samples, sampleRate: audio.sampleRate)) {
        if (_isMobile) {
          await _audioHandler.playFile(wavPath, text);
        } else {
          await _windowsPlayer.setFilePath(wavPath);
          _windowsPlayer.play();
        }
      } else {
        setState(() => _isBusy = false);
      }
    } catch (e) {
      setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    bool canInteract = _isReady && !_isBusy;
    double progress = _textChunks.isEmpty ? 0.0 : _currentChunkIndex / _textChunks.length;
    bool showJumpButton = _selectedChunkIndex != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('free_voice_reader', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 20)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      segments: const [
                        ButtonSegment(value: 'cs', label: Text('Čeština (Jirka)', style: TextStyle(fontWeight: FontWeight.w500))),
                        ButtonSegment(value: 'en', label: Text('English (Kokoro)', style: TextStyle(fontWeight: FontWeight.w500))),
                      ],
                      selected: {_currentLang},
                      onSelectionChanged: canInteract ? (Set<String> newSelection) {
                        setState(() => _currentLang = newSelection.first);
                        _initEngine();
                      } : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: (_isReady && !_isParsingPdf) ? _pickAndParsePdf : null,
                icon: const Icon(Icons.picture_as_pdf_rounded),
                label: const Text('IMPORTOVAT PDF DOKUMENT', style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 54),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 16),
              if (_isPdfLoaded && !_isParsingPdf)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12, left: 4, right: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Blok: ${_currentChunkIndex + 1} / ${_textChunks.length}',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade800, fontWeight: FontWeight.bold),
                        ),
                      ),
                      Text(
                        _showOriginalLayout ? 'Zobrazení: Původní PDF' : 'Zobrazení: Čistý text',
                        style: TextStyle(fontSize: 12, color: Colors.blue.shade900, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.04),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: _isParsingPdf
                            ? const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 20),
                              Text('Asynchrononní čištění a příprava textu...', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500)),
                            ],
                          ),
                        )
                            : (_isPdfLoaded
                            ? IndexedStack(
                          index: _showOriginalLayout ? 1 : 0,
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: ScrollablePositionedList.builder(
                                itemScrollController: _itemScrollController,
                                itemPositionsListener: _itemPositionsListener,
                                itemCount: _textChunks.length,
                                itemBuilder: (context, index) {
                                  bool isCurrentSentence = _isBusy && index == _currentChunkIndex;
                                  bool isSelectedSentence = index == _selectedChunkIndex;

                                  return InkWell(
                                    onTap: () {
                                      setState(() { _selectedChunkIndex = index; });
                                    },
                                    borderRadius: BorderRadius.circular(8),
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 150),
                                      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: isCurrentSentence
                                            ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3)
                                            : (isSelectedSentence ? Colors.orange.shade50 : Colors.transparent),
                                        borderRadius: BorderRadius.circular(8),
                                        border: isSelectedSentence ? Border.all(color: Colors.orange.shade400, width: 1.5) : null,
                                      ),
                                      child: isCurrentSentence
                                          ? RichText(
                                        text: TextSpan(
                                          style: const TextStyle(fontSize: 17, height: 1.6, color: Colors.black87),
                                          children: _buildHighlightedWords(_textChunks[index], context),
                                        ),
                                      )
                                          : Text(
                                        _textChunks[index],
                                        style: TextStyle(
                                          fontSize: 16,
                                          height: 1.6,
                                          color: index < _currentChunkIndex ? Colors.grey.shade400 : Colors.black87,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            if (_pdfFilePath != null)
                              SfPdfViewer.file(
                                File(_pdfFilePath!),
                                controller: _pdfViewerController,
                                canShowScrollHead: false,
                                canShowTextSelectionMenu: false,
                                onDocumentLoaded: (PdfDocumentLoadedDetails details) {
                                  _loadedDocument = details.document;
                                  _scrollToCurrentChunk(_currentChunkIndex);
                                },
                              )
                            else
                              const SizedBox.shrink(),
                          ],
                        )
                            : Center(child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Text(_testTexts[_currentLang]!, style: const TextStyle(fontSize: 16, color: Colors.grey, height: 1.5), textAlign: TextAlign.center),
                        ))),
                      ),
                    ),
                    if (_isPdfLoaded && !_isParsingPdf)
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Card(
                          elevation: 2,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                          child: IconButton(
                            icon: Icon(
                              _showOriginalLayout ? Icons.text_snippet_outlined : Icons.picture_as_pdf_outlined,
                              color: Theme.of(context).colorScheme.primary,
                              size: 22,
                            ),
                            onPressed: () {
                              setState(() {
                                _showOriginalLayout = !_showOriginalLayout;
                              });
                              _scrollToCurrentChunk(_currentChunkIndex);
                            },
                          ),
                        ),
                      ),
                    if (_isPdfLoaded && _isUserScrolling && !_showOriginalLayout)
                      Positioned(
                        bottom: 16,
                        right: 16,
                        child: FloatingActionButton.small(
                          onPressed: _recenterToCurrentChunk,
                          child: const Icon(Icons.center_focus_strong),
                        ),
                      ),
                  ],
                ),
              ),
              if (_isPdfLoaded && !_isParsingPdf) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: Colors.grey.shade200,
                  color: Theme.of(context).colorScheme.primary,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
              ],
              const SizedBox(height: 16),
              if (!_isPdfLoaded && !_isParsingPdf)
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: OutlinedButton.icon(
                    onPressed: canInteract ? _speakTest : null,
                    icon: const Icon(Icons.volume_up_rounded),
                    label: const Text('PREHRAT TESTOVACÍ FRÁZI'),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              if (_isPdfLoaded && !_isParsingPdf)
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 56,
                        child: showJumpButton
                            ? FilledButton.icon(
                          onPressed: _jumpToSelectedAndPlay,
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.orange.shade700,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: const Icon(Icons.play_circle_filled, size: 24),
                          label: const Text('SPUSTIT OD VYBRANÉHO MÍSTA', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        )
                            : FilledButton.icon(
                          onPressed: _isReady ? (_isBusy ? _stopPdfReading : _startPdfReading) : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: _isBusy ? Colors.red.shade600 : Theme.of(context).colorScheme.primary,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: Icon(_isBusy ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 26),
                          label: Text(_isBusy ? 'ZASTAVIT ČTENÍ' : 'SPUSTIT PŘEHRÁVÁNÍ', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        ),
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

  List<TextSpan> _buildHighlightedWords(String text, BuildContext context) {
    List<String> words = text.split(' ');
    List<TextSpan> spans = [];

    for (int i = 0; i < words.length; i++) {
      bool isCurrentWord = i == _currentWordIndex;
      spans.add(
        TextSpan(
          text: words[i] + (i == words.length - 1 ? "" : " "),
          style: TextStyle(
            fontWeight: isCurrentWord ? FontWeight.bold : FontWeight.normal,
            backgroundColor: isCurrentWord ? Theme.of(context).colorScheme.primary.withOpacity(0.2) : Colors.transparent,
            color: isCurrentWord ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      );
    }
    return spans;
  }
}