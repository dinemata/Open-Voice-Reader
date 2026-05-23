import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:pdfx/pdfx.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  sherpa.initBindings();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const SpeechTestScreen(),
    );
  }
}

class SpeechTestScreen extends StatefulWidget {
  const SpeechTestScreen({super.key});

  @override
  State<SpeechTestScreen> createState() => _SpeechTestScreenState();
}

class _SpeechTestScreenState extends State<SpeechTestScreen> {
  sherpa.OfflineTts? _tts;
  final AudioPlayer _audioPlayer = AudioPlayer();
  final ScrollController _scrollController = ScrollController();
  PdfControllerPinch? _pdfController;

  bool _isReady = false;
  bool _isBusy = false;
  bool _isParsingPdf = false;
  String? _error;
  String _currentLang = 'cs';
  String _appSupportDir = "";

  List<String> _textChunks = [];
  List<int> _chunkPageMapping = [];
  int _currentChunkIndex = 0;
  int _currentWordIndex = 0;
  int? _selectedChunkIndex;
  bool _isPdfLoaded = false;
  bool _showOriginalLayout = false;

  bool _filterPageNumbers = true;
  bool _filterFootnotes = true;
  bool _filterLinks = true;

  String _cleanupMode = 'chytreParsovani';
  String? _lastLoadedRawText;

  final Map<String, String> _testTexts = {
    'cs': 'Ahoj! Já jsem Jirka a tohle je test přirozené češtiny přímo v tvém mobilu.',
    'en': 'Hello! This is a test of the Kokoro voice model.',
  };

