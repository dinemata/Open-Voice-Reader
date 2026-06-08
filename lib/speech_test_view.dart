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
import 'package:bitsdojo_window/bitsdojo_window.dart';
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
  final bool strikethrough;

  const HighlightPainter({
    required this.sentenceRects,
    this.wordRect,
    this.sentenceColor = const Color(0x331A73E8),
    this.wordColor = const Color(0x881A73E8),
    this.strikethrough = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sentencePaint = Paint()..color = sentenceColor;
    for (final r in sentenceRects) {
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)), sentencePaint);
      if (strikethrough) {
        final strikePaint = Paint()
          ..color = sentenceColor.withValues(alpha: (sentenceColor.a * 2.5).clamp(0.0, 1.0))
          ..strokeWidth = (r.height * 0.12).clamp(1.0, 2.5)
          ..strokeCap = StrokeCap.round;
        final midY = r.top + r.height * 0.52;
        canvas.drawLine(Offset(r.left + 1, midY), Offset(r.right - 1, midY), strikePaint);
      }
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
      old.sentenceRects != sentenceRects || old.wordRect != wordRect || old.strikethrough != strikethrough;
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
  final bool skipParentheses;
  final String searchQuery;
  final Set<int> searchMatchChunks;
  final int? activeSearchChunk;
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
    this.skipParentheses = false,
    this.searchQuery = '',
    this.searchMatchChunks = const {},
    this.activeSearchChunk,
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

  List<Rect> _parenWordRects(PdfChunkMetadata chunk) {
    if (!skipParentheses) return [];
    final text = chunk.text;
    final List<Rect> result = [];
    final parenRegex = RegExp(r'\(([^)]*)\)');
    final words = text.split(' ');
    for (final match in parenRegex.allMatches(text)) {
      int charPos = 0;
      for (int wi = 0; wi < words.length && wi < chunk.pdfWords.length; wi++) {
        final wordEnd = charPos + words[wi].length;
        if (charPos >= match.start && wordEnd <= match.end + 1) {
          result.add(_toScreen(chunk.pdfWords[wi].bounds));
        }
        charPos = wordEnd + 1;
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final displayHeight = displayWidth * page.heightPt / page.widthPt;

    final List<Rect> sentenceRects = [];
    final List<Rect> pendingRects = [];
    final List<Rect> parenRects = [];
    final List<Rect> searchRects = [];
    final List<Rect> activeSearchRects = [];
    Rect? wordRect;

    for (int ci = 0; ci < chunks.length; ci++) {
      final chunk = chunks[ci];
      if (chunk.pageNumber != page.pageNumber) continue;

      if (ci == currentChunkIndex) {
        for (int wi = 0; wi < chunk.pdfWords.length; wi++) {
          final screenRect = _toScreen(chunk.pdfWords[wi].bounds);
          sentenceRects.add(screenRect);
          if (isBusy && wi == currentWordIndex) wordRect = screenRect;
        }
        parenRects.addAll(_parenWordRects(chunk));
      }

      if (pendingChunkIndex != null && ci == pendingChunkIndex) {
        for (final w in chunk.pdfWords) pendingRects.add(_toScreen(w.bounds));
      }

      if (searchQuery.isNotEmpty && searchMatchChunks.contains(ci)) {
        final words = chunk.text.split(' ');
        for (int wi = 0; wi < words.length && wi < chunk.pdfWords.length; wi++) {
          if (words[wi].toLowerCase().contains(searchQuery)) {
            final r = _toScreen(chunk.pdfWords[wi].bounds);
            if (ci == activeSearchChunk) { activeSearchRects.add(r); } else { searchRects.add(r); }
          }
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
                  sentenceColor: Colors.orange.withValues(alpha: 0.35),
                  wordColor: Colors.orange.withValues(alpha: 0.6),
                ),
              ),
            CustomPaint(
              size: Size(displayWidth, displayHeight),
              painter: HighlightPainter(
                sentenceRects: sentenceRects,
                wordRect: wordRect,
                sentenceColor: primaryColor.withValues(alpha: 0.22),
                wordColor: primaryColor.withValues(alpha: 0.55),
              ),
            ),
            if (parenRects.isNotEmpty)
              CustomPaint(
                size: Size(displayWidth, displayHeight),
                painter: HighlightPainter(
                  sentenceRects: parenRects,
                  wordRect: null,
                  sentenceColor: Colors.purple.withValues(alpha: 0.28),
                  wordColor: Colors.purple.withValues(alpha: 0.28),
                  strikethrough: true,
                ),
              ),
            if (searchRects.isNotEmpty)
              CustomPaint(
                size: Size(displayWidth, displayHeight),
                painter: HighlightPainter(
                  sentenceRects: searchRects,
                  wordRect: null,
                  sentenceColor: const Color(0xFF00897B).withValues(alpha: 0.22),
                  wordColor: const Color(0xFF00897B).withValues(alpha: 0.22),
                ),
              ),
            if (activeSearchRects.isNotEmpty)
              CustomPaint(
                size: Size(displayWidth, displayHeight),
                painter: HighlightPainter(
                  sentenceRects: activeSearchRects,
                  wordRect: null,
                  sentenceColor: const Color(0xFF00897B).withValues(alpha: 0.42),
                  wordColor: const Color(0xFF00897B).withValues(alpha: 0.42),
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

/// Full-width vertical speed slider — looks like the Speechify style.
class _VerticalSpeedSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final double height;
  final Color inactiveColor;
  final void Function(double) onChanged;

  const _VerticalSpeedSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.height,
    this.inactiveColor = const Color(0xFFBBBBBB),
    required this.onChanged,
  });

  double _clampedFrac() => ((value - min) / (max - min)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) {
        final RenderBox box = context.findRenderObject() as RenderBox;
        final localY = box.globalToLocal(d.globalPosition).dy.clamp(0.0, height);
        final frac = 1.0 - (localY / height);
        onChanged(min + frac * (max - min));
      },
      onTapDown: (d) {
        final localY = d.localPosition.dy.clamp(0.0, height);
        final frac = 1.0 - (localY / height);
        onChanged(min + frac * (max - min));
      },
      child: SizedBox(
        width: 44,
        height: height,
        child: CustomPaint(
          painter: _VerticalSliderPainter(
            fraction: _clampedFrac(),
            activeColor: const Color(0xFF1A73E8),
            inactiveColor: inactiveColor,
          ),
        ),
      ),
    );
  }
}

class _VerticalSliderPainter extends CustomPainter {
  final double fraction;
  final Color activeColor;
  final Color inactiveColor;

  const _VerticalSliderPainter({
    required this.fraction,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final double radius = w / 2;
    final double frac = fraction;
    final double filledH = frac * h;

    final pillRect = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), Radius.circular(radius));

    canvas.drawRRect(pillRect, Paint()..color = inactiveColor);

    if (filledH > 0) {
      canvas.save();
      canvas.clipRRect(pillRect);
      canvas.drawRect(Rect.fromLTWH(0, h - filledH, w, filledH), Paint()..color = activeColor);
      canvas.restore();
    }

    const int totalSteps = 70;
    for (int i = 5; i < totalSteps; i += 5) {
      final bool isMajor = i % 20 == 0;
      final double tickFrac = i / totalSteps;
      final double y = h - tickFrac * h;
      final double inset = isMajor ? 3.0 : w * 0.22;
      final bool isActive = tickFrac <= frac;
      final Color tickColor = isActive
          ? Colors.white.withValues(alpha: isMajor ? 0.80 : 0.45)
          : const Color(0xFF888888).withValues(alpha: isMajor ? 0.55 : 0.30);
      canvas.drawLine(
        Offset(inset, y), Offset(w - inset, y),
        Paint()..color = tickColor..strokeWidth = isMajor ? 1.5 : 1.0..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_VerticalSliderPainter old) => old.fraction != fraction;
}

/// Standalone search bar widget — lives in its own State so parent setState()
/// never reconstructs the TextField and never unfocuses the user.
class _SearchBar extends StatefulWidget {
  final String initialQuery;
  final int matchCount;
  final int activeIndex;
  final bool isDark;
  final void Function(String query) onQueryChanged;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  const _SearchBar({
    super.key,
    required this.initialQuery,
    required this.matchCount,
    required this.activeIndex,
    this.isDark = false,
    required this.onQueryChanged,
    required this.onPrev,
    required this.onNext,
  });

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialQuery);
    _focus = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(_SearchBar old) {
    super.didUpdateWidget(old);
    if (widget.initialQuery.isEmpty && _ctrl.text.isNotEmpty) {
      _ctrl.clear();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 380), () {
      if (mounted) {
        widget.onQueryChanged(q.trim().toLowerCase());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool hasMatches = widget.matchCount > 0;
    final bg = widget.isDark ? const Color(0xFF2C2C2C) : Colors.white;
    return Material(
      elevation: 4,
      color: bg,
      borderRadius: BorderRadius.circular(10),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: hasMatches ? 130 : 210,
          child: TextField(
            controller: _ctrl,
            focusNode: _focus,
            style: TextStyle(color: widget.isDark ? Colors.white : Colors.black87),
            onTapOutside: (_) {},
            decoration: InputDecoration(
              hintText: 'Hledat…',
              hintStyle: TextStyle(color: widget.isDark ? Colors.white38 : const Color(0xFF9AA0A6)),
              prefixIcon: const Icon(Icons.search_rounded, size: 16, color: Color(0xFF00897B)),
              suffixIcon: _ctrl.text.isNotEmpty
                  ? IconButton(
                  icon: const Icon(Icons.clear_rounded, size: 14),
                  onPressed: () {
                    _ctrl.clear();
                    widget.onQueryChanged('');
                    _focus.requestFocus();
                  })
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 9),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              filled: true, fillColor: widget.isDark ? const Color(0xFF2C2C2C) : Colors.white,
            ),
            onChanged: _onChanged,
          ),
        ),
        if (hasMatches) ...[
          Text('${widget.activeIndex + 1}/${widget.matchCount}',
              style: TextStyle(fontSize: 10, color: widget.isDark ? Colors.white60 : const Color(0xFF5F6368))),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
            onPressed: () { widget.onPrev(); _focus.requestFocus(); },
            padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 28, minHeight: 36),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
            onPressed: () { widget.onNext(); _focus.requestFocus(); },
            padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 28, minHeight: 36),
          ),
        ],
      ]),
    );
  }
}

/// Reusable bottom audio player bar.
class AudioPlayerBar extends StatelessWidget {
  final bool isReady;
  final bool isBusy;
  final bool isCompleted;
  final bool showJumpButton;
  final double progress;
  final double volume;
  final double playbackSpeed;
  final bool speedOpen;
  final int currentChunkIndex;
  final int totalChunks;
  final int currentPdfPage;
  final int totalPdfPages;
  final bool isPdfLayout;
  final bool isTxtFile;
  final String etaRead;
  final String etaLeft;
  final VoidCallback? onPlay;
  final VoidCallback? onPause;
  final VoidCallback? onRestart;
  final VoidCallback? onJump;
  final VoidCallback? onSeekBack;
  final VoidCallback? onSeekForward;
  final VoidCallback? onMute;
  final ValueChanged<double> onVolumeChanged;
  final LayerLink speedLayerLink;
  final void Function(BuildContext) onSpeedTap;
  final bool isDark;

