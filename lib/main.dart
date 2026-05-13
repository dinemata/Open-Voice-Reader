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
  bool _isReady = false;
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

      await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      return file.path;
    } catch (e) {
      debugPrint("Asset $assetPath chybí, přeskakuji...");
      return "";
    }
  }

  Future<void> _initEngine() async {
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
        
        // ZAJIŠTĚNÍ DAT PRO KOKORO
        await _prepareFile('$base/espeak-ng-data/phontab');
        await _prepareFile('$base/espeak-ng-data/phondata');
        await _prepareFile('$base/espeak-ng-data/phondata-manifest');
        await _prepareFile('$base/espeak-ng-data/phonindex');
        await _prepareFile('$base/espeak-ng-data/intonations');
        await _prepareFile('$base/espeak-ng-data/en_dict');
        
        // JAZYKOVÁ DATA (Zajišťujeme i malá písmena pro Linux/Android)
        await _prepareFile('$base/espeak-ng-data/lang/gmw/en');
        final usPath = await _prepareFile('$base/espeak-ng-data/lang/gmw/en-US');
        if (usPath.isNotEmpty) {
           // Vytvoříme kopii s malými písmeny (pojistka)
           await File(usPath).copy('$_appSupportDir/$base/espeak-ng-data/lang/gmw/en-us');
        }

        // Vytvoření hlasu en-us (mapujeme na jazyk en-us)
        final voicesDir = Directory('$_appSupportDir/$base/espeak-ng-data/voices');
        if (!await voicesDir.exists()) await voicesDir.create(recursive: true);
        await File('${voicesDir.path}/en-us').writeAsString("name en-us\nlanguage en-us\n");
        await File('${voicesDir.path}/en').writeAsString("name en\nlanguage en\n");

        modelConfig = sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: modelPath, 
            voices: voicesPath, 
            tokens: tokensPath,
            dataDir: '$_appSupportDir/$base/espeak-ng-data',
          ),
          numThreads: 4,
          debug: true,
        );
      }

      _tts?.free();
      _tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: modelConfig, maxNumSenetences: 1));
      
      if (mounted) setState(() => _isReady = true);
    } catch (e) {
      debugPrint("CHYBA inicializace: $e");
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isReady = false;
        });
      }
    }
  }

  void _speak() async {
    if (_tts == null) return;
    try {
      final text = _testTexts[_currentLang]!;
      
      // Pro Kokoro SID 3 (Sarah), pro Piper SID 0
      final sid = (_currentLang == 'en') ? 3 : 0;
      
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
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Voice Test 2026')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'cs', label: Text('CZ (Jirka)')),
                ButtonSegment(value: 'en', label: Text('EN (Kokoro)')),
              ],
              selected: {_currentLang},
              onSelectionChanged: (Set<String> newSelection) {
                setState(() => _currentLang = newSelection.first);
                _initEngine();
              },
            ),
            const SizedBox(height: 20),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Chyba: $_error', style: const TextStyle(color: Colors.red, fontSize: 10), textAlign: TextAlign.center),
              ),
            const SizedBox(height: 40),
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text(_testTexts[_currentLang]!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _isReady ? _speak : null,
              icon: _isReady ? const Icon(Icons.volume_up) : const CircularProgressIndicator(strokeWidth: 2),
              label: Text(_isReady ? 'Přečíst text' : 'Načítám AI model...'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(20)),
            ),
          ],
        ),
      ),
    );
  }
}
