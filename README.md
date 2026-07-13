# Blink Rate Detection (Flutter + Google ML Kit)

This repository contains the native iOS/Android mobile application for the **Dry Eye Disease Blink Rate Detection** project. It utilizes **Google ML Kit's Face Detection API** combined with custom 1st-derivative velocity mathematics to accurately track human blink rates in real-time.

## 🧠 Core Architecture & Methodology

Unlike traditional geometric distance measurements (Eye Aspect Ratio), this application relies on Google ML Kit's pre-trained neural network to output an `eyeOpenProbability` score (ranging from `0.0` fully closed to `1.0` fully open). 

By averaging the left and right eye probabilities, we generate a unified "Openness Curve" which is fed into our custom Signal Processing engine.

### 1. Framerate-Independent Velocity (1st Derivative)
To prevent slow spatial distortions (like turning your head) from being falsely registered as a blink, we calculate the **velocity** (the 1st derivative) of the eyelid closing speed over a sliding 150ms window.
* **Math:** `Velocity = Δ Probability / 100ms`
* This ensures consistent mathematical behavior regardless of whether the camera is running at 30 FPS, 60 FPS, or dropping frames due to thermal throttling.

### 2. The 3-State Valley Detection Machine
Blinks are registered by looking for steep "valleys" in the probability graph.
* **State 0 (OPEN):** Waits for the closing velocity to drop below `-0.05` per 100ms.
* **State 1 (CLOSING):** Tracks the eyelid all the way to the absolute bottom of the blink (the `valleyMin`).
* **State 2 (OPENING):** Waits for the opening velocity to level off. Once the eye is fully open, it evaluates the `valleyMin` to classify it as a **Full Blink** (< 30% open) or **Half Blink** (< 70% open).

### 3. Motion & Edge Rejection Safeguards
* **Motion Blur Protection:** If the user's face moves faster than 5% of its own width within 100ms, the tracker temporarily aborts to prevent false positives from camera shake.
* **Angle Limits:** Head turns (Yaw/Pitch) greater than 30° immediately pause tracking.
* **Edge Safety Box:** If the face drifts into the top 15% or bottom 15% of the camera frame, tracking pauses to avoid wide-angle lens distortion.

## 🚀 Getting Started

### Prerequisites
* [Flutter SDK](https://docs.flutter.dev/get-started/install) (latest stable)
* Xcode (for iOS deployment)

### Installation
1. Clone this repository.
2. Run `flutter pub get` to install the `google_mlkit_face_detection` dependency.
3. If building for iOS, navigate to the `ios` directory and run `pod install`.
4. Run `flutter run` or hit **Play** in your IDE to launch the app on a physical device (the simulator camera will not work for face detection).

---
*Developed as part of the TeleMedC Dry Eye diagnostic suite.*