  const AudioPlayerBar({
    super.key,
    required this.isReady,
    required this.isBusy,
    required this.isCompleted,
    required this.showJumpButton,
    required this.progress,
    required this.volume,
    required this.playbackSpeed,
    required this.speedOpen,
    required this.currentChunkIndex,
    required this.totalChunks,
    required this.currentPdfPage,
    required this.totalPdfPages,
    required this.isPdfLayout,
    required this.isTxtFile,
    required this.etaRead,
    required this.etaLeft,
    this.onPlay,
    this.onPause,
    this.onRestart,
    this.onJump,
    this.onSeekBack,
    this.onSeekForward,
    this.onMute,
    required this.onVolumeChanged,
    required this.speedLayerLink,
    required this.onSpeedTap,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final isPhone = screenW < 480;
    final progressBg = isDark ? const Color(0xFF3A3A3A) : Colors.grey.shade200;

    return Column(mainAxisSize: MainAxisSize.min, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: progress,
          backgroundColor: progressBg,
          color: Theme.of(context).colorScheme.primary,
          minHeight: 4,
        ),
      ),
      const SizedBox(height: 2),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(etaRead, style: const TextStyle(fontSize: 9, color: Color(0xFF9AA0A6), fontWeight: FontWeight.w500)),
          if (!isCompleted)
            Text(etaLeft, style: const TextStyle(fontSize: 9, color: Color(0xFF9AA0A6), fontWeight: FontWeight.w500)),
        ]),
      ),
      const SizedBox(height: 1),
      SizedBox(
        height: 48,
        child: Stack(alignment: Alignment.center, children: [
          Positioned(
            left: 0,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.article_rounded, size: 12, color: Colors.grey),
              const SizedBox(width: 3),
              Text(
                isCompleted ? 'Hotovo'
                    : (isPdfLayout && !isTxtFile
                    ? 'Strana\u00A0$currentPdfPage/$totalPdfPages'
                    : 'Blok\u00A0${currentChunkIndex + 1}/$totalChunks'),
                style: const TextStyle(fontSize: 10, color: Color(0xFF5F6368), fontWeight: FontWeight.w600),
              ),
            ]),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
              icon: const Icon(Icons.replay_10_rounded, size: 26),
              onPressed: isBusy ? onSeekBack : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 48, height: 48,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: isReady
                      ? (showJumpButton ? onJump
                      : (isCompleted ? onRestart
                      : (isBusy ? onPause : onPlay)))
                      : null,
                  child: showJumpButton
                      ? Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(color: Colors.orange.shade700, shape: BoxShape.circle),
                    child: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 28),
                  )
                      : (isCompleted
                      ? Icon(Icons.replay_rounded, color: isDark ? Colors.white : const Color(0xFF1A73E8), size: 44)
                      : Stack(alignment: Alignment.center, children: [
                    Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: isBusy ? Colors.red.shade600 : const Color(0xFF1A73E8),
                        shape: BoxShape.circle,
                      ),
                    ),
                    Icon(
                      isBusy ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                  ])),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(Icons.forward_10_rounded, size: 26),
              onPressed: isBusy ? onSeekForward : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ]),
          Positioned(
            right: 0,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Builder(builder: (btnCtx) => CompositedTransformTarget(
                link: speedLayerLink,
                child: GestureDetector(
                  onTap: () => onSpeedTap(btnCtx),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      color: speedOpen
                          ? const Color(0xFF1A73E8)
                          : (isDark ? const Color(0xFF2C2C2C) : const Color(0xFFF1F3F4)),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.speed_rounded, size: 15,
                          color: speedOpen ? Colors.white : (isDark ? Colors.white70 : const Color(0xFF5F6368))),
                      const SizedBox(width: 3),
                      Text(
                        playbackSpeed % 1 == 0 ? '${playbackSpeed.toInt()}x' : '${playbackSpeed}x',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                            color: speedOpen ? Colors.white : (isDark ? Colors.white : const Color(0xFF1F1F1F))),
                      ),
                    ]),
                  ),
                ),
              )),
              if (!isPhone && !Platform.isAndroid && !Platform.isIOS) ...[
                const SizedBox(width: 8),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: Icon(
                    volume == 0.0 ? Icons.volume_off_rounded
                        : (volume < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
                    size: 18, color: isDark ? const Color(0xFF90CAF9) : const Color(0xFF5F6368),
                  ),
                  onPressed: onMute,
                ),
                SizedBox(
                  width: 72,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                    ),
                    child: Slider(
                      value: volume, min: 0.0, max: 1.0,
                      activeColor: isDark ? const Color(0xFF90CAF9) : Theme.of(context).colorScheme.primary,
                      inactiveColor: isDark ? const Color(0xFF37474F) : Colors.grey.shade300,
                      onChanged: onVolumeChanged,
                    ),
                  ),
                ),
              ],
            ]),
          ),
        ]),
      ),
    ]);
  }
}

// ─── Window control buttons ───────────────────────────────────────────────────
class _WindowControls extends StatefulWidget {
  final bool isDark;
  const _WindowControls({required this.isDark});
  @override
  State<_WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<_WindowControls> {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    if (!Platform.isAndroid && !Platform.isIOS) {
      try { _isMaximized = appWindow.isMaximized; } catch (_) {}
    }
  }

  void _minimize() {
    if (Platform.isAndroid || Platform.isIOS) return;
    try { appWindow.minimize(); } catch (e) { debugPrint('[WIN] minimize: $e'); }
  }

  void _toggleMaximize() {
    if (Platform.isAndroid || Platform.isIOS) return;
    try {
      if (appWindow.isMaximized) {
        appWindow.restore();
        setState(() => _isMaximized = false);
      } else {
        appWindow.maximize();
        setState(() => _isMaximized = true);
      }
    } catch (e) { debugPrint('[WIN] maximize: $e'); }
  }

  void _close() {
    if (Platform.isAndroid || Platform.isIOS) { SystemNavigator.pop(); return; }
    try { appWindow.close(); } catch (e) { debugPrint('[WIN] close: $e'); SystemNavigator.pop(); }
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid || Platform.isIOS) return const SizedBox.shrink();
    final iconColor = widget.isDark ? Colors.white60 : const Color(0xFF5F6368);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _WinBtn(onTap: _minimize,
          child: Icon(Icons.remove_rounded, size: 14, color: iconColor)),
      _WinBtn(onTap: _toggleMaximize,
          child: Icon(_isMaximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
              size: 13, color: iconColor)),
      _WinBtn(onTap: _close, hoverColor: Colors.red.shade600,
          child: Icon(Icons.close_rounded, size: 14, color: iconColor)),
      const SizedBox(width: 2),
    ]);
  }
}

