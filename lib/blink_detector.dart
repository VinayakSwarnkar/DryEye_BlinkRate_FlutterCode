import 'dart:ui';
import 'dart:math';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class EarData {
  final double prob;
  final int timestamp;
  EarData(this.prob, this.timestamp);
}

class BlinkDetector {
  // Since ML Kit natively outputs probability from 0.0 to 1.0, 
  // we can use standard thresholds without manual calibration.
  static const double FULL_BLINK_THRESH = 0.30; // < 30% open = full blink
  static const double HALF_BLINK_THRESH = 0.70; // < 70% open = half blink
  
  static const double VELOCITY_START_THRESH = -0.05; // Probability dropping fast
  static const double VELOCITY_OPEN_THRESH = 0.01;   // Probability increasing
  
  List<EarData> history = [];
  
  int valleyState = 0; // 0=OPEN, 1=CLOSING, 2=OPENING
  int fullBlinkCount = 0;
  int halfBlinkCount = 0;
  double minProbInCurrentBlink = 1.0;
  
  String debugText = "Looking for eyes...";

  void reset() {
    history.clear();
    valleyState = 0;
    fullBlinkCount = 0;
    halfBlinkCount = 0;
    minProbInCurrentBlink = 1.0;
    debugText = "Looking for eyes...";
  }

  Offset? lastFaceCenter;
  int lastFaceTimestamp = 0;

  void processFace(Face face, int imageHeight) {
    // 1. Check head angles (Yaw and Pitch)
    if (face.headEulerAngleX != null && face.headEulerAngleY != null) {
      if (face.headEulerAngleX!.abs() > 30 || face.headEulerAngleY!.abs() > 30) {
         valleyState = 0;
         debugText = "Head Turned Too Far!";
         return;
      }
    }

    // 2. Check Face Movement (Motion Blur / Phone Shaking)
    int nowMs = DateTime.now().millisecondsSinceEpoch;
    Offset currentCenter = face.boundingBox.center;
    
    if (lastFaceCenter != null) {
      double dt = (nowMs - lastFaceTimestamp) / 100.0;
      if (dt > 0.0) {
        double dx = currentCenter.dx - lastFaceCenter!.dx;
        double dy = currentCenter.dy - lastFaceCenter!.dy;
        double distanceMoved = sqrt(dx*dx + dy*dy);
        
        double faceWidth = face.boundingBox.width;
        // If face moves more than 5% of its own width per 100ms, it's motion blur.
        double speed = distanceMoved / dt;
        if (speed > faceWidth * 0.05) { 
           valleyState = 0; // Abort any blink in progress
           debugText = "Motion Detected!";
           lastFaceCenter = currentCenter;
           lastFaceTimestamp = nowMs;
           return;
        }
      }
    }
    lastFaceCenter = currentCenter;
    lastFaceTimestamp = nowMs;

    // 3. Get Google's built-in AI Blink Probability!
    if (face.leftEyeOpenProbability == null || face.rightEyeOpenProbability == null) {
      debugText = "Waiting for Eye AI...";
      return;
    }
    
    double displayProb = (face.leftEyeOpenProbability! + face.rightEyeOpenProbability!) / 2.0;

    // 4. Safety Box (Y bounds) using simple face bounding box
    double faceCenterY = face.boundingBox.center.dy;
    double normalizedY = faceCenterY / imageHeight;
    
    if (normalizedY < 0.15 || normalizedY > 0.85) {
      valleyState = 0;
      debugText = "OUT OF BOUNDS (Y: ${normalizedY.toStringAsFixed(2)})";
      return;
    }
    
    // 5. Time-based Velocity tracking (Framerate Independent)
    history.add(EarData(displayProb, nowMs));
    
    // Keep history strictly within a ~150ms window
    history.removeWhere((data) => nowMs - data.timestamp > 150);
    
    double velocity = 0.0;
    if (history.length >= 2) {
      EarData oldest = history.first;
      double dt = (nowMs - oldest.timestamp) / 100.0; // Units of 100 ms
      if (dt > 0.0) {
        velocity = (displayProb - oldest.prob) / dt;
      }
    }
    
    // 4. Valley Detection State Machine
    if (valleyState == 0) { // OPEN
      if (velocity < VELOCITY_START_THRESH && displayProb < 0.85) {
        valleyState = 1; // CLOSING
        minProbInCurrentBlink = displayProb;
      }
    } else if (valleyState == 1) { // CLOSING
      if (displayProb < minProbInCurrentBlink) {
        minProbInCurrentBlink = displayProb;
      }
      if (velocity > VELOCITY_OPEN_THRESH && displayProb > minProbInCurrentBlink + 0.05) {
        valleyState = 2; // OPENING
      }
    } else if (valleyState == 2) { // OPENING
      if (displayProb > 0.80 || velocity <= 0) {
        if (minProbInCurrentBlink <= FULL_BLINK_THRESH) {
          fullBlinkCount++;
        } else if (minProbInCurrentBlink <= HALF_BLINK_THRESH) {
          halfBlinkCount++;
        }
        valleyState = 0; // Reset
      }
    }
    
    String stateStr = valleyState == 0 ? "OPEN" : (valleyState == 1 ? "CLOSING" : "OPENING");
    debugText = "Eye Prob: ${(displayProb * 100).toStringAsFixed(1)}% | Vel: ${velocity.toStringAsFixed(2)}\nState: $stateStr";
  }
}
