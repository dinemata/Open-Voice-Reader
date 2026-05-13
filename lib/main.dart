import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:audioplayers/audioplayers.dart';

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
      theme: ThemeData(
        useMaterial3: true, 
        colorSchemeSeed: Colors.blue,
      ),
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
  
  bool _isReady = false;
  bool _isBusy = false; 
  String? _error;
  String _currentLang = 'cs'; 
  String _appSupportDir = "";

  final Map<String, String> _testTexts = {
    'cs': 'Ahoj! Já jsem Jirka a tohle je test přirozené češtiny přímo v tvém mobilu. Doufám, že mě teď slyšíš!',
    'en': 'Hello! This is a test of the Kokoro voice model. You should be able to hear me clearly now.',
  };

  @override
  void initState() {
    super.initState();
    _initEngine();
    
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isBusy = false);
    });
  }

  @override
  void dispose() {
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
      
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }

      final buffer = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
      await file.writeAsBytes(buffer, flush: true);
      return file.path;
    } catch (e) {
      debugPrint("Asset $assetPath not found.");
      return "";
    }
  }

  Future<void> _initEngine() async {
    if (_isBusy) return;
    
    setState(() {
      _isReady = false;
      _error = null;
    });

    try {
      final dir = await getApplicationSupportDirectory();
      _appSupportDir = dir.path;
      
      sherpa.OfflineTtsModelConfig modelConfig;

      if (_currentLang == 'cs') {
        final base = 'assets/models/vits-piper-cs_CZ-jirka-medium';
        final modelPath = await _prepareFile('$base/cs_CZ-jirka-medium.onnx');
        final tokensPath = await _prepareFile('$base/tokens.txt');
        
        await _prepareFile('$base/espeak-ng-data/phontab');
        await _prepareFile('$base/espeak-ng-data/phondata');
        await _prepareFile('$base/espeak-ng-data/phonindex');
        await _prepareFile('$base/espeak-ng-data/intonations');
        await _prepareFile('$base/espeak-ng-data/cs_dict');
        
        final voiceFile = File('$_appSupportDir/$base/espeak-ng-data/voices/cs');
        if (!await voiceFile.exists()) {
          await voiceFile.parent.create(recursive: true);
          await voiceFile.writeAsString("name cs\nlanguage cs\n");
        }

        modelConfig = sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: modelPath, 
            tokens: tokensPath, 
            dataDir: '$_appSupportDir/$base/espeak-ng-data'
          ),
          numThreads: 4,
          debug: true,
        );
      } else {
        final base = 'assets/models/kokoro-en-v0_19';
        final modelPath = await _prepareFile('$base/model.onnx');
        final voicesPath = await _prepareFile('$base/voices.bin');
        final tokensPath = await _prepareFile('$base/tokens.txt');
        
        final espeakDir = '$base/espeak-ng-data';
        await _prepareFile('$espeakDir/phontab');
        await _prepareFile('$espeakDir/phondata');
        await _prepareFile('$espeakDir/phondata-manifest');
        await _prepareFile('$espeakDir/phonindex');
        await _prepareFile('$espeakDir/intonations');
        await _prepareFile('$espeakDir/en_dict');
        await _prepareFile('$espeakDir/lang/gmw/en');
        await _prepareFile('$espeakDir/lang/gmw/en-US');

        final voicesDir = Directory('$_appSupportDir/$espeakDir/voices');
        if (!await voicesDir.exists()) await voicesDir.create(recursive: true);
        await File('${voicesDir.path}/en-us').writeAsString("name en-us\nlanguage en\n");
        await File('${voicesDir.path}/en').writeAsString("name en\nlanguage en\n");

        modelConfig = sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: modelPath, voices: voicesPath, tokens: tokensPath,
            dataDir: '$_appSupportDir/$espeakDir',
          ),
          numThreads: 4,
          debug: true,
        );
      }

      _tts?.free();
      _tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: modelConfig, maxNumSenetences: 1));
      
      if (mounted) setState(() => _isReady = true);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _isReady = false; });
    }
  }

  void _speak() async {
    if (_tts == null || _isBusy) return;

    setState(() => _isBusy = true);

    try {
      final text = _testTexts[_currentLang]!;
      final sid = (_currentLang == 'en') ? 9 : 0;
      
      // Let the UI render the loading state first
      await Future.delayed(const Duration(milliseconds: 100));

      final audio = _tts!.generate(text: text, sid: sid);
      
      final tempDir = await getTemporaryDirectory();
      final wavPath = '${tempDir.path}/output.wav';
      
      final success = sherpa.writeWave(
        filename: wavPath,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );

      if (success) {
        await _audioPlayer.play(DeviceFileSource(wavPath));
      } else {
        if (mounted) setState(() => _isBusy = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isBusy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    bool canPlay = _isReady && !_isBusy;

    return Scaffold(
      appBar: AppBar(title: const Text('AI Voice Test 2026')),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'cs', label: Text('CZ (Jirka)')),
                  ButtonSegment(value: 'en', label: Text('EN (Kokoro)')),
                ],
                selected: {_currentLang},
                onSelectionChanged: canPlay ? (Set<String> newSelection) {
                  setState(() => _currentLang = newSelection.first);
                  _initEngine();
                } : null,
              ),
              const SizedBox(height: 30),
              if (_error != null)
                Text('Chyba: $_error', style: const TextStyle(color: Colors.red, fontSize: 11), textAlign: TextAlign.center),
              
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Text(
                  _testTexts[_currentLang]!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, height: 1.5),
                ),
              ),
              const SizedBox(height: 50),
              
              // Big, constant size button
              SizedBox(
                width: double.infinity,
                height: 80,
                child: ElevatedButton.icon(
                  onPressed: canPlay ? _speak : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: canPlay ? Theme.of(context).colorScheme.primaryContainer : Colors.grey.shade100,
                    foregroundColor: canPlay ? Theme.of(context).colorScheme.onPrimaryContainer : Colors.grey.shade500,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    elevation: 0,
                  ),
                  icon: _isBusy 
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_circle_filled, size: 32),
                  label: Text(
                    _isBusy 
                        ? 'ZPRACOVÁVÁM...' 
                        : (_isReady ? 'PŘEČÍST TEXT' : 'NAČÍTÁM MODEL...'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