  @override
  void initState() {
    super.initState();
    _initEngine();

    _audioPlayer.onPlayerComplete.listen((_) {
      if (_isPdfLoaded && _audioPlayer.releaseMode != ReleaseMode.loop) {
        _currentWordIndex = 0;
        _currentChunkIndex++;
        _readNextChunk();
      } else {
        if (mounted) setState(() => _isBusy = false);
      }
    });

    _audioPlayer.onPositionChanged.listen((position) {
      if (_textChunks.isEmpty || _currentChunkIndex >= _textChunks.length) return;

      final currentText = _textChunks[_currentChunkIndex];
      List<String> words = currentText.split(' ');
      if (words.isEmpty) return;

      _audioPlayer.getDuration().then((totalDuration) {
        if (totalDuration == null || totalDuration.inMilliseconds == 0) return;

        double progress = position.inMilliseconds / totalDuration.inMilliseconds;
        int calculatedWordIndex = (progress * words.length).floor();

        if (calculatedWordIndex != _currentWordIndex && calculatedWordIndex < words.length) {
          setState(() {
            _currentWordIndex = calculatedWordIndex;
          });
        }
      });
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _pdfController?.dispose();
    _audioPlayer.dispose();
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
    setState(() { _isReady = false; _error = null; });

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

      final voicesDir = Directory('$_appSupportDir/$espeakDirName/voices');
      if (!await voicesDir.exists()) await voicesDir.create(recursive: true);
      await File('${voicesDir.path}/cs').writeAsString("name cs\nlanguage cs\n");
      await File('${voicesDir.path}/en-us').writeAsString("name en-us\nlanguage en-us\n");

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
      if (mounted) setState(() { _error = e.toString(); _isReady = false; });
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
          if (RegExp(r'^\d+$').hasMatch(word) ||
              RegExp(r'^\[\d+\]$').hasMatch(word) ||
              RegExp(r'^(page|strana)\s*\d+', caseSensitive: false).hasMatch(word)) {
            continue;
          }
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
        if (isEndOfSentence || currentSentence.length > 200) {
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

      final sf.PdfDocument document = sf.PdfDocument(inputBytes: bytes);
      _parsePdfByPages(document);
      document.dispose();

      _pdfController?.dispose();
      _pdfController = PdfControllerPinch(document: PdfDocument.openFile(filePath));

      setState(() {
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba PDF: $e')));
    }
  }

  void _scrollToCurrentChunk(int index) {
    if (_scrollController.hasClients && _textChunks.isNotEmpty) {
      final double itemHeight = 52.0;
      final double viewportHeight = _scrollController.position.viewportDimension;
      double targetPosition = (index * itemHeight) - (viewportHeight / 3);

      _scrollController.animateTo(
        targetPosition.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 280),
        curve: Curves.fastOutSlowIn,
      );
    }

    if (_pdfController != null && _chunkPageMapping.isNotEmpty && index < _chunkPageMapping.length) {
      int targetPage = _chunkPageMapping[index];
      _pdfController!.jumpToPage(targetPage);
    }
  }

  void _startPdfReading() {
    if (_textChunks.isEmpty || _tts == null) return;
    setState(() { _isBusy = true; });
    _readNextChunk();
  }

  void _stopPdfReading() {
    _audioPlayer.stop();
    setState(() { _isBusy = false; });
  }

  void _jumpToSelectedAndPlay() async {
    if (_selectedChunkIndex == null || _selectedChunkIndex! >= _textChunks.length) return;

    setState(() { _isBusy = true; });
    await _audioPlayer.stop();

    setState(() {
      _currentChunkIndex = _selectedChunkIndex!;
      _currentWordIndex = 0;
      _selectedChunkIndex = null;
    });

    _readNextChunkDirect();
  }

  void _readNextChunkDirect() async {
    if (_currentChunkIndex >= _textChunks.length) {
      setState(() { _isBusy = false; });
      return;
    }

    try {
      final text = _textChunks[_currentChunkIndex];
      final sid = (_currentLang == 'en') ? 9 : 0;

      _scrollToCurrentChunk(_currentChunkIndex);

      final audio = _tts!.generate(text: text, sid: sid);
      final tempDir = await getTemporaryDirectory();
      final wavPath = '${tempDir.path}/chunk_$_currentChunkIndex.wav';

      final success = sherpa.writeWave(filename: wavPath, samples: audio.samples, sampleRate: audio.sampleRate);

      if (success) {
        if (mounted) setState(() {});
        await _audioPlayer.play(DeviceFileSource(wavPath));
      }
    } catch (e) {
      setState(() { _isBusy = false; });
    }
  }

  void _readNextChunk() async {
    if (_currentChunkIndex >= _textChunks.length || !_isBusy) {
      setState(() { _isBusy = false; });
      return;
    }

    try {
      final text = _textChunks[_currentChunkIndex];
      final sid = (_currentLang == 'en') ? 9 : 0;

      _scrollToCurrentChunk(_currentChunkIndex);

      final audio = _tts!.generate(text: text, sid: sid);
      final tempDir = await getTemporaryDirectory();
      final wavPath = '${tempDir.path}/chunk_$_currentChunkIndex.wav';

      final success = sherpa.writeWave(filename: wavPath, samples: audio.samples, sampleRate: audio.sampleRate);

      if (success) {
        if (mounted) setState(() {});
        await _audioPlayer.play(DeviceFileSource(wavPath));
      } else {
        _currentWordIndex = 0;
        _currentChunkIndex++;
        _readNextChunk();
      }
    } catch (e) {
      _currentWordIndex = 0;
      _currentChunkIndex++;
      _readNextChunk();
    }
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
        await _audioPlayer.play(DeviceFileSource(wavPath));
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
      appBar: AppBar(title: const Text('free_voice_reader'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  flex: 5,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'cs', label: Center(child: Text('CZ'))),
                      ButtonSegment(value: 'en', label: Center(child: Text('EN'))),
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
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: (_isReady && !_isParsingPdf) ? _pickAndParsePdf : null,
              icon: const Icon(Icons.file_upload),
              label: const Text('IMPORTOVAT KNIHU / PDF'),
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 45)),
            ),
            const SizedBox(height: 12),

            if (_isPdfLoaded && !_isParsingPdf)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 4, right: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Pozice: $_currentChunkIndex / ${_textChunks.length} bloků',
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade700, fontWeight: FontWeight.w500),
                    ),
                    Text(
                      _showOriginalLayout ? 'Nativní PDF pohled' : 'Zjednodušené čtení',
                      style: TextStyle(fontSize: 13, color: Colors.blue.shade800, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),

            Expanded(
              child: Stack(
                children: [
                  Container(
                    width: double.infinity,
                    padding: _showOriginalLayout ? EdgeInsets.zero : const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: _isParsingPdf
                        ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Chroustám a čistím formátování PDF...', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    )
                        : (_isPdfLoaded
                    // FIX: IndexedStack zachovává stav PDF view v paměti a neničí ho
                        ? IndexedStack(
                      index: _showOriginalLayout ? 1 : 0,
                      children: [
                        ListView.builder(
                          controller: _scrollController,
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
                                duration: const Duration(milliseconds: 200),
                                margin: const EdgeInsets.symmetric(vertical: 2),
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: isCurrentSentence
                                      ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.4)
                                      : (isSelectedSentence ? Colors.orange.shade50 : Colors.transparent),
                                  borderRadius: BorderRadius.circular(8),
                                  border: isSelectedSentence ? Border.all(color: Colors.orange.shade300, width: 1) : null,
                                ),
                                child: isCurrentSentence
                                    ? RichText(
                                  text: TextSpan(
                                    style: TextStyle(fontSize: 16, height: 1.5, color: Theme.of(context).colorScheme.onPrimaryContainer),
                                    children: _buildHighlightedWords(_textChunks[index], context),
                                  ),
                                )
                                    : Text(
                                  _textChunks[index],
                                  style: TextStyle(
                                    fontSize: 15,
                                    height: 1.5,
                                    color: index < _currentChunkIndex ? Colors.grey.shade400 : Colors.black87,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        if (_pdfController != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: PdfViewPinch(
                              controller: _pdfController!,
                              scrollDirection: Axis.vertical,
                            ),
                          )
                        else
                          const SizedBox.shrink(),
                      ],
                    )
                        : Center(child: Text(_testTexts[_currentLang]!, style: const TextStyle(fontSize: 16), textAlign: TextAlign.center))),
                  ),
                  if (_isPdfLoaded && !_isParsingPdf)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: CircleAvatar(
                        backgroundColor: Colors.white.withOpacity(0.9),
                        radius: 20,
                        child: IconButton(
                          icon: Icon(
                            _showOriginalLayout ? Icons.text_fields : Icons.picture_as_pdf,
                            color: Colors.blue.shade700,
                            size: 20,
                          ),
                          onPressed: () {
                            setState(() { _showOriginalLayout = !_showOriginalLayout; });
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),

            if (_isPdfLoaded && !_isParsingPdf) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress, borderRadius: BorderRadius.circular(4)),
            ],
            const SizedBox(height: 12),

            if (!_isPdfLoaded && !_isParsingPdf)
              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton.icon(
                  onPressed: canInteract ? _speakTest : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('TESTOVACÍ FRÁZE'),
                ),
              ),
            if (_isPdfLoaded && !_isParsingPdf)
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 60,
                      child: showJumpButton
                          ? ElevatedButton.icon(
                        onPressed: _jumpToSelectedAndPlay,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange.shade600,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        icon: const Icon(Icons.forward, size: 26),
                        label: const Text('SPUSTIT OD VYBRANÉHO MÍSTA', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      )
                          : ElevatedButton.icon(
                        onPressed: _isReady ? (_isBusy ? _stopPdfReading : _startPdfReading) : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isBusy ? Colors.red.shade50 : Theme.of(context).colorScheme.primaryContainer,
                          foregroundColor: _isBusy ? Colors.red : Theme.of(context).colorScheme.onPrimaryContainer,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        icon: Icon(_isBusy ? Icons.stop : Icons.play_arrow, size: 26),
                        label: Text(_isBusy ? 'ZASTAVIT' : 'PŘEČÍST KNIHU', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                    ),
                  ),
                ],
              ),
          ],
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
            backgroundColor: isCurrentWord ? Theme.of(context).colorScheme.primary.withOpacity(0.3) : Colors.transparent,
            color: isCurrentWord ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      );
    }
    return spans;
  }
}