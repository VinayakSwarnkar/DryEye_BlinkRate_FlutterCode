import 'dart:ui';
import 'dart:math';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class EarData {
  final double prob;
  final int timestamp;
  EarData(this.prob, this.timestamp);
}

class BlinkDetector {
  // Relative Multipliers for Dynamic Baseline
  static const double FULL_BLINK_MULTIPLIER = 0.30; // 30% of baseline = full blink
  static const double HALF_BLINK_MULTIPLIER = 0.70; // 70% of baseline = half blink
  
  static const double VELOCITY_START_THRESH = -0.05; // Probability dropping fast
  static const double VELOCITY_OPEN_THRESH = 0.01;   // Probability increasing
  
  List<EarData> history = [];
  List<EarData> baselineHistory = []; // Continuous 5-second rolling window
  
  int valleyState = 0; // 0=OPEN, 1=CLOSING, 2=OPENING
  int fullBlinkCount = 0;
  int halfBlinkCount = 0;
  double minProbInCurrentBlink = 1.0;

  double baselineSmoothedProb = -1.0; // Heavily smoothed (70% history) for baseline
  double triggerSmoothedProb = -1.0;  // Lightly smoothed (20% history) for state machine
  double baselineProb = 0.85; // Dynamically adjusts based on baselineHistory
  
  String debugText = "Looking for eyes...";

  void reset() {
    history.clear();
    baselineHistory.clear();
    valleyState = 0;
    fullBlinkCount = 0;
    halfBlinkCount = 0;
    minProbInCurrentBlink = 1.0;
    baselineSmoothedProb = -1.0;
    triggerSmoothedProb = -1.0;
    baselineProb = 0.85;
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
    
    double rawProb = (face.leftEyeOpenProbability! + face.rightEyeOpenProbability!) / 2.0;

    // 4. Safety Box (Y bounds) using simple face bounding box
    double faceCenterY = face.boundingBox.center.dy;
    double normalizedY = faceCenterY / imageHeight;
    
    if (normalizedY < 0.15 || normalizedY > 0.85) {
      valleyState = 0;
      debugText = "OUT OF BOUNDS (Y: ${normalizedY.toStringAsFixed(2)})";
      return;
    }
    
    // 5. Dual-Track Algorithmic Noise Reduction
    if (baselineSmoothedProb < 0) {
      baselineSmoothedProb = rawProb;
      triggerSmoothedProb = rawProb;
    } else {
      baselineSmoothedProb = (baselineSmoothedProb * 0.7) + (rawProb * 0.3); // Track A (Baseline): 70% history
      triggerSmoothedProb = (triggerSmoothedProb * 0.2) + (rawProb * 0.8); // Track B (Trigger): 20% history
    }

    // 6. Continuous 5-Second Rolling Baseline (Uses heavily smoothed Track A)
    baselineHistory.add(EarData(baselineSmoothedProb, nowMs));
    baselineHistory.removeWhere((data) => nowMs - data.timestamp > 5000); // Keep exactly 5 seconds
    
    if (baselineHistory.isNotEmpty) {
      List<double> sortedProbs = baselineHistory.map((e) => e.prob).toList();
      sortedProbs.sort();
      // Take the 90th percentile to ignore brief upward noise spikes and downward blinks
      int percentileIndex = (sortedProbs.length * 0.90).floor();
      // Safeguard array bounds
      if (percentileIndex >= sortedProbs.length) percentileIndex = sortedProbs.length - 1;
      
      double currentPeak = sortedProbs[percentileIndex];
      // Prevent baseline from collapsing to 0 if the user keeps their eyes closed for >5s
      if (currentPeak > 0.15) {
        baselineProb = currentPeak;
      }
    }
    
    // 7. Time-based Velocity tracking (Uses lightly smoothed Track B)
    history.add(EarData(triggerSmoothedProb, nowMs));
    
    // Keep velocity history strictly within a ~150ms window
    history.removeWhere((data) => nowMs - data.timestamp > 150);
    
    double velocity = 0.0;
    if (history.length >= 2) {
      EarData oldest = history.first;
      double dt = (nowMs - oldest.timestamp) / 100.0; // Units of 100 ms
      if (dt > 0.0) {
        velocity = (triggerSmoothedProb - oldest.prob) / dt;
      }
    }
    
    // 8. Valley Detection State Machine (Uses lightly smoothed Track B)
    if (valleyState == 0) { // OPEN
      if (velocity < VELOCITY_START_THRESH && triggerSmoothedProb < (baselineProb * 0.95)) {
        valleyState = 1; // CLOSING
        minProbInCurrentBlink = triggerSmoothedProb;
      }
    } else if (valleyState == 1) { // CLOSING
      if (triggerSmoothedProb < minProbInCurrentBlink) {
        minProbInCurrentBlink = triggerSmoothedProb;
      }
      if (velocity > VELOCITY_OPEN_THRESH && triggerSmoothedProb > minProbInCurrentBlink + 0.05) {
        valleyState = 2; // OPENING
      }
    } else if (valleyState == 2) { // OPENING
      if (triggerSmoothedProb > (baselineProb * 0.90) || velocity <= 0) {
        if (minProbInCurrentBlink <= (baselineProb * FULL_BLINK_MULTIPLIER)) {
          fullBlinkCount++;
        } else if (minProbInCurrentBlink <= (baselineProb * HALF_BLINK_MULTIPLIER)) {
          halfBlinkCount++;
        }
        valleyState = 0; // Reset
      }
    }
    
    String stateStr = valleyState == 0 ? "OPEN" : (valleyState == 1 ? "CLOSING" : "OPENING");
    debugText = "Eye: ${(triggerSmoothedProb * 100).toStringAsFixed(1)}% | Base: ${(baselineProb * 100).toStringAsFixed(1)}% | Vel: ${velocity.toStringAsFixed(2)}\nState: $stateStr";
  }
}
