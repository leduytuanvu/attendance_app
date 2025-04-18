import 'dart:async';

import 'package:attendance_app/services/face_recognition_service.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'; // Import for WriteBuffer
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';

// Face angle tracking enum
enum FaceAngle { front, left, right, up, down }

class FaceScanScreen extends StatefulWidget {
  final bool isIdentifying;

  const FaceScanScreen({super.key, this.isIdentifying = false});

  @override
  State<FaceScanScreen> createState() => _FaceScanScreenState();
}

class _FaceScanScreenState extends State<FaceScanScreen> {
  List<CameraDescription>? cameras;
  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isDetecting = false;
  FaceDetector? _faceDetector;
  Timer? _detectionTimer;
  bool _faceDetected = false;
  int _detectionCount = 0;
  static const int _requiredDetections = 3; // Detections needed per angle
  final bool _showConfirmation = false;

  // Flag to track if we're in the process of navigating away
  bool _isNavigating = false;

  // Store the last detected face for face data generation
  Face? _lastDetectedFace;

  // For identification mode
  final TextEditingController _cccdController = TextEditingController();

  // Face angle tracking
  final Map<FaceAngle, bool> _angleDetected = {
    FaceAngle.front: false,
    FaceAngle.left: false,
    FaceAngle.right: false,
    FaceAngle.up: false,
    FaceAngle.down: false,
  };
  FaceAngle _currentRequestedAngle =
      FaceAngle.front; // Start with front angle for better user experience

  // Combined face data from multiple angles
  final List<String> _faceDataFromAngles = [];

  // List to store processed face data with embeddings
  final List<Map<String, dynamic>> _processedFaceData = [];

  // Track progress for UI feedback
  int _totalAnglesDetected = 0;
  int _totalRequiredAngles =
      5; // All 5 angles for registration, 3 for identification

  // Face recognition service
  final FaceRecognitionService _faceRecognitionService =
      FaceRecognitionService();

  @override
  void initState() {
    super.initState();
    _initializeCameraAndDetector();
  }

  @override
  void dispose() {
    // Cancel any timers first
    _detectionTimer?.cancel();

    // Close the face detector
    if (_faceDetector != null) {
      _faceDetector!.close();
      _faceDetector = null;
    }

    // Dispose of the camera controller safely
    if (_controller != null) {
      if (_controller!.value.isStreamingImages) {
        _controller!.stopImageStream().then((_) {
          _controller!.dispose();
        }).catchError((e) {
          print("Error stopping image stream: $e");
          _controller!.dispose();
        });
      } else {
        _controller!.dispose();
      }
      _controller = null;
    }

    super.dispose();
  }

