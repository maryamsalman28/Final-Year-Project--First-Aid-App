import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // MethodChannel
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'burn_ar_image_guide.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BurnApp());
}

class BurnApp extends StatelessWidget {
  const BurnApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'First Aid Assistant',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class _Preprocessed {
  final Uint8List bytes;    // not used by native, but handy for debug
  final String debugPath;   // path we pass to native
  const _Preprocessed(this.bytes, this.debugPath);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();
  static const MethodChannel _infer = MethodChannel('burn_infer');

  File? _imageFile;
  String? _prediction;
  String? _qualityMessage;
  String? _error;
  bool _isRunning = false;

  static const int inputW = 224, inputH = 224;

  Future<void> _pickImage(ImageSource source) async {
    if (_isRunning) return;
    setState(() {
      _error = null;
      _prediction = null;
      _qualityMessage = null;
      _imageFile = null;
    });

    final XFile? xfile = await _picker.pickImage(source: source, imageQuality: 95);
    if (xfile == null) return;

    final file = File(xfile.path);
    setState(() => _imageFile = file);

    final qualityMsg = await _checkImageQuality(file);
    if (qualityMsg != null) {
      setState(() => _qualityMessage = qualityMsg);
      return;
    }

    await _runPrediction(file);
  }

  Future<String?> _checkImageQuality(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return "Could not read the image. Please try another photo.";

      if (decoded.width < 200 || decoded.height < 200) {
        return "Image is too small. Please retake closer to the injury.";
      }

      final double avg = _averageLuminance(decoded);
      if (avg < 60) return "Image is too dark. Use better lighting.";
      if (avg > 200) return "Image is overexposed. Reduce brightness.";

      final double blurVar = _laplacianVariance(decoded, target: 128);
      if (blurVar < 80) return "Image looks blurry. Hold steady and refocus.";

      return null;
    } catch (e) {
      return "Image quality check failed. ($e)";
    }
  }

  double _averageLuminance(img.Image im) {
    final w = im.width, h = im.height;
    final stepX = math.max(1, w ~/ 256);
    final stepY = math.max(1, h ~/ 256);
    var count = 0;
    var sum = 0.0;
    for (int y = 0; y < h; y += stepY) {
      for (int x = 0; x < w; x += stepX) {
        final p = im.getPixel(x, y);
        final r = img.getRed(p).toDouble();
        final g = img.getGreen(p).toDouble();
        final b = img.getBlue(p).toDouble();
        sum += 0.299 * r + 0.587 * g + 0.114 * b;
        count++;
      }
    }
    return sum / count;
  }

  double _laplacianVariance(img.Image im, {int target = 128}) {
    final resized = img.copyResize(im, width: target, height: target, interpolation: img.Interpolation.average);
    const kernel = [
      [0, 1, 0],
      [1, -4, 1],
      [0, 1, 0],
    ];
    var sum = 0.0, sumSq = 0.0, count = 0;

    final gray = img.grayscale(resized);
    for (int y = 1; y < gray.height - 1; y++) {
      for (int x = 1; x < gray.width - 1; x++) {
        var v = 0.0;
        for (int ky = -1; ky <= 1; ky++) {
          for (int kx = -1; kx <= 1; kx++) {
            final p = gray.getPixel(x + kx, y + ky);
            v += img.getRed(p).toDouble() * kernel[ky + 1][kx + 1];
          }
        }
        sum += v;
        sumSq += v * v;
        count++;
      }
    }
    final mean = sum / count;
    return ((sumSq / count) - (mean * mean)).abs();
  }

  Future<_Preprocessed> _preprocessJpeg(File file) async {
    final raw = await file.readAsBytes();
    final decoded = img.decodeImage(raw)!;

    final crop = math.min(decoded.width, decoded.height);
    final x0 = (decoded.width - crop) ~/ 2;
    final y0 = (decoded.height - crop) ~/ 2;
    final cropped = img.copyCrop(decoded, x0, y0, crop, crop);

    final resized = img.copyResize(
      cropped,
      width: inputW,
      height: inputH,
      interpolation: img.Interpolation.average,
    );

    final jpeg = img.encodeJpg(resized, quality: 95);
    final dir = await getTemporaryDirectory();
    final outPath = "${dir.path}/inference_input.jpg";
    await File(outPath).writeAsBytes(jpeg, flush: true);

    return _Preprocessed(Uint8List.fromList(jpeg), outPath);
  }

  Future<void> _runPrediction(File file) async {
    if (_isRunning) return;
    try {
      setState(() { _isRunning = true; _error = null; _prediction = null; });

      // Preprocess to 224x224 and get a temp file path
      final pp = await _preprocessJpeg(file);

      // Ask native side to run inference on that path
      final label = await _infer.invokeMethod<String>('infer', {'path': pp.debugPath});
      setState(() => _prediction = (label ?? 'unknown'));
    } catch (e, st) {
      debugPrint("PREDICTION ERROR: $e\n$st");
      setState(() => _error = "Prediction failed: $e");
    } finally {
      setState(() => _isRunning = false);
    }
  }

