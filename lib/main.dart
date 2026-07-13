import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'blink_detector.dart';

late List<CameraDescription> _cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _cameras = await availableCameras();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TMC Dry Eye',
      theme: ThemeData(
        primarySwatch: Colors.teal,
        scaffoldBackgroundColor: const Color(0xFF0f172a),
        fontFamily: 'Inter',
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white),
        ),
      ),
      home: const CameraScreen(),
    );
  }
}

enum AppState { start, testing, results }

class CameraScreen extends StatefulWidget {
  const CameraScreen({Key? key}) : super(key: key);

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  bool _isProcessing = false;
  
  late final FaceDetector _faceDetector;
  final BlinkDetector _blinkDetector = BlinkDetector();
  
  AppState _currentState = AppState.start;
  int _timeLeft = 15;
  Timer? _timer;
  
  @override
  void initState() {
    super.initState();
    
    final options = FaceDetectorOptions(
      enableContours: false, // We no longer need manual contours!
      enableClassification: true, // Native Blink AI
    );
    _faceDetector = FaceDetector(options: options);
    
    _initializeCamera();
  }
  
  Future<void> _initializeCamera() async {
    final frontCamera = _cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => _cameras.first,
    );
    
    _controller = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
    );
    
    await _controller!.initialize();
    
    if (mounted) {
      setState(() {});
      _controller!.startImageStream(_processCameraImage);
    }
  }

  void _startTest() {
    setState(() {
      _currentState = AppState.testing;
      _timeLeft = 15;
    });
    
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_timeLeft > 0) {
          _timeLeft--;
        } else {
          _timer?.cancel();
          _currentState = AppState.results;
        }
      });
    });
  }

  void _resetTest() {
    _blinkDetector.reset();
    setState(() {
      _currentState = AppState.start;
    });
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessing || _currentState != AppState.testing) return;
    _isProcessing = true;

    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final Size imageSize = Size(image.width.toDouble(), image.height.toDouble());
      
      final camera = _controller!.description;
      final imageRotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
      if (imageRotation == null) return;

      final inputImageFormat = InputImageFormatValue.fromRawValue(image.format.raw);
      if (inputImageFormat == null) return;

      final metadata = InputImageMetadata(
        size: imageSize,
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: image.planes[0].bytesPerRow,
      );

      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        metadata: metadata,
      );

      final faces = await _faceDetector.processImage(inputImage);
      
      if (faces.isNotEmpty && _currentState == AppState.testing) {
        _blinkDetector.processFace(faces.first, image.height);
        if (mounted) {
          setState(() {}); 
        }
      }
    } catch (e) {
      print("Error processing frame: $e");
    } finally {
      _isProcessing = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  Widget _buildStartScreen() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text("TMC Dry Eye", style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 10),
          const Text("Version 2.0", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF10b981))),
          const SizedBox(height: 30),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              "Read the daily eye health tip while we analyze your natural blink rate.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Color(0xFF94a3b8)),
            ),
          ),
          const SizedBox(height: 50),
          ElevatedButton(
            onPressed: _startTest,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10b981),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
            ),
            child: const Text("Start Test", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildTestingScreen() {
    return Column(
      children: [
        // Top: 4:3 Camera Viewport
        Container(
          width: double.infinity,
          color: Colors.black,
          child: AspectRatio(
            aspectRatio: 4 / 3, // Matches the web app landscape video
            child: ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller!.value.previewSize!.height,
                  height: _controller!.value.previewSize!.width,
                  child: CameraPreview(_controller!),
                ),
              ),
            ),
          ),
        ),
        
        // Debug Text over Camera
        if (_blinkDetector.debugText.isNotEmpty)
          Container(
            width: double.infinity,
            color: const Color(0xFF1e293b),
            padding: const EdgeInsets.all(8),
            child: Text(
              _blinkDetector.debugText.replaceAll('\n', ' - '),
              style: const TextStyle(color: Color(0xFF10b981), fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),

        // Middle: Tip and Timer
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("DAILY EYE HEALTH TIP", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF10b981))),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1e293b),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text("${_timeLeft}s", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                    ),
                  ],
                ),
                const SizedBox(height: 30),
                const Text(
                  "Remember to take a 20-second break every 20 minutes and look at something 20 feet away to reduce eye strain.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, height: 1.5),
                ),
                const Spacer(),
                const Text("(Please read naturally...)", style: TextStyle(fontSize: 14, color: Color(0xFF64748b), fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        ),

        // Bottom: Live Stats
        Container(
          width: double.infinity,
          color: const Color(0xFF1e293b),
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 30),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("LIVE BLINKS", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF10b981))),
                  const SizedBox(height: 5),
                  Text("Half Blinks: ${_blinkDetector.halfBlinkCount}", style: const TextStyle(fontSize: 12, color: Color(0xFF94a3b8))),
                ],
              ),
              Text("${_blinkDetector.fullBlinkCount}", style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildResultsScreen() {
    int totalBlinks = _blinkDetector.fullBlinkCount;
    int estimatedRate = totalBlinks * 4; // 15 seconds * 4 = 1 minute
    bool isNormal = estimatedRate >= 10;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text("Test Complete", style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
            const SizedBox(height: 40),
            
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: const Color(0xFF1e293b),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Column(
                children: [
                  const Text("Total Blinks", style: TextStyle(fontSize: 16, color: Color(0xFF94a3b8))),
                  const SizedBox(height: 10),
                  Text("$totalBlinks", style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white)),
                ],
              ),
            ),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.only(bottom: 30),
              decoration: BoxDecoration(
                color: const Color(0xFF1e293b),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Column(
                children: [
                  const Text("Estimated Rate", style: TextStyle(fontSize: 16, color: Color(0xFF94a3b8))),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text("$estimatedRate", style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white)),
                      const SizedBox(width: 8),
                      const Text("blinks/min", style: TextStyle(fontSize: 16, color: Color(0xFF94a3b8))),
                    ],
                  ),
                ],
              ),
            ),

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: isNormal ? const Color(0xFF10b981).withOpacity(0.2) : Colors.amber.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: isNormal ? const Color(0xFF10b981) : Colors.amber),
              ),
              child: Text(
                isNormal ? "Normal" : "Possible Dry Eye",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isNormal ? const Color(0xFF10b981) : Colors.amber,
                ),
              ),
            ),

            const SizedBox(height: 50),
            
            ElevatedButton(
              onPressed: _resetTest,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3b82f6),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              ),
              child: const Text("Test Again", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    
    return Scaffold(
      body: SafeArea(
        child: _currentState == AppState.start
            ? _buildStartScreen()
            : _currentState == AppState.testing
                ? _buildTestingScreen()
                : _buildResultsScreen(),
      ),
    );
  }
}