  Future<void> _initializeCameraAndDetector() async {
    // 1. Request Camera Permission
    var cameraStatus = await Permission.camera.request();
    if (!cameraStatus.isGranted) {
      _showErrorDialog(
          'Camera permission denied. Please grant permission in settings.');
      return;
    }

    // 2. Initialize Face Detector
    final options = FaceDetectorOptions(
      enableContours: true, // Enable contours for better Asian face detection
      enableLandmarks: true, // Enable landmarks for better Asian face detection
      performanceMode: FaceDetectorMode
          .accurate, // Use accurate mode for better results with Asian faces
      minFaceSize: 0.15, // Detect faces that occupy at least 15% of the image
    );
    _faceDetector = FaceDetector(options: options);

    // 3. Initialize Camera
    try {
      cameras = await availableCameras();
      if (cameras == null || cameras!.isEmpty) {
        _showErrorDialog('No cameras available on this device.');
        return;
      }

      // Use the front camera if available
      CameraDescription frontCamera = cameras!.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras!.first, // Fallback to the first camera
      );

      print(
          "Using camera: ${frontCamera.name}, direction: ${frontCamera.lensDirection}");

      _controller = CameraController(
        frontCamera,
        ResolutionPreset.high, // Use higher resolution for better detection
        enableAudio: false, // Audio not needed
        imageFormatGroup: ImageFormatGroup
            .yuv420, // Use YUV420 format for better compatibility
      );

      await _controller!.initialize();
      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
      });

      print("Camera initialized successfully");

      // Start face detection periodically
      _startDetectionLoop();
    } catch (e) {
      print("Error initializing camera: $e");
      _showErrorDialog('Failed to initialize camera: ${e.toString()}');
    }
  }

  // Optimized detection loop with better performance and reduced freezing
  void _startDetectionLoop() {
    if (!_isCameraInitialized ||
        _controller == null ||
        !_controller!.value.isInitialized) {
      print("Camera not ready for detection loop.");
      return;
    }

    // Stop previous timer if exists
    _detectionTimer?.cancel();

    try {
      // Check if the camera is already streaming images
      if (_controller!.value.isStreamingImages) {
        print("Camera is already streaming images, not starting a new stream");
        return;
      }

      print("Starting optimized image stream for face detection");

      // Use a more efficient approach with throttling to prevent UI freezing
      int frameSkipCounter = 0;
      const int frameSkipThreshold =
          2; // Process every 3rd frame to reduce CPU load

      // Start the image stream only once
      _controller!.startImageStream((CameraImage image) async {
        // Skip frames to reduce processing load
        frameSkipCounter = (frameSkipCounter + 1) % (frameSkipThreshold + 1);
        if (frameSkipCounter != 0) return;

        // Prevent concurrent processing
        if (_isDetecting || !mounted || _isNavigating) return;

        // Set detecting flag without setState to reduce UI updates
        _isDetecting = true;

        try {
          final InputImage? inputImage = _inputImageFromCameraImage(image);
          if (inputImage == null) {
            print("Failed to create InputImage from camera image");
            if (mounted) {
              _isDetecting = false;
            }
            return;
          }

          // Process the image for faces
          final List<Face> faces =
              await _faceDetector!.processImage(inputImage);

          // Only update UI if mounted
          if (!mounted) {
            _isDetecting = false;
            return;
          }

          // Check if faces were found
          if (faces.isNotEmpty) {
            final face = faces.first;

            // Store the detected face for later use
            _lastDetectedFace = face;

            // Check if the face is at the correct angle
            bool isCorrectAngle =
                _isCorrectFaceAngle(face, _currentRequestedAngle);

            // Batch UI updates to reduce setState calls
            setState(() {
              _faceDetected = isCorrectAngle;

              if (isCorrectAngle) {
                // Increment detection count for the current angle
                _detectionCount++;

                // Check if we've reached the required detections
                bool thresholdReached = widget.isIdentifying
                    ? _detectionCount >= 2
                    : // Faster for check-in
                    _detectionCount >=
                        _requiredDetections; // More thorough for registration

                if (thresholdReached) {
                  // Mark this angle as detected
                  _angleDetected[_currentRequestedAngle] = true;

                  // For check-in mode with front angle, proceed immediately
                  if (widget.isIdentifying &&
                      _currentRequestedAngle == FaceAngle.front) {
                    // Schedule face data storage and confirmation
                    Future.delayed(const Duration(milliseconds: 300), () {
                      if (mounted && !_isNavigating) {
                        _storeFaceDataForAngle(face, _currentRequestedAngle)
                            .then((_) {
                          if (mounted && !_isNavigating) {
                            _confirmFaceDetection(skipConfirmation: true);

                            // Stop image stream
                            if (_controller != null &&
                                _controller!.value.isStreamingImages) {
                              _controller!.stopImageStream();
                            }
                          }
                        });
                      }
                    });
                  }
                  // For registration or other angles in check-in
                  else {
                    // Store face data for this angle
                    _storeFaceDataForAngle(face, _currentRequestedAngle);

                    // For registration mode, automatically move to next angle without confirmation
                    if (!widget.isIdentifying) {
                      _detectionCount = 0; // Reset for next angle
                      setState(() {
                        _totalAnglesDetected++;
                      });
                      _moveToNextAngle();
                    }
                  }
                }
              }

              // Always reset detection flag at the end
              _isDetecting = false;
            });
          } else {
            // No face detected in this frame
            if (mounted) {
              setState(() {
                _faceDetected = false;
                _isDetecting = false;
              });
            }
          }
        } catch (e) {
          print("Error during face detection: $e");
          if (mounted) {
            _isDetecting = false;
          }
        }
      });
    } catch (e) {
      print("Error starting image stream: $e");
      if (mounted) {
        setState(() {
          _isDetecting = false;
        });
        _showErrorDialog('Failed to start camera stream: ${e.toString()}');
      }
    }
  }

  Future<void> _stopDetectionAndCamera() async {
    _detectionTimer?.cancel();
    if (_controller != null && _controller!.value.isStreamingImages) {
      await _controller!.stopImageStream();
    }
    _isDetecting = false; // Ensure detection stops
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_controller == null || cameras == null || cameras!.isEmpty) return null;

    // Find the index of the current camera in the cameras list
    int cameraIndex = cameras!.indexOf(_controller!.description);
    if (cameraIndex < 0) {
      cameraIndex = 0; // Fallback to first camera if not found
    }

    final camera = cameras![cameraIndex];
    final sensorOrientation = camera.sensorOrientation;

    // Get rotation based on camera sensor orientation
    final cameraRotation =
        InputImageRotationValue.fromRawValue(sensorOrientation);
    if (cameraRotation == null) return null;

    // Handle different image formats
    if (image.format.group == ImageFormatGroup.bgra8888 &&
        image.planes.length == 1) {
      // For BGRA8888 format
      return InputImage.fromBytes(
        bytes: image.planes[0].bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: cameraRotation,
          format: InputImageFormat.bgra8888,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } else if (image.format.group == ImageFormatGroup.yuv420) {
      // For YUV420 format
      final bytes = _concatenatePlanes(image.planes);
      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: cameraRotation,
          format:
              InputImageFormat.nv21, // YUV420 is typically processed as NV21
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } else {
      print(
          'Unsupported image format: ${image.format.group} with ${image.planes.length} planes');
      return null;
    }
  }

  // Helper to concatenate planes for NV21 format if needed by the ML Kit input
  Uint8List _concatenatePlanes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (Plane plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  void _showErrorDialog(String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    ).then((_) {
      // Pop the face scan screen if an error occurred during init
      if (!_isCameraInitialized && mounted) {
        Navigator.pop(context, false); // Return false on error
      }
    });
  }

  // Check if the face is at the correct angle based on the requested angle
  bool _isCorrectFaceAngle(Face face, FaceAngle angle) {
    final top = face.boundingBox.top;
    final yAngle = face.headEulerAngleY ?? 0;
    final zAngle = face.headEulerAngleZ ?? 0;
    final xAngle = face.headEulerAngleX ?? 0; // Try to use X angle if available
    final height = face.boundingBox.height;
    final width = face.boundingBox.width;
    final aspectRatio = width / height;

    // Invert Y angle for front camera (fix left-right reversal)
    // Front camera is mirrored, so we need to invert the Y angle
    final adjustedYAngle = -yAngle; // Invert Y angle for front camera

    // Calculate additional metrics for up/down detection
    // Use multiple indicators for more reliable up/down detection

    // 1. Position of face in frame
    final normalizedTop = top / height; // Normalized position from top

    // 2. Face aspect ratio changes when looking up/down
    final faceAspectRatioChange =
        aspectRatio - 1.3; // Typical face aspect ratio is around 1.3

    // Combine multiple indicators for more reliable detection
    final isLookingUp = (zAngle < -5) || // Traditional angle detection
        (normalizedTop > 0.6) || // Position in frame
        (faceAspectRatioChange < -0.15); // Face gets taller when looking up

    // Make looking down detection more sensitive
    final isLookingDown = (zAngle >
            3) || // More sensitive angle detection (was 5)
        (normalizedTop < 0.35) || // More sensitive position threshold (was 0.3)
        (faceAspectRatioChange >
            0.1) || // More sensitive aspect ratio change (was 0.15)
        (xAngle > 8); // Also use X angle if available

    // Print detailed debug info for angle detection
    print(
        "[Face Angle Debug] Original Y: $yAngle, Adjusted Y: $adjustedYAngle, Z: $zAngle, X: $xAngle, "
        "Top: $top, NormalizedTop: $normalizedTop, Height: $height, Width: $width, "
        "AspectRatio: $aspectRatio, AspectRatioChange: $faceAspectRatioChange, "
        "isLookingUp: $isLookingUp, isLookingDown: $isLookingDown, "
        "CurrentRequestedAngle: $angle");

    // For identification mode, be a bit more lenient but still require correct positioning
    if (widget.isIdentifying) {
      // For identification, we mainly care about having a good frontal face
      if (angle == FaceAngle.front) {
        // Front face detection for identification
        return adjustedYAngle.abs() < 15 && zAngle.abs() < 15;
      }

      // For other angles in identification mode
      switch (angle) {
        case FaceAngle.front:
          // Already handled above
          return true;
        case FaceAngle.left:
          return adjustedYAngle > 20 &&
              adjustedYAngle < 60; // Must be clearly turned left
        case FaceAngle.right:
          return adjustedYAngle < -20 &&
              adjustedYAngle > -60; // Must be clearly turned right
        case FaceAngle.up:
          // More lenient for identification mode
          return isLookingUp || zAngle < -3 || normalizedTop > 0.55;
        case FaceAngle.down:
          // More lenient for identification mode
          return isLookingDown || zAngle > 3 || normalizedTop < 0.35;
      }
    }

    // For registration mode, be more strict to ensure quality face data
    switch (angle) {
      case FaceAngle.front:
        // Front face detection - must be looking directly at camera
        return adjustedYAngle.abs() < 12 && zAngle.abs() < 12;

      case FaceAngle.left:
        // Left angle detection - must be clearly turned left
        return adjustedYAngle > 25 && adjustedYAngle < 60;

      case FaceAngle.right:
        // Right angle detection - must be clearly turned right
        return adjustedYAngle < -25 && adjustedYAngle > -60;

      case FaceAngle.up:
        // Up angle detection - use multiple indicators with stricter thresholds for registration
        return isLookingUp ||
            (zAngle < -4 && normalizedTop > 0.5) || // Combined conditions
            (faceAspectRatioChange < -0.1 &&
                normalizedTop > 0.45); // Another combination

      case FaceAngle.down:
        // Down angle detection - use multiple indicators with more sensitive thresholds
        return isLookingDown ||
            (zAngle > 2 &&
                normalizedTop < 0.45) || // More sensitive combined conditions
            (faceAspectRatioChange > 0.05 &&
                normalizedTop < 0.5) || // More sensitive combination
            (xAngle > 5); // Also use X angle if available
    }

    // Default fallback (should never reach here)
    return false;
  }

  // Method to confirm face detection and return to previous screen
  Future<void> _confirmFaceDetection({bool skipConfirmation = false}) async {
    // Set the navigation flag to prevent further camera operations
    setState(() {
      _isNavigating = true;
    });

    try {
      // Safely stop detection and camera
      try {
        await _stopDetectionAndCamera();
      } catch (e) {
        print("Error stopping detection and camera: $e");
        // Continue even if there's an error stopping the camera
      }

      // Check if widget is still mounted before proceeding
      if (!mounted) return;

      // Prepare result data
      Map<String, dynamic> resultData = {
        'faceDetected': true,
        'success': true,
        'multiAngle': false,
        'faceData': _lastDetectedFace != null
            ? _generateFallbackFaceData(_lastDetectedFace!)
            : null
      };

      // Check if widget is still mounted before popping
      if (mounted) {
        try {
          // Ensure we're properly releasing camera resources before navigation
          if (_controller != null) {
            try {
              // First stop any streaming
              if (_controller!.value.isStreamingImages) {
                await _controller!.stopImageStream();
              }
              // Then dispose the controller
              await _controller!.dispose();
            } catch (e) {
              print("Error disposing camera controller: $e");
            } finally {
              // Always set controller to null to prevent further access attempts
              _controller = null;
            }
          }

          // Use a more robust navigation approach
          if (mounted) {
            // Use a direct approach with a try-catch
            try {
              print("Navigating back with result data");
              Navigator.of(context).pop(resultData);
            } catch (e) {
              print("Navigation failed: $e");

              // Try again with a post-frame callback
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  try {
                    Navigator.of(context).pop(resultData);
                  } catch (e2) {
                    print("Post-frame navigation failed: $e2");
                  }
                }
              });
            }
          }
        } catch (navError) {
          print("Navigation error in _confirmFaceDetection: $navError");
        }
      }
    } catch (e) {
      print("Error in _confirmFaceDetection: $e");
      // If there's an error, still try to return some result if mounted
      if (mounted) {
        try {
          // Ensure we're properly releasing camera resources before navigation
          if (_controller != null) {
            await _controller!.dispose();
            _controller = null;
          }

          // Use a safer navigation approach
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.of(context).pop({
                'faceDetected': true,
                'success': false,
                'error': e.toString(),
                'faceData': _lastDetectedFace != null
                    ? _generateFallbackFaceData(_lastDetectedFace!)
                    : null
              });
            }
          });
        } catch (navError) {
          print("Error during error handling navigation: $navError");
        }
      }
    }
  }

  // Get a single camera image for processing - optimized to reduce freezing
  Future<CameraImage?> _getCameraImage() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isNavigating) {
      print("Camera not initialized for image capture");
      return null;
    }

    // Use a completer to get a single frame from the camera
    final completer = Completer<CameraImage?>();

    // Set a shorter timeout to avoid hanging if no image is received
    final timeout = Timer(const Duration(milliseconds: 1500), () {
      if (!completer.isCompleted) {
        completer.complete(null);
        print("Camera image capture timed out");
      }
    });

    try {
      CameraImage? latestImage;
      bool wasStreaming = false;

      // Check if we're already streaming images
      if (_controller!.value.isStreamingImages) {
        wasStreaming = true;
        print("Camera is already streaming, using existing stream");

        // Temporarily pause detection to avoid conflicts
        _isDetecting = true;

        // Try to get an image from the existing stream with a timeout
        bool imageReceived = false;

        // Create a temporary listener for the existing stream
        // We'll use a variable outside the callback to track if we got an image
        try {
          // Wait a bit to see if we get an image from the existing stream
          await Future.delayed(const Duration(milliseconds: 200));

          // If we still don't have an image, try a different approach
          if (!imageReceived && _lastDetectedFace != null) {
            // We have a last detected face, so we can use that
            print("Using last detected face as fallback");
            if (!completer.isCompleted) {
              timeout.cancel();
              completer.complete(
                  null); // Return null but we'll use last detected face
            }
          } else {
            // Try a more careful approach to restart the stream
            try {
              // Safely stop the stream first
              print("Safely stopping existing stream");
              await _controller!.stopImageStream();

              // Small delay to ensure the stream is fully stopped
              await Future.delayed(const Duration(milliseconds: 100));

              // Start a new stream to get one frame
              print("Starting new temporary stream");
              if (!_controller!.value.isStreamingImages) {
                await _controller!.startImageStream((image) {
                  // Only take the first image
                  if (latestImage == null) {
                    latestImage = image;
                    imageReceived = true;

                    // Complete with the image
                    if (!completer.isCompleted) {
                      timeout.cancel();
                      completer.complete(image);
                    }
                  }
                });

                // Wait a short time to ensure we get at least one frame
                await Future.delayed(const Duration(milliseconds: 300));

                // Stop the temporary stream
                if (_controller!.value.isStreamingImages) {
                  await _controller!.stopImageStream();
                }
              }
            } catch (e) {
              print("Error in stream restart approach: $e");
              if (!completer.isCompleted) {
                completer.complete(null);
              }
            }
          }
        } catch (e) {
          print("Error in existing stream handling: $e");
          if (!completer.isCompleted) {
            completer.complete(null);
          }
        }
      } else {
        // If not streaming, start a new stream just to get one frame
        print("Starting new image stream for single frame");
        try {
          await _controller!.startImageStream((image) {
            // Only complete once
            if (latestImage == null) {
              latestImage = image;

              // Complete with the image
              if (!completer.isCompleted) {
                timeout.cancel();
                completer.complete(image);
              }
            }
          });

          // Wait a short time to ensure we get at least one frame
          await Future.delayed(const Duration(milliseconds: 300));

          // Stop the temporary stream
          if (_controller!.value.isStreamingImages) {
            await _controller!.stopImageStream();
          }
        } catch (e) {
          print("Error starting temporary stream: $e");
          if (!completer.isCompleted) {
            completer.complete(null);
          }
        }
      }

      // If we were streaming before, restart the detection loop
      if (wasStreaming) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted && _controller != null && !_isNavigating) {
            _isDetecting = false;
            // Only restart if controller is still valid and not already streaming
            if (_controller != null &&
                _controller!.value.isInitialized &&
                !_controller!.value.isStreamingImages) {
              _startDetectionLoop();
            }
          }
        });
      }

      // If we got an image, return it
      if (latestImage != null) {
        return latestImage;
      }
    } catch (e) {
      print("Error getting camera image: $e");
      if (!completer.isCompleted) {
        completer.complete(null);
      }

      // Make sure detection can continue
      if (mounted) {
        _isDetecting = false;
      }
    }

    // Return the captured image or null if we couldn't get one
    return completer.future;
  }

  // Generate face data using TensorFlow Lite model
  Future<Map<String, dynamic>> _generateFaceData(Face face) async {
    if (_controller == null || !_controller!.value.isInitialized) {
      print("Camera not initialized for face data generation");
      return {
        'success': false,
        'error': 'Camera not initialized',
        'fallbackData': _generateFallbackFaceData(face),
      };
    }

    try {
      // Get the current camera image
      final cameraImage = await _getCameraImage();
      if (cameraImage == null) {
        print("Failed to get camera image");
        return {
          'success': false,
          'error': 'Failed to get camera image',
          'fallbackData': _generateFallbackFaceData(face),
        };
      }

      // Process the image with TensorFlow Lite through the face recognition service
      final List<double>? embedding =
          await _faceRecognitionService.getFaceEmbedding(cameraImage, face);

      if (embedding == null) {
        print("Failed to generate face embedding");
        return {
          'success': false,
          'error': 'Failed to generate face embedding',
          'fallbackData': _generateFallbackFaceData(face),
        };
      }

      // Convert embedding to string for storage
      final embeddingString =
          _faceRecognitionService.embeddingToString(embedding);

      // Return success with embedding data
      return {
        'success': true,
        'embedding': embedding,
        'embeddingString': embeddingString,
        'faceId': 'face_${DateTime.now().millisecondsSinceEpoch}',
        'metadata': {
          'boundingBox': {
            'left': face.boundingBox.left,
            'top': face.boundingBox.top,
            'width': face.boundingBox.width,
            'height': face.boundingBox.height,
          },
          'headEulerAngleY': face.headEulerAngleY,
          'headEulerAngleZ': face.headEulerAngleZ,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'angle': _currentRequestedAngle.toString(),
        },
      };
    } catch (e) {
      print("Error generating face data: $e");
      return {
        'success': false,
        'error': e.toString(),
        'fallbackData': _generateFallbackFaceData(face),
      };
    }
  }

  // Generate fallback face data when TFLite processing fails
  String _generateFallbackFaceData(Face face) {
    return "face_${face.boundingBox.left.toStringAsFixed(2)}_"
        "${face.boundingBox.top.toStringAsFixed(2)}_"
        "${face.boundingBox.width.toStringAsFixed(2)}_"
        "${face.boundingBox.height.toStringAsFixed(2)}_"
        "${face.headEulerAngleY?.toStringAsFixed(2) ?? '0.00'}_"
        "${face.headEulerAngleZ?.toStringAsFixed(2) ?? '0.00'}_"
        "${DateTime.now().millisecondsSinceEpoch}";
  }

  // Store face data for the current angle
  Future<void> _storeFaceDataForAngle(Face face, FaceAngle angle) async {
    Map<String, dynamic> faceData = await _generateFaceData(face);

    // Add angle information to the face data
    faceData['angle'] = angle.toString();

    // Store the processed face data
    _processedFaceData.add(faceData);

    // For backward compatibility, also store string representation
    if (faceData['success']) {
      _faceDataFromAngles.add(faceData['embeddingString']);
    } else {
      _faceDataFromAngles.add(faceData['fallbackData']);
    }

    print(
        "Stored face data for angle: $angle - Success: ${faceData['success']}");
  }

  // Move to the next angle or complete if all angles are detected
  void _moveToNextAngle() {
    // For registration, require all 5 angles to be detected
    // For identification, 3 angles would be sufficient
    bool allRequiredAnglesDetected = true;

    // Set the required number of angles based on mode
    _totalRequiredAngles = widget.isIdentifying ? 3 : 5;

    // Check if all required angles are detected
    if (!widget.isIdentifying) {
      // For registration, require all angles including up and down
      for (var angle in FaceAngle.values) {
        if (!_angleDetected[angle]!) {
          allRequiredAnglesDetected = false;
          break;
        }
      }
    } else {
      // For identification, at least 3 angles are sufficient
      int detectedAnglesCount = 0;
      for (var detected in _angleDetected.values) {
        if (detected) detectedAnglesCount++;
      }
      allRequiredAnglesDetected = detectedAnglesCount >= 3;
    }

    // If all required angles are detected, proceed to confirmation
    if (allRequiredAnglesDetected) {
      // Stop image stream
      if (_controller != null && _controller!.value.isStreamingImages) {
        _controller!.stopImageStream();
      }

      // Proceed to confirmation immediately
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          _confirmFaceDetection();
        }
      });
      return;
    }

    // Otherwise, move to the next undetected angle
    FaceAngle? nextAngle;

    // Define the preferred order of angles for a more natural user experience
    final List<FaceAngle> preferredOrder = [
      FaceAngle.front,
      FaceAngle.left,
      FaceAngle.right,
      FaceAngle.up,
      FaceAngle.down,
    ];

    // Find the next angle in the preferred order that hasn't been detected yet
    for (var angle in preferredOrder) {
      if (!_angleDetected[angle]!) {
        nextAngle = angle;
        break;
      }
    }

    // If we found a next angle, update the UI
    if (nextAngle != null) {
      setState(() {
        _currentRequestedAngle = nextAngle!;
        _detectionCount = 0;
        _faceDetected = false;
      });

      // Provide feedback to the user about the next angle
      print("Moving to next angle: $_currentRequestedAngle");

      // Ensure detection loop is running for the new angle
      // Only restart if not already streaming
      if (_controller != null && !_controller!.value.isStreamingImages) {
        _startDetectionLoop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
            widget.isIdentifying ? 'Xác thực khuôn mặt' : 'Đăng ký khuôn mặt'),
        backgroundColor: Colors.blue,
      ),
      body: Stack(
        children: [
          // Camera preview - only show when controller is valid and initialized
          _isCameraInitialized &&
                  _controller != null &&
                  _controller!.value.isInitialized &&
                  !_isNavigating
              ? Center(
                  child: Builder(
                    builder: (context) {
                      try {
                        return CameraPreview(_controller!);
                      } catch (e) {
                        print("Error building CameraPreview: $e");
                        return const Center(
                          child: Text("Camera preview unavailable",
                              style: TextStyle(color: Colors.white)),
                        );
                      }
                    },
                  ),
                )
              : const Center(
                  child: CircularProgressIndicator(),
                ),

          // Face detection overlay
          if (_isCameraInitialized)
            Positioned.fill(
              child: CustomPaint(
                painter: FaceOverlayPainter(
                  faceDetected: _faceDetected,
                  currentAngle: _currentRequestedAngle,
                  isIdentifying: widget.isIdentifying,
                ),
              ),
            ),

          // Angle instruction text
          if (_isCameraInitialized && !_showConfirmation)
            Positioned(
              top: 20,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(12),
                color: Colors.black54,
                child: Column(
                  children: [
                    Text(
                      _getInstructionText(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _getDetailedInstructionText(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Progress indicator
                    if (!widget.isIdentifying) // Only show for registration
                      LinearProgressIndicator(
                        value: _totalAnglesDetected / _totalRequiredAngles,
                        backgroundColor: Colors.grey,
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(Colors.green),
                      ),
                    if (!widget.isIdentifying)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Đã quét $_totalAnglesDetected/$_totalRequiredAngles góc',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

          // Processing indicator when all angles are detected
          if (_showConfirmation)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: const Center(
                  child: Card(
                    margin: EdgeInsets.all(16),
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Đã quét xong tất cả các góc',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 16),
                          Text(
                            'Đang xử lý dữ liệu khuôn mặt...',
                            textAlign: TextAlign.center,
                          ),
                          SizedBox(height: 16),
                          CircularProgressIndicator(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Get instruction text based on current angle
  String _getInstructionText() {
    switch (_currentRequestedAngle) {
      case FaceAngle.front:
        return 'Nhìn thẳng vào camera';
      case FaceAngle.left:
        return 'Xoay mặt sang trái';
      case FaceAngle.right:
        return 'Xoay mặt sang phải';
      case FaceAngle.up:
        return 'Ngẩng mặt lên trên';
      case FaceAngle.down:
        return 'Cúi mặt xuống dưới';
    }
  }

  // Get detailed instruction text based on current angle
  String _getDetailedInstructionText() {
    switch (_currentRequestedAngle) {
      case FaceAngle.front:
        return 'Giữ khuôn mặt trong khung và nhìn thẳng vào camera';
      case FaceAngle.left:
        return 'Từ từ xoay mặt sang bên trái khoảng 45 độ';
      case FaceAngle.right:
        return 'Từ từ xoay mặt sang bên phải khoảng 45 độ';
      case FaceAngle.up:
        return 'Ngẩng cằm lên trên và nhìn lên trần nhà (không chỉ di chuyển mắt)';
      case FaceAngle.down:
        return 'Cúi cằm xuống dưới như nhìn xuống sàn nhà (không chỉ di chuyển mắt)';
      default:
        return '';
    }
  }
}

// Face overlay painter
class FaceOverlayPainter extends CustomPainter {
  final bool faceDetected;
  final FaceAngle currentAngle;
  final bool isIdentifying;

  FaceOverlayPainter({
    required this.faceDetected,
    required this.currentAngle,
    required this.isIdentifying,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double centerX = size.width / 2;
    final double centerY = size.height / 2;
    final double radius = size.width * 0.4; // Oval size

    // Draw face outline
    final Paint outlinePaint = Paint()
      ..color = faceDetected ? Colors.green : Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    // Draw oval for face positioning
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centerX, centerY),
        width: radius * 1.5,
        height: radius * 1.8,
      ),
      outlinePaint,
    );

    // Draw angle indicator
    final Paint anglePaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.fill;

    // Draw angle indicator based on current requested angle
    switch (currentAngle) {
      case FaceAngle.front:
        // Center dot - placed outside the oval at the top
        canvas.drawCircle(
          Offset(centerX, centerY - radius * 1.2),
          15,
          anglePaint..color = Colors.red,
        );

        // Add text label
        final TextPainter textPainter = TextPainter(
          text: const TextSpan(
            text: 'NHÌN THẲNG',
            style: TextStyle(
              color: Colors.red,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              backgroundColor: Colors.black54,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();

        // Draw text background for better visibility
        final Paint textBgPaint = Paint()
          ..color = Colors.black54
          ..style = PaintingStyle.fill;
        canvas.drawRect(
            Rect.fromLTWH(
                centerX - textPainter.width / 2 - 5,
                centerY - radius * 1.2 - 45,
                textPainter.width + 10,
                textPainter.height + 6),
            textBgPaint);

        // Position text above the dot
        textPainter.paint(
            canvas,
            Offset(
                centerX - textPainter.width / 2, centerY - radius * 1.2 - 40));
        break;

      case FaceAngle.left:
        // Left arrow - placed completely outside the oval
        final Paint arrowPaint = Paint()
          ..color = Colors.red
          ..style = PaintingStyle.fill;

        final Path arrowPath = Path()
          ..moveTo(centerX - radius * 1.2,
              centerY) // Arrow tip further left, outside oval
          ..lineTo(centerX - radius * 0.8, centerY - 30) // Wider arrow
          ..lineTo(centerX - radius * 0.8, centerY + 30) // Wider arrow
          ..close();
        canvas.drawPath(arrowPath, arrowPaint);

        // Add text label
        final TextPainter textPainter = TextPainter(
          text: const TextSpan(
            text: 'PHẢI',
            style: TextStyle(
              color: Colors.red,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              backgroundColor: Colors.black54,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();

        // Draw text background for better visibility
        final Paint textBgPaint = Paint()
          ..color = Colors.black54
          ..style = PaintingStyle.fill;
        canvas.drawRect(
            Rect.fromLTWH(
                centerX - radius * 1.2 - textPainter.width / 2 - 5 + 20,
                centerY - 70,
                textPainter.width + 10,
                textPainter.height + 6),
            textBgPaint);

        // Position text to the left of the arrow
        textPainter.paint(
            canvas,
            Offset(centerX - radius * 1.2 - textPainter.width / 2 + 20,
                centerY - 65));
        break;

      case FaceAngle.right:
        // Right arrow - placed completely outside the oval
        final Paint arrowPaint = Paint()
          ..color = Colors.red
          ..style = PaintingStyle.fill;

        final Path arrowPath = Path()
          ..moveTo(centerX + radius * 1.2,
              centerY) // Arrow tip further right, outside oval
          ..lineTo(centerX + radius * 0.8, centerY - 30) // Wider arrow
          ..lineTo(centerX + radius * 0.8, centerY + 30) // Wider arrow
          ..close();
        canvas.drawPath(arrowPath, arrowPaint);

        // Add text label
        final TextPainter textPainter = TextPainter(
          text: const TextSpan(
            text: 'TRÁI',
            style: TextStyle(
              color: Colors.red,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              backgroundColor: Colors.black54,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();

        // Draw text background for better visibility
        final Paint textBgPaint = Paint()
          ..color = Colors.black54
          ..style = PaintingStyle.fill;
        canvas.drawRect(
            Rect.fromLTWH(
                centerX + radius * 1.2 - textPainter.width / 2 - 5 - 20,
                centerY - 70,
                textPainter.width + 10,
                textPainter.height + 6),
            textBgPaint);

        // Position text to the right of the arrow
        textPainter.paint(
            canvas,
            Offset(centerX + radius * 1.2 - textPainter.width / 2 - 20,
                centerY - 65));
        break;
      case FaceAngle.up:
        // Enhanced up arrow with visual guide for chin movement - OUTSIDE the face oval
        // Draw larger, more prominent up arrow
        final Paint arrowPaint = Paint()
          ..color = Colors.red // More attention-grabbing color
          ..style = PaintingStyle.fill;

        final Path arrowPath = Path()
          ..moveTo(centerX,
              centerY - radius * 1.2) // Arrow tip further up, outside oval
          ..lineTo(centerX - 30, centerY - radius * 0.8) // Wider arrow
          ..lineTo(centerX + 30, centerY - radius * 0.8) // Wider arrow
          ..close();
        canvas.drawPath(arrowPath, arrowPaint);

        // Draw chin movement guide
        final Paint guidePaint = Paint()
          ..color = Colors.yellow
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0; // Thicker line

        // Draw curved line to indicate chin movement - more pronounced curve
        final Path guidePath = Path()
          ..moveTo(centerX - 50, centerY + 30) // Start further out
          ..quadraticBezierTo(
              centerX,
              centerY - 60, // Control point further above
              centerX + 50,
              centerY + 30 // End further out
              );
        canvas.drawPath(guidePath, guidePaint);

        // Add more prominent text label
        final TextPainter textPainter = TextPainter(
          text: const TextSpan(
            text: 'NGẨNG CẰM LÊN',
            style: TextStyle(
              color: Colors.red,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              backgroundColor: Colors.black54,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();

        // Draw text background for better visibility
        final Paint textBgPaint = Paint()
          ..color = Colors.black54
          ..style = PaintingStyle.fill;
        canvas.drawRect(
            Rect.fromLTWH(
                centerX - textPainter.width / 2 - 5,
                centerY - radius * 1.2 - 45,
                textPainter.width + 10,
                textPainter.height + 6),
            textBgPaint);

        // Position text above the arrow, outside the oval
        textPainter.paint(
            canvas,
            Offset(
                centerX - textPainter.width / 2, centerY - radius * 1.2 - 40));

        // Add additional instruction text
        final TextPainter instructionPainter = TextPainter(
          text: const TextSpan(
            text: 'Nhìn lên trần nhà',
            style: TextStyle(
              color: Colors.yellow,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        instructionPainter.layout();
        instructionPainter.paint(
            canvas,
            Offset(centerX - instructionPainter.width / 2,
                centerY - radius * 1.2 - 70));
        break;
      case FaceAngle.down:
        // Enhanced down arrow with visual guide for chin movement - OUTSIDE the face oval
        // Draw larger, more prominent down arrow
        final Paint arrowPaint = Paint()
          ..color = Colors.red // More attention-grabbing color
          ..style = PaintingStyle.fill;

        final Path arrowPath = Path()
          ..moveTo(centerX,
              centerY + radius * 1.2) // Arrow tip further down, outside oval
          ..lineTo(centerX - 30, centerY + radius * 0.8) // Wider arrow
          ..lineTo(centerX + 30, centerY + radius * 0.8) // Wider arrow
          ..close();
        canvas.drawPath(arrowPath, arrowPaint);

        // Draw chin movement guide
        final Paint guidePaint = Paint()
          ..color = Colors.yellow
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0; // Thicker line

        // Draw curved line to indicate chin movement - more pronounced curve
        final Path guidePath = Path()
          ..moveTo(centerX - 50, centerY - 30) // Start further out
          ..quadraticBezierTo(
              centerX,
              centerY + 60, // Control point further below
              centerX + 50,
              centerY - 30 // End further out
              );
        canvas.drawPath(guidePath, guidePaint);

        // Add more prominent text label
        final TextPainter textPainter = TextPainter(
          text: const TextSpan(
            text: 'CÚI CẰM XUỐNG',
            style: TextStyle(
              color: Colors.red,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              backgroundColor: Colors.black54,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();

        // Draw text background for better visibility
        final Paint textBgPaint = Paint()
          ..color = Colors.black54
          ..style = PaintingStyle.fill;
        canvas.drawRect(
            Rect.fromLTWH(
                centerX - textPainter.width / 2 - 5,
                centerY + radius * 1.2 + 10,
                textPainter.width + 10,
                textPainter.height + 6),
            textBgPaint);

        // Position text below the arrow, outside the oval
        textPainter.paint(
            canvas,
            Offset(
                centerX - textPainter.width / 2, centerY + radius * 1.2 + 15));

        // Add additional instruction text
        final TextPainter instructionPainter = TextPainter(
          text: const TextSpan(
            text: 'Nhìn xuống sàn nhà',
            style: TextStyle(
              color: Colors.yellow,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        instructionPainter.layout();
        instructionPainter.paint(
            canvas,
            Offset(centerX - instructionPainter.width / 2,
                centerY + radius * 1.2 + 45));
        break;
    }
  }

  @override
  bool shouldRepaint(FaceOverlayPainter oldDelegate) {
    return faceDetected != oldDelegate.faceDetected ||
        currentAngle != oldDelegate.currentAngle;
  }
}