  // Helper: decide if a label indicates a positive burn detection
  bool _isPositiveDetection(String? label) {
    if (label == null) return false;
    final l = label.toLowerCase();
    return l.contains('first') || l.contains('1st') ||
           l.contains('second') || l.contains('2nd') ||
           l.contains('third') || l.contains('3rd');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('First Aid Assistant')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            _imageFile == null ? _heroCard(theme) : _previewCard(theme),
            const SizedBox(height: 16),
            _actionButtons(theme),
            if (_qualityMessage != null) ...[
              const SizedBox(height: 16),
              _infoCard("Image Quality", _qualityMessage!, theme, isWarning: true),
            ],
            if (_prediction != null) ...[
              const SizedBox(height: 16),
              _resultCard(_prediction!, theme),

              // AR button only when a burn is detected
              if (_isPositiveDetection(_prediction) && _imageFile != null) ...[
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => BurnImageGuideScreen(
                          imageFile: _imageFile!,
                          label: _prediction!,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.view_in_ar),
                  label: const Text('Open AR Guide'),
                ),
              ],

              // Treatment steps only when a burn is detected
              if (_isPositiveDetection(_prediction)) ...[
                const SizedBox(height: 12),
                _treatmentCard(_prediction!, theme),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              _infoCard("Error", _error!, theme, isWarning: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _heroCard(ThemeData theme) => Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(Icons.healing, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                "Upload or capture a clear photo of the burn area.\n"
                "Ensure good lighting and focus for accurate results.",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );

  Widget _previewCard(ThemeData theme) => Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              if (_imageFile != null)
                Image.file(_imageFile!, height: 240, fit: BoxFit.cover),
              const SizedBox(height: 8),
              Text(
                _error != null
                    ? "Prediction failed"
                    : (_prediction == null ? "Analyzing…" : "Prediction complete"),
                style: theme.textTheme.labelLarge,
              )
            ],
          ),
        ),
      );

  Widget _actionButtons(ThemeData theme) => Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _pickImage(ImageSource.camera),
              icon: const Icon(Icons.camera_alt),
              label: const Text('Take Photo'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _pickImage(ImageSource.gallery),
              icon: const Icon(Icons.photo_library),
              label: const Text('Upload Image'),
            ),
          ),
        ],
      );

  Widget _resultCard(String label, ThemeData theme) => Card(
        elevation: 1,
        child: ListTile(
          leading: const Icon(Icons.assignment_turned_in),
          title: Text(
            label == 'Burn not detected' ? 'Burn not detected' : 'Detected: $label',
            style: theme.textTheme.titleMedium,
          ),
          subtitle: const Text("This is an AI-assisted estimate, not a diagnosis."),
        ),
      );

  Widget _treatmentCard(String label, ThemeData theme) {
    // Defensive guard: no instructions for non-burn results
    if (!_isPositiveDetection(label)) return const SizedBox.shrink();

    final l = label.toLowerCase();
    String txt;
    if (l.contains("1st") || l.contains("first")) {
      txt = "First-degree burn guidance:\n"
          "• Cool under running water for 10–15 minutes.\n"
          "• Apply soothing gel such as aloe vera.\n"
          "• Avoid ice or butter.\n"
          "• Usually heals in a few days.";
    } else if (l.contains("2nd") || l.contains("second")) {
      txt = "Second-degree burn guidance:\n"
          "• Cool gently with clean running water.\n"
          "• Do not burst blisters.\n"
          "• Cover loosely with a sterile, non-stick dressing.\n"
          "• Consider medical attention depending on size and location.";
    } else {
      // third-degree
      txt = "Third-degree burn guidance:\n"
          "• Call emergency services immediately.\n"
          "• Do not apply ointments.\n"
          "• Cover with a clean, dry cloth and keep warm.";
    }

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(txt, style: theme.textTheme.bodyMedium),
      ),
    );
  }

  Widget _infoCard(String title, String msg, ThemeData theme, {bool isWarning = false}) => Card(
        color: isWarning ? const Color(0xFFFFF2F2) : null,
        elevation: 0,
        child: ListTile(
          leading: Icon(
            isWarning ? Icons.warning_amber_rounded : Icons.info_outline,
            color: isWarning ? Colors.red : theme.colorScheme.primary,
          ),
          title: Text(title, style: theme.textTheme.titleSmall),
          subtitle: Text(msg),
          trailing: TextButton(
            onPressed: () {
              setState(() {
                _imageFile = null;
                _prediction = null;
                _qualityMessage = null;
                _error = null;
              });
            },
            child: const Text("Retry"),
          ),
        ),
      );
}