class _WinBtn extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;
  final Color? hoverColor;
  const _WinBtn({required this.onTap, required this.child, this.hoverColor});
  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 40, height: 40,
          color: _hovered
              ? (widget.hoverColor ?? Colors.white.withValues(alpha: 0.10))
              : Colors.transparent,
          alignment: Alignment.center,
          child: widget.child,
        ),
      ),
    );
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
  bool _skipLinks = true;
  bool _skipPageNumbers = true;
  bool _skipSuperscripts = false;
  bool _pdfInvert = false;

  double _textZoomFactor = 1.0;
  double _textBaselineZoom = 1.0;
  double _pdfZoomFactor = 0.5;
  double _pdfBaselineZoom = 0.7;
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
  bool _parametryOpen = false;
  final LayerLink _parametryLayerLink = LayerLink();
  OverlayEntry? _parametryOverlay;
  bool _speedOpen = false;
  final LayerLink _speedLayerLink = LayerLink();
  OverlayEntry? _speedOverlay;
  bool _moreOpen = false;
  final LayerLink _moreLayerLink = LayerLink();
  OverlayEntry? _moreOverlay;
  final LayerLink _themeLayerLink = LayerLink();
  bool _themeOpen = false;
  OverlayEntry? _themeOverlay;

  bool _searchOpen = false;
  String _searchQuery = '';
  final List<int> _searchMatches = [];
  int _searchMatchIndex = 0;
  Timer? _searchDebounce;

  bool _autoSpeedIncrease = false;
  int _wordsReadSinceSpeedIncrease = 0;
  static const int _autoSpeedWordInterval = 650;
  static const double _autoSpeedStep = 0.05;

  bool get _isTxtFile => widget.book.filePath.toLowerCase().endsWith('.txt');
  double get _currentZoomFactor => globalIsOriginalLayout ? _pdfZoomFactor : _textZoomFactor;
  List<ModelConfig> get _filteredModels => availableModels.where((m) => m.id != _selectedModel.id).toList();
  bool get _isDark {
    final mode = appThemeNotifier.value;
    if (mode == 2) return true;
    if (mode == 1) return false;
    return WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
  }

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
    SharedPreferences.getInstance().then((prefs) {
      final savedSpeed = prefs.getDouble('speed_${widget.book.id}');
      final savedAutoSpeed = prefs.getBool('auto_speed_${widget.book.id}') ?? false;
      final savedSkipLinks = prefs.getBool('skip_links') ?? true;
      final savedSkipPages = prefs.getBool('skip_pages') ?? true;
      final savedSkipParens = prefs.getBool('skip_parens') ?? false;
      final savedSkipSuper = prefs.getBool('skip_superscripts') ?? false;
      final savedWordIndex = prefs.getInt('word_${widget.book.id}') ?? 0;
      if (mounted) setState(() {
        if (savedSpeed != null) _playbackSpeed = savedSpeed;
        _autoSpeedIncrease = savedAutoSpeed;
        _skipLinks = savedSkipLinks;
        _skipPageNumbers = savedSkipPages;
        _skipParentheses = savedSkipParens;
        _skipSuperscripts = savedSkipSuper;
        if (savedWordIndex > 0) {
          _currentWordIndex = savedWordIndex;
          prefs.setInt('word_${widget.book.id}', 0);
        }
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pdfVertScrollController.addListener(_onPdfScroll);
      _pdfHorizScrollController.addListener(_onPdfScroll);
      if (_isReady && mounted) {
        _recenterToCurrentChunk();
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted && _isReady) _recenterToCurrentChunk();
        });
      }
      if (mounted) {
        final screenW = MediaQuery.of(context).size.width;
        final baseline = ((400.0 / screenW) * 0.8).clamp(0.5, 1.0);
        setState(() {
          _pdfBaselineZoom = baseline;
          _pdfZoomFactor = baseline;
        });
      }
    });
  }

  Timer? _onPdfScrollDebounce;

  void _onPdfScroll() {
    if (_isProgrammaticScrolling) return;
    _onPdfScrollDebounce?.cancel();
    _onPdfScrollDebounce = Timer(const Duration(milliseconds: 80), () {
      if (!_isProgrammaticScrolling && !_isUserScrolling && mounted) {
        setState(() { _isUserScrolling = true; });
      }
    });
  }

  void _setupAudioListeners() {
    _playbackStateSubscription?.cancel();
    _positionSubscription?.cancel();

    if (Platform.isAndroid || Platform.isIOS) {
      _playbackStateSubscription = audioHandler.playbackState.listen((state) {
        if (state.processingState == AudioProcessingState.completed && _isBusy) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_isBusy) return;
            if (_stopAtEndOfBlock) { _stopAudioAndPop(); } else { _handleTrackComplete(); }
          });
        }
      });
      _positionSubscription = audioHandler.player
          .createPositionStream(minPeriod: const Duration(milliseconds: 60), maxPeriod: const Duration(milliseconds: 80))
          .listen((p) => _updateWordHighlight(p));
    } else {
      _playbackStateSubscription = windowsPlayer.processingStateStream.listen((state) {
        if (state == ProcessingState.completed && _isBusy) {
          final dur = windowsPlayer.duration;
          final pos = windowsPlayer.position;
          if (dur == null || dur.inMilliseconds == 0) {
            return;
          }
          if (pos.inMilliseconds < 100) {
            return;
          }
          // Call directly — addPostFrameCallback waits for a Flutter frame which
          // on Windows requires OS message pump activity (mouse hover etc).
          // _handleTrackComplete is safe to call from a stream listener.
          if (!_isBusy) return;
          if (_stopAtEndOfBlock) { _stopAudioAndPop(); } else { _handleTrackComplete(); }
        }
      });
      _positionSubscription = windowsPlayer
          .createPositionStream(minPeriod: const Duration(milliseconds: 60), maxPeriod: const Duration(milliseconds: 80))
          .listen((p) => _updateWordHighlight(p));
    }
  }

  void _stopAudioAndPop() async {
    _isBusy = false;
    if (Platform.isAndroid || Platform.isIOS) await audioHandler.stop(); else await windowsPlayer.stop();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    if (!_isBusy) {
      _playbackStateSubscription?.cancel();
      _positionSubscription?.cancel();
    }
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
    _parametryOverlay?.remove();
    _moreOverlay?.remove();
    _themeOverlay?.remove();
    _searchDebounce?.cancel();
    _onPdfScrollDebounce?.cancel();
    unawaited(_pdfRenderService.dispose());
    super.dispose();
  }

  void _scrollListener() {}

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
    try {
      await _pdfRenderService.open(widget.book.filePath);
      for (int i = 1; i <= globalTotalPdfPages; i++) {
        final renderRes = (displayWidth * 1.0).clamp(400.0, 700.0);
        final rendered = await _pdfRenderService.renderPage(i, renderRes);
        if (!mounted) { _isPagesRendering = false; return; }
        setState(() => _renderedPages.add(rendered));
      }
    } catch (e) {
      debugPrint('[PDF_RENDER] Error rendering pages: $e');
      if (mounted) {
        setState(() { globalIsOriginalLayout = false; });
      }
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
        setState(() { _loadingStatusText = "Rozřazuji text do odstavců..."; });
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
            _mergeAbbreviationChunks();
            _recenterToCurrentChunk();
          },
        );
      } else {
        setState(() { _loadingStatusText = "Mapuji strukturu stránek..."; });
        final bytes = await file.readAsBytes();
        _loadedDocument = sf.PdfDocument(inputBytes: bytes);
        globalTotalPdfPages = _loadedDocument!.pages.count;
        globalCachedDocument = _loadedDocument;

        setState(() { _loadingStatusText = "Zaměřuji pozici slov pro zvýrazňování textu..."; });

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
            _mergeAbbreviationChunks();
            _mergeLargeGapChunks();
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
    final List<String> words = currentChunk.text.split(' ');
    if (words.isEmpty) return;
    final totalDuration = (Platform.isAndroid || Platform.isIOS) ? audioHandler.player.duration : windowsPlayer.duration;
    if (totalDuration == null || totalDuration.inMilliseconds == 0) return;

    List<int> spokenWordIndices;
    if (_skipParentheses) {
      spokenWordIndices = [];
      final parenRegex = RegExp(r'\(([^)]*)\)');
      int charPos = 0;
      for (int wi = 0; wi < words.length; wi++) {
        final wordEnd = charPos + words[wi].length;
        bool inParen = false;
        for (final m in parenRegex.allMatches(currentChunk.text)) {
          if (charPos >= m.start && wordEnd <= m.end + 1) { inParen = true; break; }
        }
        if (!inParen) spokenWordIndices.add(wi);
        charPos = wordEnd + 1;
      }
    } else {
      spokenWordIndices = List.generate(words.length, (i) => i);
    }

    if (spokenWordIndices.isEmpty) return;

    final List<String> spokenWords = spokenWordIndices.map((i) => words[i]).toList();
    final int totalChars = spokenWords.fold(0, (s, w) => s + w.length.clamp(1, 999));
    final double progressFraction = position.inMilliseconds / totalDuration.inMilliseconds;

    double accumulated = 0.0;
    int spokenIdx = 0;
    for (int i = 0; i < spokenWords.length; i++) {
      final wordWeight = spokenWords[i].length.clamp(1, 999) / totalChars;
      if (accumulated + wordWeight > progressFraction) { spokenIdx = i; break; }
      accumulated += wordWeight;
      spokenIdx = i;
    }

    final int originalWordIdx = spokenWordIndices[spokenIdx.clamp(0, spokenWordIndices.length - 1)];
    if (originalWordIdx != _currentWordIndex) {
      setState(() { _currentWordIndex = originalWordIdx; });
    }
  }

  void _handleTrackComplete() async {
    if (_autoSpeedIncrease && _currentChunkIndex < _chunksMetadata.length) {
      final words = _chunksMetadata[_currentChunkIndex].text.trim().split(RegExp(r'\s+')).length;
      _wordsReadSinceSpeedIncrease += words;
      while (_wordsReadSinceSpeedIncrease >= _autoSpeedWordInterval) {
        _wordsReadSinceSpeedIncrease -= _autoSpeedWordInterval;
        final newSpeed = (_playbackSpeed + _autoSpeedStep).clamp(0.5, 4.0);
        _playbackSpeed = newSpeed;
        SharedPreferences.getInstance().then((p) => p.setDouble('speed_${widget.book.id}', newSpeed));
        if (mounted) setState(() {});
      }
    }
    _currentWordIndex = 0;
    _currentChunkIndex++;
    _saveCurrentProgress();
    // Call directly — the old postFrameCallback competed with scheduleFrame()
    // inside _executeChunkReading, causing both to wait for a frame that only
    // arrives on Windows when the OS message pump fires (mouse hover).
    if (mounted && _isBusy) _executeChunkReading();
  }

  // ─── FIX: restored tail-call pattern — safe because each skip returns
  // immediately; there is no deep stack build-up. The while-loop alternative
  // in the broken version had an async re-entry bug via _saveCurrentProgress().
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
    await prefs.setInt('word_${widget.book.id}', _currentWordIndex);
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

  Future<String> _prepareFile(String assetPath, {String? targetPath, bool forceOverwrite = false}) async {
    try {
      final directory = await getApplicationSupportDirectory();
      final finalPath = targetPath ?? assetPath;
      final file = File('${directory.path}/$finalPath');
      if (!forceOverwrite && await file.exists() && await file.length() > 0) {
        return file.path.replaceAll('\\', '/');
      }
      final byteData = await rootBundle.load(assetPath);
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      final buffer = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
      await file.writeAsBytes(buffer, flush: true);
      return file.path.replaceAll('\\', '/');
    } catch (e) {
      debugPrint('[PREPARE_FILE] Error for $assetPath: $e');
      return "";
    }
  }

  Future<void> _initEngine() async {
    if (globalCurrentModelId == _selectedModel.id && globalTts != null) {
      return;
    }

    setState(() { _loadingStatusText = "Připravuji hlasový engine..."; });

    try {
      final directory = await getApplicationSupportDirectory();
      const esSub = 'shared-espeak-ng-data';
      final esAssetDir = 'assets/models/kokoro-en-v0_19/espeak-ng-data';

      final File checkFile = File('${directory.path}/$esSub/phontab');
      if (!await checkFile.exists()) {
        setState(() { _loadingStatusText = "Konfiguruji jazykové sady (může trvat chvíli)..."; });

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

      setState(() { _loadingStatusText = "Spouštím hlas: ${_selectedModel.name}..."; });

      final espeakDataPath = '${directory.path}/$esSub'.replaceAll('\\', '/');
      sherpa.OfflineTtsModelConfig modelConfig;

      final modelPath = await _prepareFile('${_selectedModel.assetDir}/${_selectedModel.modelFile}', targetPath: '${_selectedModel.id}_model.onnx');
      final tokensPath = await _prepareFile('${_selectedModel.assetDir}/tokens.txt', targetPath: '${_selectedModel.id}_tokens.txt');

      if (modelPath.isEmpty || tokensPath.isEmpty) throw Exception("Error loading assets.");

      final int numThreads = (Platform.isAndroid || Platform.isIOS) ? 2 : 4;
      final bool debugMode = !(Platform.isAndroid || Platform.isIOS);

      if (_selectedModel.id == 'en_kokoro') {
        final extraPath = await _prepareFile('${_selectedModel.assetDir}/${_selectedModel.configFile}', targetPath: _selectedModel.configFile);
        modelConfig = sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(model: modelPath, voices: extraPath, tokens: tokensPath, dataDir: espeakDataPath),
          numThreads: numThreads,
          debug: debugMode,
        );
      } else {
        await _prepareFile('${_selectedModel.assetDir}/${_selectedModel.configFile}', targetPath: '${_selectedModel.id}_config.json');
        modelConfig = sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(model: modelPath, tokens: tokensPath, dataDir: espeakDataPath, noiseScale: 0.667, noiseScaleW: 0.8, lengthScale: 1.0),
          numThreads: numThreads,
          debug: debugMode,
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

  void _scrollToCurrentChunk(int index, {bool force = false}) {
    if (_chunksMetadata.isEmpty || index >= _chunksMetadata.length) return;
    if (!force && _isUserScrolling) return;
    if (globalIsOriginalLayout) {
      if (_isTxtFile || _renderedPages.isEmpty) return;
      _isProgrammaticScrolling = true;
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

            double pageTopY = 16.0;
            for (final rp in _renderedPages) {
              if (rp.pageNumber == chunk.pageNumber) break;
              pageTopY += (dw * rp.heightPt / rp.widthPt) + 16.0;
            }

            double wordFracY = 0.1;
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
    _isProgrammaticScrolling = true;
    setState(() { _isUserScrolling = false; });
    _scrollToCurrentChunk(_currentChunkIndex, force: true);
  }

  void _startPdfReading() async {
    if (_chunksMetadata.isEmpty || globalTts == null) return;
    if (!await File(widget.book.filePath).exists()) {
      globalIsAudioBusy = false;
      globalActiveBookId = null;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Document was deleted, moved or renamed.')));
      return;
    }
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

  // ─── FIXED _executeChunkReading ──────────────────────────────────────────
  // Key changes vs the broken version:
  //   1. Skip logic is a single if/return per condition — no while loop.
  //      Skipping calls _skipToNextFailedChunk() which is a proper tail-call
  //      back into _executeChunkReading(); no async re-entry issue.
  //   2. Windows player uses the working delay pattern from v1.
  //      windowsPlayer.load() is NOT a valid just_audio API and was removed.
  //   3. Pre-buffer is limited to +1 only. Concurrent generate() calls for
  //      +1/+2/+3 block the main thread and freeze the UI.
  void _executeChunkReading() async {
    if (_currentChunkIndex >= _chunksMetadata.length || !_isBusy) {
      if (mounted) setState(() { _isBusy = false; });
      return;
    }

    // ── Skip checks — each returns via _skipToNextFailedChunk() ──────────
    final String raw = _chunksMetadata[_currentChunkIndex].text;

    if (_skipPageNumbers && RegExp(r'^\d{1,4}$').hasMatch(raw.trim())) {
      _skipToNextFailedChunk();
      return;
    }
    if (_skipLinks && RegExp(r'^https?://\S+$|^www\.\S+$').hasMatch(raw.trim())) {
      _skipToNextFailedChunk();
      return;
    }
    if (_skipSuperscripts) {
      final t = raw.trim();
      if (RegExp(r'^[\d¹²³⁴⁵⁶⁷⁸⁹⁰]+$').hasMatch(t) && t.length <= 3) {
        _skipToNextFailedChunk();
        return;
      }
      if (RegExp(r'^\[\d{1,3}\]$').hasMatch(t)) {
        _skipToNextFailedChunk();
        return;
      }
      if (RegExp(r'^\d{1,3}[\.\)]\s').hasMatch(t) && t.split(' ').length <= 8) {
        _skipToNextFailedChunk();
        return;
      }
    }
    if (_skipParentheses) {
      final stripped = raw.replaceAll(RegExp(r'\([^)]*\)'), ' ').replaceAll(RegExp(r'\s{2,}'), ' ').trim();
      if (stripped.isEmpty) {
        _skipToNextFailedChunk();
        return;
      }
    }

    try {
      String rawText = _chunksMetadata[_currentChunkIndex].text;
      if (_skipParentheses) {
        rawText = rawText.replaceAll(RegExp(r'\([^)]*\)'), ' ').replaceAll(RegExp(r'\s{2,}'), ' ').trim();
      }
      if (TextSanitizer.isBulletLine(rawText)) rawText = '... $rawText';

      _scrollToCurrentChunk(_currentChunkIndex);

      if (globalIsOriginalLayout && !_isTxtFile) {
        setState(() { globalCurrentPdfPage = _chunksMetadata[_currentChunkIndex].pageNumber; });
      }

      // When skip flags are active, bypass cache so we always speak the
      // stripped text rather than the originally-generated audio.
      final bool skipActive = _skipParentheses || _skipLinks || _skipPageNumbers || _skipSuperscripts;
      String? wavPath = skipActive ? null : _pregeneratedAudioCache[_currentChunkIndex];

      if (wavPath == null) {
        if (rawText.trim().isEmpty) {
          _skipToNextFailedChunk();
          return;
        }
        if (globalTts == null) {
          _skipToNextFailedChunk();
          return;
        }

        String ttsText = rawText;

        // Czech ordinal expansion
        const Map<String, String> ordinals = {
          '100.': 'stý', '90.': 'devadesátý', '80.': 'osmdesátý',
          '70.': 'sedmdesátý', '60.': 'šedesátý', '50.': 'padesátý',
          '40.': 'čtyřicátý', '30.': 'třicátý', '20.': 'dvacátý',
          '19.': 'devatenáctý', '18.': 'osmnáctý', '17.': 'sedmnáctý',
          '16.': 'šestnáctý', '15.': 'patnáctý', '14.': 'čtrnáctý',
          '13.': 'třináctý', '12.': 'dvanáctý', '11.': 'jedenáctý',
          '10.': 'desátý', '9.': 'devátý', '8.': 'osmý', '7.': 'sedmý',
          '6.': 'šestý', '5.': 'pátý', '4.': 'čtvrtý', '3.': 'třetí',
          '2.': 'druhý', '1.': 'první',
        };
        for (final entry in ordinals.entries) {
          ttsText = ttsText.replaceAllMapped(
            RegExp('(?<=[\\s(]|^)${RegExp.escape(entry.key)}(?=[\\s)]|\$)'),
                (_) => entry.value,
          );
        }

        // Colon → natural pause (longer than comma, shorter than period)
        ttsText = ttsText.replaceAll(RegExp(r':\s+'), ', ');
        ttsText = ttsText.replaceAll(RegExp(r':$'), '.');
        // Parentheses → wrap with commas so TTS lowers pitch and pauses slightly.
        // Converts "(text)" → ", text," which most VITS models interpret as
        // a natural aside. Strip the parens themselves to avoid mispronunciation.
        ttsText = ttsText.replaceAllMapped(
          RegExp(r'\(([^)]{1,120})\)'),
              (m) {
            final inner = m.group(1)!.trim();
            if (inner.isEmpty) return '';
            // If it ends with punctuation keep it, otherwise add comma
            final endsWithPunct = inner.endsWith('.') || inner.endsWith(',') ||
                inner.endsWith('!') || inner.endsWith('?');
            return endsWithPunct ? ', $inner ' : ', $inner,';
          },
        );
        // Bullet chars that survive sanitization → short pause
        ttsText = ttsText.replaceAll('• ', '... ');
        ttsText = ttsText.replaceAll('– ', ', ');
        ttsText = ttsText.replaceAll('— ', ', ');

        // Abbreviation normalisation
        const abbrevStemsRaw = r'(tzv|napr|než|např|tj|atd|apod|str|kap|dr|prof|ing|mgr|bc|phd|mudr|eg|ie|etc|vs|viz)';
        ttsText = ttsText.replaceAllMapped(
          RegExp(r'\b' + abbrevStemsRaw + r'\.(\S)', caseSensitive: false),
              (m) => '${m.group(1)}. ${m.group(2)}',
        );
        ttsText = DictionaryJirka.apply(ttsText);
        ttsText = ttsText.replaceAllMapped(
          RegExp(r'\b' + abbrevStemsRaw + r'\.$', caseSensitive: false),
              (m) => m.group(1)!,
        );

        if (!_isBusy) return;
        final audio = globalTts!.generate(text: ttsText, sid: _selectedModel.sid);
        final tempDir = await getTemporaryDirectory();
        wavPath = p.join(tempDir.path,
            'chunk_${_currentChunkIndex}_${DateTime.now().millisecondsSinceEpoch}.wav');
        sherpa.writeWave(filename: wavPath, samples: audio.samples, sampleRate: audio.sampleRate);
      }

      if (_isBusy) {
        if (Platform.isAndroid || Platform.isIOS) {
          await audioHandler.playFile(wavPath, rawText);
          await audioHandler.player.setSpeed(_playbackSpeed);
          await audioHandler.player.setVolume(_volume);
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
        // Pre-generate the NEXT chunk while the current one plays.
        // generate() is synchronous and blocks the thread, but since
        // audio playback runs independently (just_audio plays in its own
        // thread), we can call generate() here and the freeze happens
        // during playback — not between chunks — so the user never hears
        // a gap. The key rule: only generate ONE chunk ahead, never two,
        // because concurrent generate() calls corrupt the native engine.
        _pregenerateNextChunk(_currentChunkIndex + 1);
      }
    } catch (e) {
      debugPrint('Chunk read error: $e');
      _skipToNextFailedChunk();
    }
  }

  // Pre-generates chunk [nextIndex] and caches the wav path.
  // Called immediately after play() so it runs during playback, not between chunks.
  // Guards against re-entry: if a pre-generation is already running, bails out.
  bool _isPreGenerating = false;
  Future<void> _pregenerateNextChunk(int nextIndex) async {
    if (_isPreGenerating) return;
    if (nextIndex >= _chunksMetadata.length) return;
    if (_pregeneratedAudioCache.containsKey(nextIndex)) return;
    if (globalTts == null) return;
    final raw = _chunksMetadata[nextIndex].text;
    if (_skipPageNumbers && RegExp(r'^\d{1,4}$').hasMatch(raw.trim())) return;
    if (_skipLinks && RegExp(r'^https?://\S+$|^www\.\S+$').hasMatch(raw.trim())) return;
    _isPreGenerating = true;
    // No scheduleFrame here — this runs during playback and pumping frames
    // races with the processingState stream, causing premature track advance.
    if (!_isBusy) { _isPreGenerating = false; return; }
    try {
      String ttsText = raw;
      if (_skipParentheses) {
        ttsText = ttsText.replaceAll(RegExp(r'\([^)]*\)'), ' ').replaceAll(RegExp(r'\s{2,}'), ' ').trim();
        if (ttsText.isEmpty) { _isPreGenerating = false; return; }
      }
      if (TextSanitizer.isBulletLine(ttsText)) ttsText = '... $ttsText';
      ttsText = DictionaryJirka.apply(ttsText);
      final audio = globalTts!.generate(text: ttsText, sid: _selectedModel.sid);
      final tempDir = await getTemporaryDirectory();
      final path = p.join(tempDir.path, 'prebuf_${nextIndex}_${DateTime.now().millisecondsSinceEpoch}.wav');
      if (sherpa.writeWave(filename: path, samples: audio.samples, sampleRate: audio.sampleRate)) {
        _pregeneratedAudioCache[nextIndex] = path;
      }
    } catch (e) {
      debugPrint('Pre-generate error: $e');
    }
    _isPreGenerating = false;
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
            color: (color == Colors.transparent ? (_isDark ? Colors.white.withValues(alpha: 0.15) : Colors.grey.withValues(alpha: 0.22)) : color),
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }

  List<TextSpan> _buildSearchHighlightedWords(String text, String query, bool isActive) {
    if (query.isEmpty) return [TextSpan(text: text)];
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    int cursor = 0;
    while (cursor < text.length) {
      final idx = lower.indexOf(query, cursor);
      if (idx == -1) {
        spans.add(TextSpan(text: text.substring(cursor)));
        break;
      }
      if (idx > cursor) spans.add(TextSpan(text: text.substring(cursor, idx)));
      spans.add(TextSpan(
        text: text.substring(idx, idx + query.length),
        style: TextStyle(
          backgroundColor: isActive ? const Color(0xFF00897B).withValues(alpha: 0.35) : const Color(0xFF00897B).withValues(alpha: 0.18),
          color: isActive ? const Color(0xFF004D40) : const Color(0xFF00695C),
          fontWeight: FontWeight.w700,
        ),
      ));
      cursor = idx + query.length;
    }
    return spans;
  }

  List<TextSpan> _buildHighlightedWords(String text, BuildContext context) {
    if (_skipParentheses && RegExp(r'\(').hasMatch(text)) {
      final spans = <TextSpan>[];
      final parenRegex = RegExp(r'\(([^)]*)\)');
      int cursor = 0;
      for (final match in parenRegex.allMatches(text)) {
        if (match.start > cursor) {
          final before = text.substring(cursor, match.start).split(' ');
          for (int j = 0; j < before.length; j++) {
            final wi = _wordIndexUpTo(text, cursor) + j;
            final isCurrent = wi == _currentWordIndex;
            spans.add(TextSpan(
              text: before[j] + (j == before.length - 1 && match.start == text.length ? '' : ' '),
              style: TextStyle(
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                backgroundColor: isCurrent ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2) : Colors.transparent,
                color: isCurrent ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ));
          }
        }
        spans.add(TextSpan(
          text: match.group(0),
          style: TextStyle(
            color: Colors.purple.shade400,
            backgroundColor: Colors.purple.shade50,
            fontStyle: FontStyle.italic,
            decoration: TextDecoration.lineThrough,
            decorationColor: Colors.purple.shade300,
          ),
        ));
        cursor = match.end;
      }
      if (cursor < text.length) {
        final after = text.substring(cursor).split(' ');
        for (int j = 0; j < after.length; j++) {
          final wi = _wordIndexUpTo(text, cursor) + j;
          final isCurrent = wi == _currentWordIndex;
          spans.add(TextSpan(
            text: after[j] + (j == after.length - 1 ? '' : ' '),
            style: TextStyle(
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              backgroundColor: isCurrent ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2) : Colors.transparent,
              color: isCurrent ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ));
        }
      }
      return spans;
    }

    List<String> words = text.split(' ');
    List<TextSpan> spans = [];
    for (int i = 0; i < words.length; i++) {
      bool isCurrent = i == _currentWordIndex;
      spans.add(TextSpan(
        text: words[i] + (i == words.length - 1 ? "" : " "),
        style: TextStyle(
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          backgroundColor: isCurrent ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2) : Colors.transparent,
          color: isCurrent ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ));
    }
    return spans;
  }

  int _wordIndexUpTo(String text, int charOffset) {
    if (charOffset <= 0) return 0;
    return text.substring(0, charOffset).split(' ').length - 1;
  }

  String _etaString(int fromChunk, int toChunk, double speed) {
    if (_chunksMetadata.isEmpty || speed <= 0) return '';
    int words = 0;
    for (int i = fromChunk.clamp(0, _chunksMetadata.length); i < toChunk.clamp(0, _chunksMetadata.length); i++) {
      words += _chunksMetadata[i].text.trim().split(RegExp(r'\s+')).length;
    }
    final minutes = (words / (150.0 * speed)).round();
    if (minutes < 1) return '<1 min';
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}min';
  }

  void _mergeAbbreviationChunks() {
    final abbrevPattern = RegExp(
      r'^(tzv|napr|např|tj|atd|apod|str|kap|dr|prof|ing|mgr|bc|phd|mudr|eg|ie|etc|vs|viz|'
      r'jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec|po|út|st|čt|pá)\.*[,;]?$',
      caseSensitive: false,
    );
    final abbrevInParenPattern = RegExp(
      r'\(\s*(tzv|napr|např|tj|atd|apod|str|kap|dr|prof|ing|mgr|bc|phd|mudr|eg|ie|etc|vs|viz)\s*$',
      caseSensitive: false,
    );
    for (int i = _chunksMetadata.length - 2; i >= 0; i--) {
      final text = _chunksMetadata[i].text.trim();
      final shouldMerge = abbrevPattern.hasMatch(text) || abbrevInParenPattern.hasMatch(text);
      if (shouldMerge && i + 1 < _chunksMetadata.length) {
        final merged = PdfChunkMetadata(
          text: '$text ${_chunksMetadata[i + 1].text}',
          pageNumber: _chunksMetadata[i].pageNumber,
          pdfWords: [..._chunksMetadata[i].pdfWords, ..._chunksMetadata[i + 1].pdfWords],
        );
        _chunksMetadata[i] = merged;
        _chunksMetadata.removeAt(i + 1);
        if (i + 1 < _chunkHeadingLevels.length) _chunkHeadingLevels.removeAt(i + 1);
      }
    }
  }

  void _mergeLargeGapChunks() {
    for (int i = _chunksMetadata.length - 2; i >= 0; i--) {
      final String a = _chunksMetadata[i].text.trim();
      final String b = _chunksMetadata[i + 1].text.trim();
      if (a.isEmpty || b.isEmpty) continue;
      final String lastChar = a[a.length - 1];
      final String firstChar = b[0];
      final bool aEndsInclusive = '.!?:;–—'.contains(lastChar);
      final bool bStartsLower = firstChar == firstChar.toLowerCase() &&
          firstChar != firstChar.toUpperCase();
      if (!aEndsInclusive && bStartsLower) {
        final merged = PdfChunkMetadata(
          text: '$a $b',
          pageNumber: _chunksMetadata[i].pageNumber,
          pdfWords: [..._chunksMetadata[i].pdfWords, ..._chunksMetadata[i + 1].pdfWords],
        );
        _chunksMetadata[i] = merged;
        _chunksMetadata.removeAt(i + 1);
        if (i + 1 < _chunkHeadingLevels.length) _chunkHeadingLevels.removeAt(i + 1);
      }
    }
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
        _isUserScrolling = false;
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

  Widget _buildAppBar(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final isPhone = screenW < 480;

    final titleRow = Row(children: [
      const SizedBox(width: 4),
      TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: _isDark ? Colors.white70 : Colors.black87),
        onPressed: _handlePopAction,
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 14),
        label: const Text('Zpět', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ),
      const SizedBox(width: 4),
      Expanded(
        child: (!Platform.isAndroid && !Platform.isIOS)
        // MoveWindow lets the user drag the window by the title area.
        // It passes child tap events through, so the InkWell still works.
            ? MoveWindow(
          child: InkWell(
            onTap: _showFileNameDialog,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
              child: Text(widget.book.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14,
                      color: _isDark ? Colors.white : const Color(0xFF1F1F1F))),
            ),
          ),
        )
            : InkWell(
          onTap: _showFileNameDialog,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
            child: Text(widget.book.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14,
                    color: _isDark ? Colors.white : const Color(0xFF1F1F1F))),
          ),
        ),
      ),
      const SizedBox(width: 8),
      if (!_isParsingPdf) ...[
        Container(
          height: 36, constraints: const BoxConstraints(maxWidth: 160),
          decoration: BoxDecoration(color: _isDark ? const Color(0xFF1A3A6E) : const Color(0xFFE8F0FE), borderRadius: BorderRadius.circular(8)),
          child: PopupMenuButton<ModelConfig>(
            enabled: !_isBusy && _isReady,
            offset: const Offset(0, 40),
            constraints: const BoxConstraints(minWidth: 140, maxWidth: 200),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: EdgeInsets.zero,
            onOpened: () { if (_isBusy) _stopPdfReading(); },
            onSelected: (m) { setState(() { _selectedModel = m; }); _initEngineAndLoadPdf(); },
            itemBuilder: (ctx) => _filteredModels.map<PopupMenuEntry<ModelConfig>>((m) =>
                PopupMenuItem<ModelConfig>(
                  value: m, height: 36, padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(3)),
                      child: Text(m.langCode.toUpperCase(), style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.grey)),
                    ),
                    const SizedBox(width: 4),
                    _buildCpuIndicator(m.cpuLoad),
                    const SizedBox(width: 4),
                    Expanded(child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                  ]),
                )).toList(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(color: _isDark ? Colors.white.withValues(alpha: 0.15) : Colors.white, borderRadius: BorderRadius.circular(3)),
                  child: Text(_selectedModel.langCode.toUpperCase(), style: TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: _isDark ? Colors.white54 : Colors.grey)),
                ),
                const SizedBox(width: 4),
                _buildCpuIndicator(_selectedModel.cpuLoad),
                const SizedBox(width: 4),
                Expanded(child: Text(_selectedModel.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: _isDark ? Colors.white : const Color(0xFF1F1F1F), fontWeight: FontWeight.w600))),
                const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF1A73E8), size: 18),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 6),
        if (!_isTxtFile)
          SizedBox(
            height: 36,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: const Color(0xFF1A73E8),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              onPressed: () { setState(() => globalIsOriginalLayout = !globalIsOriginalLayout); _scrollToCurrentChunk(_currentChunkIndex); },
              icon: Icon(globalIsOriginalLayout ? Icons.picture_as_pdf : Icons.text_fields_rounded, size: 18),
              label: Text(globalIsOriginalLayout ? 'PDF' : 'Text', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          )
        else
          Container(height: 36, padding: const EdgeInsets.symmetric(horizontal: 10), alignment: Alignment.center,
              child: const Text('Text', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1A73E8)))),
      ],
    ]);

    Widget themeBtn = CompositedTransformTarget(
      link: _themeLayerLink,
      child: IconButton(
        tooltip: 'Vzhled',
        icon: Icon(
          appThemeNotifier.value == 0 ? Icons.brightness_auto_rounded
              : appThemeNotifier.value == 1 ? Icons.light_mode_rounded
              : Icons.dark_mode_rounded,
          size: 20,
          color: appThemeNotifier.value != 0 ? const Color(0xFF1A73E8) : (_isDark ? const Color(0xFFE0E0E0) : const Color(0xFF5F6368)),
        ),
        onPressed: () => _toggleThemeOverlay(context),
      ),
    );

    final actionItems = <Widget>[
      if (!_isParsingPdf) ...[
        Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
              onPressed: (_currentZoomFactor <= _minZoom || _isMinZoomReached) ? null : () => _changeZoom(-_zoomStep)),
          Container(constraints: const BoxConstraints(minWidth: 36), alignment: Alignment.center,
              child: Text('${((_currentZoomFactor / (globalIsOriginalLayout ? _pdfBaselineZoom : _textBaselineZoom)) * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w700, color: _isDark ? Colors.white : null))),
          IconButton(icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
              onPressed: (_currentZoomFactor >= _maxZoom || _isMaxZoomReached) ? null : () => _changeZoom(_zoomStep)),
        ]),
        CompositedTransformTarget(link: _parametryLayerLink,
          child: IconButton(tooltip: 'Parametry',
            icon: Icon(Icons.tune_rounded,
                color: (_skipParentheses || _skipLinks || _skipPageNumbers || _skipSuperscripts) ? Colors.purple.shade400 : (_isDark ? const Color(0xFFE0E0E0) : const Color(0xFF5F6368)),
                size: 20),
            onPressed: () => _toggleParametryOverlay(context),
          ),
        ),
        IconButton(
          icon: Icon(_searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
              color: _searchOpen ? const Color(0xFF00C853) : null),
          tooltip: 'Hledat (Ctrl+F)',
          onPressed: () => setState(() {
            _searchOpen = !_searchOpen;
            if (!_searchOpen) { _searchQuery = ''; _searchMatches.clear(); _searchMatchIndex = 0; }
          }),
        ),
        IconButton(
          icon: Icon(_isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
          onPressed: () => setState(() => _isFullscreen = !_isFullscreen),
        ),
      ],
    ];

    final actionsRow = isPhone
        ? Row(mainAxisSize: MainAxisSize.min, children: [
      CompositedTransformTarget(
        link: _moreLayerLink,
        child: IconButton(
          icon: Icon(Icons.more_vert_rounded, color: _moreOpen ? const Color(0xFF1A73E8) : null),
          onPressed: () => _toggleMoreOverlay(context),
        ),
      ),
    ])
        : Row(mainAxisSize: MainAxisSize.min, children: [
      ...actionItems,
      themeBtn,
      const SizedBox(width: 4),
      if (!Platform.isAndroid && !Platform.isIOS)
        _WindowControls(isDark: _isDark),
    ]);

    final border = Border(bottom: BorderSide(color: Colors.grey.shade200, width: 1));

    if (isPhone) {
      final phoneTitleRow = Row(children: [
        const SizedBox(width: 4),
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: _isDark ? Colors.white70 : Colors.black87, padding: const EdgeInsets.symmetric(horizontal: 6)),
          onPressed: _handlePopAction,
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 14),
          label: const Text('Zpět', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: InkWell(
            onTap: _showFileNameDialog,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
              child: Text(widget.book.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: _isDark ? Colors.white : const Color(0xFF1F1F1F))),
            ),
          ),
        ),
      ]);
      final phoneSecondRow = Row(children: [
        const SizedBox(width: 8),
        if (!_isParsingPdf) ...[
          Container(
            height: 32, constraints: const BoxConstraints(maxWidth: 150),
            decoration: BoxDecoration(color: _isDark ? const Color(0xFF1A3A6E) : const Color(0xFFE8F0FE), borderRadius: BorderRadius.circular(8)),
            child: PopupMenuButton<ModelConfig>(
              enabled: !_isBusy && _isReady,
              offset: const Offset(0, 36),
              constraints: const BoxConstraints(minWidth: 140, maxWidth: 200),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: EdgeInsets.zero,
              onOpened: () { if (_isBusy) _stopPdfReading(); },
              onSelected: (m) { setState(() { _selectedModel = m; }); _initEngineAndLoadPdf(); },
              itemBuilder: (ctx) => _filteredModels.map<PopupMenuEntry<ModelConfig>>((m) =>
                  PopupMenuItem<ModelConfig>(
                    value: m, height: 36, padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(children: [
                      Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(3)),
                          child: Text(m.langCode.toUpperCase(), style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.grey))),
                      const SizedBox(width: 4), _buildCpuIndicator(m.cpuLoad), const SizedBox(width: 4),
                      Expanded(child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF1F1F1F)))),
                    ]),
                  )).toList(),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [
                  Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3)),
                      child: Text(_selectedModel.langCode.toUpperCase(), style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.grey))),
                  const SizedBox(width: 4), _buildCpuIndicator(_selectedModel.cpuLoad), const SizedBox(width: 4),
                  Expanded(child: Text(_selectedModel.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF1F1F1F), fontWeight: FontWeight.w600))),
                  const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF1A73E8), size: 16),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (!_isTxtFile)
            SizedBox(height: 32,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: const Color(0xFF1A73E8),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                onPressed: () { setState(() => globalIsOriginalLayout = !globalIsOriginalLayout); _scrollToCurrentChunk(_currentChunkIndex); },
                icon: Icon(globalIsOriginalLayout ? Icons.picture_as_pdf : Icons.text_fields_rounded, size: 16),
                label: Text(globalIsOriginalLayout ? 'PDF' : 'Text', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ),
        ],
        const Spacer(),
        actionsRow,
      ]);
      final phoneBar = Container(
        decoration: BoxDecoration(
          color: _isDark ? const Color(0xFF1E1E1E) : Colors.white,
          border: border,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(height: 44, child: phoneTitleRow),
          Container(height: 1, color: _isDark ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade100),
          SizedBox(height: 42, child: phoneSecondRow),
        ]),
      );
      return phoneBar;
    }

    final singleRow = Container(
      decoration: BoxDecoration(
        color: _isDark ? const Color(0xFF1E1E1E) : Colors.white,
        border: border,
      ),
      child: Row(children: [
        Expanded(child: titleRow),
        const VerticalDivider(width: 12, indent: 10, endIndent: 10),
        actionsRow,
      ]),
    );
    // MoveWindow is embedded directly in the title Expanded area above,
    // so no Stack needed — just return singleRow on all platforms.
    return singleRow;
  }

  Widget _buildTocButton(BuildContext context) {
    final entries = _tocEntries;
    if (entries.isEmpty) return const SizedBox.shrink();

    final int activeListIndex = entries.indexWhere((e) => e.index == _activeChapterIndex);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FloatingActionButton.small(
          heroTag: 'toc_fab',
          onPressed: () => setState(() => _tocOpen = !_tocOpen),
          backgroundColor: _tocOpen ? const Color(0xFF1A73E8) : (_isDark ? const Color(0xFF2C2C2C) : Colors.white),
          foregroundColor: _tocOpen ? Colors.white : (_isDark ? Colors.white : Colors.black87),
          elevation: 3,
          child: const Icon(Icons.format_list_bulleted_rounded),
        ),
        if (_tocOpen)
          Builder(builder: (ctx) {
            final sc = ScrollController();
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
                color: _isDark ? const Color(0xFF2C2C2C) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 16, offset: const Offset(0, 4))],
                border: Border.all(color: _isDark ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade200),
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
                            ? Colors.orange.withValues(alpha: 0.12)
                            : isActiveChapter
                            ? (_isDark ? Colors.white.withValues(alpha: 0.12) : Theme.of(ctx).colorScheme.primary.withValues(alpha: 0.1))
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
                                  ? Theme.of(ctx).colorScheme.primary.withValues(alpha: 0.55)
                                  : Theme.of(ctx).colorScheme.primary.withValues(alpha: 0.3),
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
                                  : (_isDark ? Colors.white70 : Colors.black87),
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
              if (n.dragDetails != null && !_isUserScrolling) {
                setState(() { _isUserScrolling = true; });
                _isProgrammaticScrolling = false;
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
                              child: _pdfInvert
                                  ? ColorFiltered(
                                colorFilter: const ColorFilter.matrix(<double>[
                                  -1,  0,  0, 0, 255,
                                  0, -1,  0, 0, 255,
                                  0,  0, -1, 0, 255,
                                  0,  0,  0, 1,   0,
                                ]),
                                child: _buildPdfPagesColumn(availableWidth),
                              )
                                  : _buildPdfPagesColumn(availableWidth),
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

  Widget _buildPdfPagesColumn(double availableWidth) {
    const double pageGap = 16.0;
    final double displayWidth = availableWidth - 96.0;
    return Column(
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
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 18, spreadRadius: 2, offset: const Offset(0, 4),
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
                primaryColor: const Color(0xFF1A73E8),
                skipParentheses: _skipParentheses,
                searchQuery: _searchQuery,
                searchMatchChunks: _searchMatches.toSet(),
                activeSearchChunk: _searchMatches.isNotEmpty ? _searchMatches[_searchMatchIndex] : null,
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
    );
  }

  void _toggleSpeedOverlay(BuildContext context) {
    if (_speedOpen) { _closeSpeedOverlay(); } else { _openSpeedOverlay(context); }
  }

  void _openSpeedOverlay(BuildContext context) {
    _speedOverlay?.remove();
    _speedOpen = true;
    if (mounted) setState(() {});

    _speedOverlay = OverlayEntry(builder: (ctx) {
      const double rangeMin = 0.5;
      const double rangeMax = 4.0;
      const List<double> presets = [0.8, 1.0, 1.2, 1.5, 2.0, 2.5];

      return Stack(fit: StackFit.expand, children: [
        SizedBox.expand(child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _closeSpeedOverlay,
        )),
        UnconstrainedBox(child: CompositedTransformFollower(
          link: _speedLayerLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(0, -6),
          child: Material(
            color: Colors.transparent,
            child: StatefulBuilder(builder: (_, setLocal) {
              final eta = _etaString(_currentChunkIndex, _chunksMetadata.length, _playbackSpeed);
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
                      if (eta.isNotEmpty)
                        Text(eta, style: TextStyle(fontSize: 10, color: dm ? Colors.white54 : const Color(0xFF5F6368), fontWeight: FontWeight.w500)),
                    ]),
                  ),
                  const Divider(height: 1, thickness: 0.5),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text('4x', style: TextStyle(fontSize: 9, color: Color(0xFF9AA0A6))),
                        const SizedBox(height: 4),
                        _VerticalSpeedSlider(
                          value: _playbackSpeed,
                          min: rangeMin,
                          max: rangeMax,
                          height: 180,
                          inactiveColor: dm ? const Color(0xFF3E3E3E) : const Color(0xFFBBBBBB),
                          onChanged: (v) {
                            final snapped = (v * 20).round() / 20.0;
                            _changeSpeed(snapped);
                            setLocal(() {});
                          },
                        ),
                        const SizedBox(height: 4),
                        Text('${rangeMin}x', style: const TextStyle(fontSize: 9, color: Color(0xFF9AA0A6))),
                      ]),
                    ),
                  ),
                  const Divider(height: 1, thickness: 0.5),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                    child: GridView.count(
                      crossAxisCount: 3,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 6,
                      childAspectRatio: 2.2,
                      children: presets.map((spd) {
                        final bool active = (_playbackSpeed - spd).abs() < 0.01;
                        return GestureDetector(
                          onTap: () { _changeSpeed(spd); setLocal(() {}); },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 100),
                            decoration: BoxDecoration(
                              color: active ? const Color(0xFF1A73E8) : (dm ? const Color(0xFF3C3C3C) : const Color(0xFFF1F3F4)),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              spd % 1 == 0 ? '${spd.toInt()}x' : '${spd}x',
                              style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700,
                                color: active ? Colors.white : (dm ? Colors.white70 : Colors.black87),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const Divider(height: 1, thickness: 0.5),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      GestureDetector(
                        onTap: () {
                          final v = ((_playbackSpeed * 20).round() - 1) / 20.0;
                          _changeSpeed(v.clamp(rangeMin, rangeMax));
                          setLocal(() {});
                        },
                        child: Container(
                          width: 34, height: 34,
                          decoration: BoxDecoration(color: dm ? const Color(0xFF3C3C3C) : const Color(0xFFF1F3F4), borderRadius: BorderRadius.circular(8)),
                          alignment: Alignment.center,
                          child: Text('−', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: dm ? Colors.white : const Color(0xFF1F1F1F))),
                        ),
                      ),
                      Text(
                        _playbackSpeed % 1 == 0 ? '${_playbackSpeed.toInt()}x' : '${_playbackSpeed}x',
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF1A73E8)),
                      ),
                      GestureDetector(
                        onTap: () {
                          final v = ((_playbackSpeed * 20).round() + 1) / 20.0;
                          _changeSpeed(v.clamp(rangeMin, rangeMax));
                          setLocal(() {});
                        },
                        child: Container(
                          width: 34, height: 34,
                          decoration: BoxDecoration(color: dm ? const Color(0xFF3C3C3C) : const Color(0xFFF1F3F4), borderRadius: BorderRadius.circular(8)),
                          alignment: Alignment.center,
                          child: Text('+', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: dm ? Colors.white : const Color(0xFF1F1F1F))),
                        ),
                      ),
                    ]),
                  ),
                  const Divider(height: 1, thickness: 0.5),
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
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                      child: Row(children: [
                        GestureDetector(
                          onTap: () {
                            _autoSpeedIncrease = !_autoSpeedIncrease;
                            _wordsReadSinceSpeedIncrease = 0;
                            SharedPreferences.getInstance().then(
                                    (p) => p.setBool('auto_speed_${widget.book.id}', _autoSpeedIncrease));
                            setLocal(() {});
                            setState(() {});
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 20, height: 20,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _autoSpeedIncrease ? const Color(0xFF1A73E8) : Colors.transparent,
                              border: Border.all(
                                color: _autoSpeedIncrease ? const Color(0xFF1A73E8) : Colors.grey.shade400,
                                width: 2,
                              ),
                            ),
                            child: _autoSpeedIncrease
                                ? const Icon(Icons.check_rounded, size: 12, color: Colors.white)
                                : null,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('Zvýšit rychlost automaticky\nkaždých 650 slov',
                              style: TextStyle(fontSize: 10, height: 1.35, fontWeight: FontWeight.w500, color: dm ? Colors.white70 : const Color(0xFF3C4043))),
                        ),
                      ]),
                    ),
                  ),
                ]),
              );
            }),
          ),
        ),
        ),
      ]);
    });

    Overlay.of(context).insert(_speedOverlay!);
  }

  void _toggleMoreOverlay(BuildContext context) {
    if (_moreOpen) { _closeMoreOverlay(); } else { _openMoreOverlay(context); }
  }

  void _openMoreOverlay(BuildContext context) {
    _moreOverlay?.remove();
    _moreOpen = true;
    if (mounted) setState(() {});

    _moreOverlay = OverlayEntry(builder: (_) => Stack(fit: StackFit.expand, children: [
      SizedBox.expand(child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _closeMoreOverlay)),
      UnconstrainedBox(child: CompositedTransformFollower(
        link: _moreLayerLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomRight,
        followerAnchor: Alignment.topRight,
        offset: const Offset(0, 4),
        child: Material(
          color: Colors.transparent,
          child: StatefulBuilder(builder: (_, setLocal) {
            final bool mdm = _isDark;
            return Container(
              width: 220,
              decoration: BoxDecoration(
                color: mdm ? const Color(0xFF2C2C2C) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 16, offset: const Offset(0, 4))],
                border: Border.all(color: mdm ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade200),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (!_isParsingPdf) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(children: [
                      const Icon(Icons.zoom_in_rounded, size: 16, color: Color(0xFF5F6368)),
                      const SizedBox(width: 6),
                      Text('Zoom', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: mdm ? Colors.white : const Color(0xFF1F1F1F))),
                      const Spacer(),
                      IconButton(icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
                          onPressed: (_currentZoomFactor <= _minZoom) ? null : () { _changeZoom(-_zoomStep); setLocal(() {}); },
                          padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
                      Container(constraints: const BoxConstraints(minWidth: 40), alignment: Alignment.center,
                          child: Text('${((_currentZoomFactor / (globalIsOriginalLayout ? _pdfBaselineZoom : _textBaselineZoom)) * 100).toStringAsFixed(0)}%',
                              style: TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w700, color: _isDark ? Colors.white : null))),
                      IconButton(icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                          onPressed: (_currentZoomFactor >= _maxZoom) ? null : () { _changeZoom(_zoomStep); setLocal(() {}); },
                          padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
                    ]),
                  ),
                  const Divider(height: 1, thickness: 0.5),
                  ListTile(dense: true, leading: Icon(Icons.tune_rounded,
                      color: (_skipParentheses || _skipLinks || _skipPageNumbers || _skipSuperscripts) ? Colors.purple.shade400 : const Color(0xFF5F6368), size: 20),
                    title: const Text('Parametry', style: TextStyle(fontSize: 13)),
                    onTap: () { _closeMoreOverlay(); _toggleParametryOverlay(context); },
                  ),
                  ListTile(dense: true,
                    leading: Icon(_searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
                        color: _searchOpen ? const Color(0xFF00C853) : null, size: 20),
                    title: const Text('Hledat', style: TextStyle(fontSize: 13)),
                    onTap: () {
                      setState(() {
                        _searchOpen = !_searchOpen;
                        if (!_searchOpen) { _searchQuery = ''; _searchMatches.clear(); _searchMatchIndex = 0; }
                      });
                      _closeMoreOverlay();
                    },
                  ),
                  ListTile(dense: true,
                    leading: Icon(_isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, size: 20),
                    title: Text(_isFullscreen ? 'Ukončit celou obrazovku' : 'Celá obrazovka', style: const TextStyle(fontSize: 13)),
                    onTap: () { setState(() => _isFullscreen = !_isFullscreen); _closeMoreOverlay(); },
                  ),
                  const Divider(height: 1, thickness: 0.5),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                  child: Row(children: [
                    const Icon(Icons.brightness_6_rounded, size: 16, color: Color(0xFF5F6368)),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Vzhled', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                    Container(
                      decoration: BoxDecoration(color: const Color(0xFFF1F3F4), borderRadius: BorderRadius.circular(8)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        for (final entry in [
                          (0, Icons.brightness_auto_rounded),
                          (1, Icons.light_mode_rounded),
                          (2, Icons.dark_mode_rounded),
                        ])
                          GestureDetector(
                            onTap: () {
                              appThemeNotifier.value = entry.$1; setState(() {});
                              SharedPreferences.getInstance().then((p) => p.setInt('theme_mode', appThemeNotifier.value));
                              setLocal(() {});
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                              decoration: BoxDecoration(
                                color: appThemeNotifier.value == entry.$1 ? const Color(0xFF1A73E8) : Colors.transparent,
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Icon(entry.$2, size: 15,
                                  color: appThemeNotifier.value == entry.$1 ? Colors.white : const Color(0xFF5F6368)),
                            ),
                          ),
                      ]),
                    ),
                  ]),
                ),
              ]),
            );
          }),
        ),
      ),
      ),
    ]));
    Overlay.of(context).insert(_moreOverlay!);
  }

  void _closeMoreOverlay() {
    _moreOverlay?.remove();
    _moreOverlay = null;
    _moreOpen = false;
    if (mounted) setState(() {});
  }

  void _toggleThemeOverlay(BuildContext context) {
    if (_themeOpen) { _closeThemeOverlay(); } else { _openThemeOverlay(context); }
  }

  void _openThemeOverlay(BuildContext context) {
    _themeOverlay?.remove();
    _themeOpen = true;
    if (mounted) setState(() {});

    _themeOverlay = OverlayEntry(builder: (_) => Stack(fit: StackFit.expand, children: [
      SizedBox.expand(child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _closeThemeOverlay)),
      UnconstrainedBox(child: CompositedTransformFollower(
        link: _themeLayerLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomRight,
        followerAnchor: Alignment.topRight,
        offset: const Offset(0, 4),
        child: Material(
          color: Colors.transparent,
          child: StatefulBuilder(builder: (_, setLocal) {
            final bool tdm = _isDark;
            return Container(
              width: 180,
              decoration: BoxDecoration(
                color: tdm ? const Color(0xFF2C2C2C) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 16, offset: const Offset(0, 4))],
                border: Border.all(color: tdm ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade200),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: Row(children: [
                    Icon(Icons.brightness_6_rounded, size: 14, color: tdm ? Colors.white54 : const Color(0xFF5F6368)),
                    const SizedBox(width: 6),
                    Text('Vzhled', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: tdm ? Colors.white : const Color(0xFF1F1F1F))),
                  ]),
                ),
                const Divider(height: 1, thickness: 0.5),
                for (final entry in [
                  (0, Icons.brightness_auto_rounded, 'Systémový'),
                  (1, Icons.light_mode_rounded, 'Světlý'),
                  (2, Icons.dark_mode_rounded, 'Tmavý'),
                ])
                  InkWell(
                    onTap: () {
                      appThemeNotifier.value = entry.$1; setState(() {});
                      SharedPreferences.getInstance().then((p) => p.setInt('theme_mode', appThemeNotifier.value));
                      setLocal(() {});
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(children: [
                        Icon(entry.$2, size: 16, color: appThemeNotifier.value == entry.$1 ? const Color(0xFF1A73E8) : (tdm ? Colors.white54 : const Color(0xFF5F6368))),
                        const SizedBox(width: 10),
                        Expanded(child: Text(entry.$3, style: TextStyle(fontSize: 13,
                            fontWeight: appThemeNotifier.value == entry.$1 ? FontWeight.w700 : FontWeight.w500,
                            color: appThemeNotifier.value == entry.$1 ? const Color(0xFF1A73E8) : (tdm ? Colors.white70 : Colors.black87)))),
                        if (appThemeNotifier.value == entry.$1) const Icon(Icons.check_rounded, size: 16, color: Color(0xFF1A73E8)),
                      ]),
                    ),
                  ),
                const SizedBox(height: 4),
                const Divider(height: 1, thickness: 0.5),
                InkWell(
                  onTap: () {
                    setState(() => _pdfInvert = !_pdfInvert);
                    setLocal(() {});
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(children: [
                      Icon(Icons.invert_colors_rounded, size: 16,
                          color: _pdfInvert ? const Color(0xFF1A73E8) : (tdm ? Colors.white54 : const Color(0xFF5F6368))),
                      const SizedBox(width: 10),
                      Expanded(child: Text('Invertovat PDF', style: TextStyle(fontSize: 13,
                          fontWeight: _pdfInvert ? FontWeight.w700 : FontWeight.w500,
                          color: _pdfInvert ? const Color(0xFF1A73E8) : (tdm ? Colors.white70 : Colors.black87)))),
                      if (_pdfInvert) const Icon(Icons.check_rounded, size: 16, color: Color(0xFF1A73E8)),
                    ]),
                  ),
                ),
                const SizedBox(height: 4),
              ]),
            );
          }),
        ),
      ),
      ),
    ]));
    Overlay.of(context).insert(_themeOverlay!);
  }

  void _closeThemeOverlay() {
    _themeOverlay?.remove();
    _themeOverlay = null;
    _themeOpen = false;
    if (mounted) setState(() {});
  }

  void _toggleParametryOverlay(BuildContext context) {
    if (_parametryOpen) { _closeParametryOverlay(); } else { _openParametryOverlay(context); }
  }

  void _openParametryOverlay(BuildContext context) {
    _parametryOverlay?.remove();
    _parametryOpen = true;
    if (mounted) setState(() {});

    _parametryOverlay = OverlayEntry(builder: (ctx) {
      return Stack(fit: StackFit.expand, children: [
        SizedBox.expand(child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _closeParametryOverlay,
        )),
        UnconstrainedBox(child: CompositedTransformFollower(
          link: _parametryLayerLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(0, 4),
          child: Material(
            color: Colors.transparent,
            child: StatefulBuilder(builder: (_, setLocal) {
              final bool pdm = _isDark;
              void toggle(String v) {
                setState(() {
                  if (v == 'parentheses') _skipParentheses = !_skipParentheses;
                  else if (v == 'links') _skipLinks = !_skipLinks;
                  else if (v == 'pages') _skipPageNumbers = !_skipPageNumbers;
                  else if (v == 'superscripts') _skipSuperscripts = !_skipSuperscripts;
                  _pregeneratedAudioCache.clear();
                });
                SharedPreferences.getInstance().then((p) {
                  p.setBool('skip_links', _skipLinks);
                  p.setBool('skip_pages', _skipPageNumbers);
                  p.setBool('skip_parens', _skipParentheses);
                  p.setBool('skip_superscripts', _skipSuperscripts);
                });
                setLocal(() {});
              }

              Widget radioRow(String val, bool active, String label, Color dot) =>
                  InkWell(
                    onTap: () => toggle(val),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(children: [
                        Container(width: 3.5, height: 20, margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(color: active ? dot : Colors.grey.shade300, borderRadius: BorderRadius.circular(2))),
                        SizedBox(width: 20, height: 20,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 130),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: active ? dot : Colors.transparent,
                              border: Border.all(color: active ? dot : Colors.grey.shade400, width: 2),
                            ),
                            child: active ? const Icon(Icons.check_rounded, size: 12, color: Colors.white) : null,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(label, style: TextStyle(
                          fontSize: 12, fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                          color: active ? dot : (pdm ? Colors.white70 : Colors.black87),
                        )),
                      ]),
                    ),
                  );

              return Container(
                width: 210,
                decoration: BoxDecoration(
                  color: pdm ? const Color(0xFF2C2C2C) : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 16, offset: const Offset(0, 4))],
                  border: Border.all(color: pdm ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade200),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                    child: Row(children: [
                      Icon(Icons.tune_rounded, size: 13, color: pdm ? Colors.white54 : const Color(0xFF5F6368)),
                      const SizedBox(width: 6),
                      Text('Parametry', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: pdm ? Colors.white : const Color(0xFF1F1F1F))),
                    ]),
                  ),
                  const Divider(height: 1, thickness: 0.5),
                  radioRow('parentheses', _skipParentheses, 'Přeskočit závorky', Colors.purple.shade400),
                  radioRow('links', _skipLinks, 'Přeskočit odkazy', Colors.purple.shade400),
                  radioRow('pages', _skipPageNumbers, 'Přeskočit čísla stran', Colors.purple.shade400),
                  radioRow('superscripts', _skipSuperscripts, 'Přeskočit horní indexy', Colors.purple.shade400),
                  const SizedBox(height: 4),
                ]),
              );
            }),
          ),
        ),
        ),
      ]);
    });
    Overlay.of(context).insert(_parametryOverlay!);
  }

  void _closeParametryOverlay() {
    _parametryOverlay?.remove();
    _parametryOverlay = null;
    _parametryOpen = false;
    if (mounted) setState(() {});
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
      if (!_searchOpen && _keyboardFocusNode.canRequestFocus) _keyboardFocusNode.requestFocus();
    });

    return ValueListenableBuilder<int>(
      valueListenable: appThemeNotifier,
      builder: (context, themeVal, child) => Theme(
        data: _isDark
            ? ThemeData.dark(useMaterial3: true).copyWith(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A73E8), brightness: Brightness.dark))
            : ThemeData.light(useMaterial3: true).copyWith(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A73E8))),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowUp, control: true): () => _changeZoom(_zoomStep),
            const SingleActivator(LogicalKeyboardKey.arrowDown, control: true): () => _changeZoom(-_zoomStep),
            const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
              setState(() {
                _searchOpen = !_searchOpen;
                if (!_searchOpen) { _searchQuery = ''; _searchMatches.clear(); _searchMatchIndex = 0; }
              });
            },
          },
          child: Focus(
            focusNode: _keyboardFocusNode,
            child: Scaffold(
              backgroundColor: _isDark ? const Color(0xFF121212) : const Color(0xFFF8F9FA),
              appBar: (_needsModelSelection || _isFullscreen)
                  ? null
                  : PreferredSize(
                preferredSize: MediaQuery.of(context).size.width < 480
                    ? const Size.fromHeight(96)
                    : const Size.fromHeight(56),
                child: _buildAppBar(context),
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
                  padding: _isFullscreen ? EdgeInsets.zero : const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Column(
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: _isDark ? const Color(0xFF1E1E1E) : Colors.white,
                                borderRadius: _isFullscreen ? BorderRadius.zero : const BorderRadius.vertical(top: Radius.circular(16)),
                                border: _isFullscreen ? null : Border.all(color: _isDark ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade200),
                                boxShadow: _isFullscreen ? [] : [BoxShadow(color: Colors.black.withValues(alpha: _isDark ? 0.3 : 0.02), blurRadius: 12, offset: const Offset(0, 4))],
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
                                          style: TextStyle(color: _isDark ? Colors.white54 : Colors.grey, fontWeight: FontWeight.w600, fontSize: 13),
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 16),
                                        Container(
                                          width: 240, height: 4,
                                          decoration: BoxDecoration(color: _isDark ? const Color(0xFF3A3A3A) : Colors.grey.shade200, borderRadius: BorderRadius.circular(2)),
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
                                      child: NotificationListener<ScrollStartNotification>(
                                        onNotification: (n) {
                                          if (n.dragDetails != null && !_isUserScrolling && !_isProgrammaticScrolling) {
                                            setState(() { _isUserScrolling = true; });
                                          }
                                          return false;
                                        },
                                        child: ScrollablePositionedList.builder(
                                          itemScrollController: _itemScrollController,
                                          itemPositionsListener: _itemPositionsListener,
                                          padding: const EdgeInsets.only(top: 52),
                                          itemCount: _chunksMetadata.length,
                                          itemBuilder: (context, index) {
                                            final bool isCurrent = index == _currentChunkIndex;
                                            final bool isSelected = index == _selectedChunkIndex;
                                            final bool isPending = index == _pendingJumpIndex;
                                            final bool isSearchMatch = _searchMatches.isNotEmpty && _searchMatches.contains(index);
                                            final bool isActiveSearchMatch = _searchMatches.isNotEmpty && _searchMatchIndex < _searchMatches.length && _searchMatches[_searchMatchIndex] == index;
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
                                              bgColor = Colors.orange.withValues(alpha: 0.12);
                                              border = Border.all(color: Colors.orange.shade400, width: 2);
                                            } else if (_isBusy && isCurrent) {
                                              bgColor = Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3);
                                              border = Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5);
                                            } else if (isSelected) {
                                              bgColor = Colors.orange.withValues(alpha: 0.12);
                                              border = Border.all(color: Colors.orange.shade400, width: 1.5);
                                            } else if (isCurrent && !_isBusy) {
                                              border = Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4), width: 1);
                                            }

                                            final Widget textWidget = (_isBusy && isCurrent)
                                                ? RichText(text: TextSpan(
                                              style: TextStyle(fontSize: fontSize, height: 1.6, color: _isDark ? Colors.white70 : Colors.black87, fontWeight: fontWeight),
                                              children: _buildHighlightedWords(_chunksMetadata[index].text, context),
                                            ))
                                                : (isSearchMatch && _searchQuery.isNotEmpty)
                                                ? RichText(text: TextSpan(
                                              style: TextStyle(fontSize: fontSize, height: isHeading ? 1.3 : 1.6, fontWeight: fontWeight,
                                                  color: index < _currentChunkIndex ? (_isDark ? Colors.white24 : Colors.grey.shade400) : (_isDark ? Colors.white70 : Colors.black87)),
                                              children: _buildSearchHighlightedWords(_chunksMetadata[index].text, _searchQuery, isActiveSearchMatch),
                                            ))
                                                : Text(_chunksMetadata[index].text, style: TextStyle(
                                              fontSize: fontSize,
                                              height: isHeading ? 1.3 : 1.6,
                                              fontWeight: fontWeight,
                                              color: index < _currentChunkIndex
                                                  ? (isHeading ? Colors.grey.shade500 : (_isDark ? Colors.white30 : Colors.grey.shade400))
                                                  : (isHeading ? (_isDark ? Colors.white : Colors.black) : (_isDark ? Colors.white70 : Colors.black87)),
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
                                                              : lvl == 2 ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.6)
                                                              : Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
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
                            if (_searchOpen)
                              Positioned(
                                top: _isFullscreen ? 16 : 8,
                                right: _isFullscreen ? 60 : 8,
                                width: 220,
                                child: _SearchBar(
                                  key: const ValueKey('search_bar'),
                                  isDark: _isDark,
                                  initialQuery: _searchQuery,
                                  matchCount: _searchMatches.length,
                                  activeIndex: _searchMatchIndex,
                                  onQueryChanged: (q) {
                                    _searchQuery = q;
                                    _searchMatches.clear();
                                    _searchMatchIndex = 0;
                                    if (q.isNotEmpty) {
                                      for (int i = 0; i < _chunksMetadata.length; i++) {
                                        if (_chunksMetadata[i].text.toLowerCase().contains(q)) _searchMatches.add(i);
                                      }
                                      if (_searchMatches.isNotEmpty) _scrollToCurrentChunk(_searchMatches[0], force: true);
                                    }
                                    setState(() {});
                                  },
                                  onPrev: () => setState(() {
                                    if (_searchMatches.isEmpty) return;
                                    _searchMatchIndex = (_searchMatchIndex - 1 + _searchMatches.length) % _searchMatches.length;
                                    _scrollToCurrentChunk(_searchMatches[_searchMatchIndex], force: true);
                                  }),
                                  onNext: () => setState(() {
                                    if (_searchMatches.isEmpty) return;
                                    _searchMatchIndex = (_searchMatchIndex + 1) % _searchMatches.length;
                                    _scrollToCurrentChunk(_searchMatches[_searchMatchIndex], force: true);
                                  }),
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
                                  decoration: BoxDecoration(color: (_isDark ? Colors.black.withValues(alpha: 0.7) : Colors.white.withValues(alpha: 0.9)), shape: BoxShape.circle),
                                  child: IconButton(
                                    icon: Icon(Icons.fullscreen_exit_rounded, color: _isDark ? Colors.white : Colors.black87),
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
                                    Container(
                                      decoration: BoxDecoration(
                                        color: _isDark ? const Color(0xFF2C2C2C) : Colors.white,
                                        borderRadius: BorderRadius.circular(28),
                                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 12, offset: const Offset(0, 3))],
                                      ),
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                                        IconButton(
                                          icon: Icon(Icons.replay_10_rounded, size: 26, color: _isDark ? Colors.white70 : Colors.black87),
                                          onPressed: _isBusy ? () => _seekRelative(-10) : null,
                                          padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            _isBusy ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                            size: 28, color: _isDark ? Colors.white70 : Colors.black87,
                                          ),
                                          onPressed: _isReady ? (_isBusy ? _stopPdfReading : _startPdfReading) : null,
                                          padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                        ),
                                        IconButton(
                                          icon: Icon(Icons.forward_10_rounded, size: 26, color: _isDark ? Colors.white70 : Colors.black87),
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
                      if (!_isParsingPdf && !_isFullscreen)
                        Container(
                          decoration: BoxDecoration(
                            color: _isDark ? const Color(0xFF1E1E1E) : Colors.white,
                            border: Border(top: BorderSide(color: _isDark ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade200, width: 1)),
                            borderRadius: _isFullscreen ? BorderRadius.zero : const BorderRadius.vertical(bottom: Radius.circular(16)),
                          ),
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                          child: AudioPlayerBar(
                            isReady: _isReady,
                            isBusy: _isBusy,
                            isCompleted: isCompleted,
                            showJumpButton: showJumpButton,
                            progress: progress,
                            volume: _volume,
                            playbackSpeed: _playbackSpeed,
                            speedOpen: _speedOpen,
                            currentChunkIndex: _currentChunkIndex,
                            totalChunks: _chunksMetadata.length,
                            currentPdfPage: globalCurrentPdfPage,
                            totalPdfPages: globalTotalPdfPages,
                            isPdfLayout: globalIsOriginalLayout,
                            isTxtFile: _isTxtFile,
                            etaRead: _etaString(0, _currentChunkIndex, _playbackSpeed),
                            etaLeft: _etaString(_currentChunkIndex, _chunksMetadata.length, _playbackSpeed),
                            onPlay: _startPdfReading,
                            onPause: _stopPdfReading,
                            onRestart: _restartAudioFromBeginning,
                            onJump: _jumpToSelectedAndPlay,
                            onSeekBack: () => _seekRelative(-10),
                            onSeekForward: () => _seekRelative(10),
                            onMute: _toggleMute,
                            onVolumeChanged: _changeVolume,
                            speedLayerLink: _speedLayerLink,
                            onSpeedTap: _toggleSpeedOverlay,
                            isDark: _isDark,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}