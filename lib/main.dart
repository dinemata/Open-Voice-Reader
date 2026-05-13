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
  bool _isBusy = false; // Sleduje generování i přehrávání
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
    
    // Uvolnění tlačítka po dohrání audia
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _tts?.free();
    super.dispose();
  }

  // Funkce pro přípravu souboru - vrací path nebo prázdný string při chybě
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
      debugPrint("Asset $assetPath chybí, přeskakuji...");
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
      
      // CESTY K SLOŽKÁM
      final kokoroBaseAsset = 'assets/models/kokoro-en-v0_19';
      final jirkaBaseAsset = 'assets/models/vits-piper-cs_CZ-jirka-medium';
      
      // 1. PŘÍPRAVA SDÍLENÉ SLOŽKY ESPEAK-NG (Sjednocení dat)
      const espeakDirName = 'shared-espeak-ng-data';
      final esAssetDir = '$kokoroBaseAsset/espeak-ng-data';
      
      // Kopírujeme CORE soubory
      await _prepareFile('$esAssetDir/phontab', targetPath: '$espeakDirName/phontab');
      await _prepareFile('$esAssetDir/phondata', targetPath: '$espeakDirName/phondata');
      await _prepareFile('$esAssetDir/phondata-manifest', targetPath: '$espeakDirName/phondata-manifest');
      await _prepareFile('$esAssetDir/phonindex', targetPath: '$espeakDirName/phonindex');
      await _prepareFile('$esAssetDir/intonations', targetPath: '$espeakDirName/intonations');
      
      // Slovníky
      await _prepareFile('$esAssetDir/en_dict', targetPath: '$espeakDirName/en_dict');
      await _prepareFile('$jirkaBaseAsset/espeak-ng-data/cs_dict', targetPath: '$espeakDirName/cs_dict');
      
      // Jazyková pravidla
      await _prepareFile('$esAssetDir/lang/gmw/en', targetPath: '$espeakDirName/lang/gmw/en');
      await _prepareFile('$esAssetDir/lang/gmw/en-US', targetPath: '$espeakDirName/lang/gmw/en-US');

      // VYTVOŘENÍ HLASŮ
      final voicesDir = Directory('$_appSupportDir/$espeakDirName/voices');
      if (!await voicesDir.exists()) await voicesDir.create(recursive: true);
      
      await File('${voicesDir.path}/cs').writeAsString("name cs\nlanguage cs\n");
      await File('${voicesDir.path}/en-us').writeAsString("name en-us\nlanguage en-us\n");

      sherpa.OfflineTtsModelConfig modelConfig;

      if (_currentLang == 'cs') {
        final modelPath = await _prepareFile('$jirkaBaseAsset/cs_CZ-jirka-medium.onnx');
        final tokensPath = await _prepareFile('$jirkaBaseAsset/tokens.txt');

        modelConfig = sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: modelPath, 
            tokens: tokensPath, 
            dataDir: '$_appSupportDir/$espeakDirName'
          ),
          numThreads: 4,
          debug: true,
        );
      } else {
        final modelPath = await _prepareFile('$kokoroBaseAsset/model.onnx');
        final voicesPath = await _prepareFile('$kokoroBaseAsset/voices.bin');
        final tokensPath = await _prepareFile('$kokoroBaseAsset/tokens.txt');

        modelConfig = sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: modelPath, 
            voices: voicesPath, 
            tokens: tokensPath,
            dataDir: '$_appSupportDir/$espeakDirName',
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
      
      // Malá pauza pro UI aby stihlo zobrazit stav "Zpracovávám"
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
        // Poznámka: _isBusy se nastaví na false v onPlayerComplete listeneru
      } else {
        setState(() => _isBusy = false);
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
    bool canInteract = _isReady && !_isBusy;

    return Scaffold(
      appBar: AppBar(title: const Text('AI Voice Test 2026'), centerTitle: true),
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
                onSelectionChanged: canInteract ? (Set<String> newSelection) {
                  setState(() => _currentLang = newSelection.first);
                  _initEngine();
                } : null,
              ),
              const SizedBox(height: 30),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Text('Chyba: $_error', style: const TextStyle(color: Colors.red, fontSize: 10), textAlign: TextAlign.center),
                ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Text(
                  _testTexts[_currentLang]!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, height: 1.6),
                ),
              ),
              const SizedBox(height: 60),
              
              // Tlačítko s konstantní velikostí a loadingem
              SizedBox(
                width: double.infinity,
                height: 85,
                child: ElevatedButton.icon(
                  onPressed: canInteract ? _speak : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: canInteract ? Theme.of(context).colorScheme.primaryContainer : Colors.grey.shade100,
                    foregroundColor: canInteract ? Theme.of(context).colorScheme.onPrimaryContainer : Colors.grey.shade500,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    elevation: 0,
                  ),
                  icon: _isBusy 
                      ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3))
                      : const Icon(Icons.play_circle_filled, size: 36),
                  label: Text(
                    _isBusy 
                        ? 'ZPRACOVÁVÁM...' 
                        : (_isReady ? 'PŘEČÍST TEXT' : 'NAČÍTÁM MODEL...'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1.5),
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
