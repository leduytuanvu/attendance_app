import 'dart:async';
import 'dart:math' as math;

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
  bool _showConfirmation = false;

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
      print("Starting image stream for face detection");
      // Start the image stream only once
      _controller!.startImageStream((CameraImage image) async {
        if (_isDetecting || !mounted) return; // Prevent concurrent processing

        setState(() {
          _isDetecting = true;
        });

        try {
          final InputImage? inputImage = _inputImageFromCameraImage(image);
          if (inputImage == null) {
            print("Failed to create InputImage from camera image");
            if (mounted) {
              setState(() {
                _isDetecting = false;
              });
            }
            return;
          }

          // Process the image for faces
          final List<Face> faces =
              await _faceDetector!.processImage(inputImage);

          if (faces.isNotEmpty && mounted) {
            final face = faces.first;

            // Store the detected face for later use
            _lastDetectedFace = face;

            // For check-in mode (identifying), we only need the front face
            // For registration mode, we need multiple angles
            if (widget.isIdentifying) {
              // For check-in, we need at least front and one more angle for better accuracy
              if (_isCorrectFaceAngle(face, _currentRequestedAngle)) {
                // Increment detection count for the current angle
                _detectionCount++;

                // Update UI to show face is being detected
                setState(() {
                  _faceDetected = true;
                  _isDetecting = false;
                });

                // If we've detected the face multiple times in the current angle
                if (_detectionCount >= 2) {
                  // Reduced from 3 to 2 for faster but still accurate check-in
                  // Mark this angle as detected
                  setState(() {
                    _angleDetected[_currentRequestedAngle] = true;

                    // Store face data for this angle
                    _storeFaceDataForAngle(face, _currentRequestedAngle);

                    // For check-in, we only need the front angle
                    if (_currentRequestedAngle == FaceAngle.front) {
                      if (widget.isIdentifying) {
                        // For identification mode (check-in), proceed immediately with just the front angle
                        // Add a small delay to ensure proper processing
                        Future.delayed(const Duration(milliseconds: 500), () {
                          if (mounted) {
                            _confirmFaceDetection(skipConfirmation: true);

                            // Stop image stream
                            if (_controller?.value.isStreamingImages ?? false) {
                              _controller?.stopImageStream();
                            }
                          }
                        });
                      } else {
                        // For registration, we still need multiple angles, show confirmation screen
                        setState(() {
                          _showConfirmation = true;
                        });
                        
                        // Add a small delay to ensure proper processing
                        Future.delayed(const Duration(milliseconds: 500), () {
                          if (mounted) {
                            // Stop image stream
                            if (_controller?.value.isStreamingImages ?? false) {
                              _controller?.stopImageStream();
                            }
                          }
                        });
                      }
                    }
                  });
                } else {
                  // Continue detecting if we haven't reached the threshold
                  setState(() {
                    _isDetecting = false;
                  });
                }
              } else {
                setState(() {
                  _faceDetected = false;
                  _isDetecting = false;
                });
              }
            } else {
              // For registration, we need multiple angles
              // Check if the current face angle matches the requested angle
              bool isCorrectAngle =
                  _isCorrectFaceAngle(face, _currentRequestedAngle);

              if (isCorrectAngle) {
                // Increment detection count for the current angle
                _detectionCount++;

                // Update UI to show face is being detected
                setState(() {
                  _faceDetected = true;
                  _isDetecting = false;
                });

                // If we've detected the face multiple times in the current angle
                if (_detectionCount >= _requiredDetections) {
                  // Mark this angle as detected
                  setState(() {
                    _angleDetected[_currentRequestedAngle] = true;

                    // Store face data for this angle
                    _storeFaceDataForAngle(face, _currentRequestedAngle);

                    // Reset detection count for next angle
                    _detectionCount = 0;

                    // Move to next angle or complete if all angles are detected
                    _moveToNextAngle();
                  });
                } else {
                  // Continue detecting if we haven't reached the threshold
                  setState(() {
                    _isDetecting = false;
                  });
                }
              } else {
                // Face detected but not at the correct angle
                setState(() {
                  _faceDetected = false;
                  _isDetecting = false;
                });
              }
            }
          } else {
            // No face detected in this frame
            if (mounted) {
              setState(() {
                _isDetecting = false;
              });
            }
          }
        } catch (e) {
          print("Error during face detection: $e");
          if (mounted) {
            setState(() {
              _isDetecting = false;
            });
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
    if (_controller?.value.isStreamingImages ?? false) {
      await _controller?.stopImageStream();
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

  // Face recognition service
  final FaceRecognitionService _faceRecognitionService =
      FaceRecognitionService();

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

  // Get a single camera image for processing
  Future<CameraImage?> _getCameraImage() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      return null;
    }

    // Use a completer to get a single frame from the camera
    final completer = Completer<CameraImage?>();
    
    // Set a timeout to avoid hanging if no image is received
    final timeout = Timer(const Duration(seconds: 2), () {
      if (!completer.isCompleted) {
        completer.complete(null);
        print("Camera image capture timed out");
      }
    });

    try {
      // Check if image stream is already running
      if (_controller!.value.isStreamingImages) {
        // If already streaming, just use the next frame from the existing stream
        // We don't need to start a new stream
        return await _getFrameFromExistingStream(completer, timeout);
      } else {
        // If not streaming, start a new stream
        await _controller!.startImageStream((image) {
          // Only complete once
          if (!completer.isCompleted) {
            // Stop the stream after getting the first image
            _controller!.stopImageStream();
            timeout.cancel();
            completer.complete(image);
          }
        });
      }
    } catch (e) {
      print("Error starting image stream: $e");
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }

    // Return the captured image
    return completer.future;
  }
  
  // Helper method to get a frame from an existing stream
  Future<CameraImage?> _getFrameFromExistingStream(
      Completer<CameraImage?> completer, Timer timeout) async {
    // We're already streaming, so we just need to wait for the next frame
    // This is a workaround since we can't directly subscribe to the existing stream
    
    // Create a flag to track if we've received a frame
    bool frameReceived = false;
    
    try {
      // Check if controller is still valid
      if (_controller == null || !_controller!.value.isInitialized) {
        print("Camera controller is null or not initialized");
        if (!completer.isCompleted) {
          completer.complete(null);
        }
        return completer.future;
      }
      
      // Since we can't directly access the stream callback, we need to stop and restart the stream
      // First, stop the current stream
      if (_controller!.value.isStreamingImages) {
        await _controller!.stopImageStream();
      } else {
        print("Camera is not streaming images");
        if (!completer.isCompleted) {
          completer.complete(null);
        }
        return completer.future;
      }
      
      // Wait a short moment to ensure the stream is fully stopped
      await Future.delayed(const Duration(milliseconds: 100));
      
      // Check again if controller is still valid
      if (_controller == null || !_controller!.value.isInitialized) {
        print("Camera controller became invalid after stopping stream");
        if (!completer.isCompleted) {
          completer.complete(null);
        }
        return completer.future;
      }
      
      // Start a new stream to get a single frame
      await _controller!.startImageStream((image) {
        // Only complete once
        if (!completer.isCompleted && !frameReceived) {
          frameReceived = true;
          
          // Cancel the timeout
          timeout.cancel();
          
          // Complete with the image
          completer.complete(image);
          
          // Stop the stream after getting the frame
          if (_controller != null && _controller!.value.isInitialized && _controller!.value.isStreamingImages) {
            _controller!.stopImageStream();
          }
          
          // Restart the original detection stream after a short delay
          Future.delayed(const Duration(milliseconds: 100), () {
            if (_controller != null && mounted && _controller!.value.isInitialized) {
              _startDetectionLoop();
            }
          });
        }
      });
      
    } catch (e) {
      print("Error getting frame from existing stream: $e");
      if (!completer.isCompleted) {
        completer.complete(null);
      }
      
      // Make sure we restart the detection stream if there was an error
      if (_controller != null && mounted && _controller!.value.isInitialized) {
        Future.delayed(const Duration(milliseconds: 100), () {
          _startDetectionLoop();
        });
      }
    }
    
    // Return the completer's future
    return completer.future;
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

  // Method to confirm face detection and return to previous screen
  Future<void> _confirmFaceDetection({bool skipConfirmation = false}) async {
    try {
      await _stopDetectionAndCamera();

      // Check if widget is still mounted before proceeding
      if (!mounted) return;

      // Process collected face data
      List<Map<String, dynamic>> processedFaceData = [];
      List<String> fallbackFaceData = [];
      List<List<double>> faceEmbeddings = [];

      // Check if we have collected face data from multiple angles
      if (_processedFaceData.isEmpty && _lastDetectedFace != null) {
        // Fallback to last detected face if no multi-angle data
        final faceDataResult = await _generateFaceData(_lastDetectedFace!);

        if (faceDataResult['success']) {
          processedFaceData.add(faceDataResult);
          faceEmbeddings.add(faceDataResult['embedding']);
        } else {
          fallbackFaceData.add(faceDataResult['fallbackData']);
        }
      } else {
        // We already have face data from multiple angles in _processedFaceData
        for (var data in _processedFaceData) {
          if (data['success']) {
            processedFaceData.add(data);
            faceEmbeddings.add(data['embedding']);
          } else {
            fallbackFaceData.add(data['fallbackData']);
          }
        }
      }

      // Check if widget is still mounted before proceeding
      if (!mounted) return;

      // Prepare result data
      Map<String, dynamic> resultData = {
        'faceDetected': true,
        'success': true,
        'multiAngle': _angleDetected.values.where((detected) => detected).length > 1,
      };

      // Add CCCD for identification mode (even though we're skipping the input screen)
      if (widget.isIdentifying) {
        resultData['cccd'] = _cccdController.text;
      }

      // Add face data
      if (processedFaceData.isNotEmpty) {
        // Use the first face data as primary
        resultData['faceData'] = processedFaceData.first['embeddingString'] ?? processedFaceData.first['fallbackData'];
        resultData['allFaceData'] = processedFaceData;

        // Add embeddings for better matching
        resultData['faceEmbeddings'] = faceEmbeddings;

        // Add a combined embedding (average of all embeddings) for more robust matching
        if (faceEmbeddings.length > 1) {
          resultData['combinedEmbedding'] = _combineEmbeddings(faceEmbeddings);
        }
      } else if (fallbackFaceData.isNotEmpty) {
        // Use fallback data if no processed data is available
        resultData['faceData'] = fallbackFaceData.first;
        resultData['allFaceData'] = fallbackFaceData;
        resultData['usingFallback'] = true;
      }

      // Check if widget is still mounted before popping
      if (mounted) {
        try {
          // Ensure we're properly releasing camera resources before navigation
          if (_controller != null) {
            await _controller!.dispose();
            _controller = null;
          }
          
          // Return result to previous screen with a more robust approach
          if (mounted) {
            try {
              // Use a safer navigation approach to prevent returning to home screen
              Navigator.of(context).pop(resultData);
            } catch (e) {
              print("First navigation attempt failed: $e");
              
              // Try again with a different approach
              Future.delayed(const Duration(milliseconds: 100), () {
                if (mounted) {
                  try {
                    Navigator.pop(context, resultData);
                  } catch (e2) {
                    print("Second navigation attempt failed: $e2");
                    
                    // Last resort - use a post-frame callback
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        try {
                          Navigator.of(context).pop(resultData);
                        } catch (e3) {
                          print("Third navigation attempt failed: $e3");
                        }
                      }
                    });
                  }
                }
              });
            }
          }
        } catch (navError) {
          print("Navigation error in _confirmFaceDetection: $navError");
          // If there's a navigation error, try again after a short delay with a different approach
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              try {
                Navigator.of(context).pop(resultData);
              } catch (e) {
                print("Second navigation attempt failed: $e");
                // Last resort - try one more time with a different approach
                if (mounted) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    Navigator.pop(context, resultData);
                  });
                }
              }
            }
          });
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
                'faceData': _lastDetectedFace != null ? _generateFallbackFaceData(_lastDetectedFace!) : null
              });
            }
          });
        } catch (navError) {
          print("Error during error handling navigation: $navError");
        }
      }
    }
  }

  // Combine multiple face embeddings into a single, more robust embedding
  List<double> _combineEmbeddings(List<List<double>> embeddings) {
    if (embeddings.isEmpty) {
      return [];
    }

    final int embeddingSize = embeddings.first.length;
    final List<double> combined = List<double>.filled(embeddingSize, 0.0);

    // Sum all embeddings
    for (final embedding in embeddings) {
      for (int i = 0; i < embeddingSize; i++) {
        combined[i] += embedding[i];
      }
    }

    // Divide by count to get average
    for (int i = 0; i < embeddingSize; i++) {
      combined[i] = combined[i] / embeddings.length;
    }

    // Normalize the combined embedding (using our own normalization since we can't access private method)
    return _normalizeEmbedding(combined);
  }

  // Normalize embedding vector to unit length for better comparison
  List<double> _normalizeEmbedding(List<double> embedding) {
    double sum = 0;
    for (final value in embedding) {
      sum += value * value;
    }

    final norm = math.sqrt(sum);
    if (norm > 0) {
      for (int i = 0; i < embedding.length; i++) {
        embedding[i] = embedding[i] / norm;
      }
    }

    return embedding;
  }

  // Check if the face is at the correct angle based on the requested angle
  // Highly optimized for Asian faces with much more lenient angle detection
  bool _isCorrectFaceAngle(Face face, FaceAngle angle) {
    final top = face.boundingBox.top;
    final yAngle = face.headEulerAngleY ?? 0;
    final zAngle = face.headEulerAngleZ ?? 0;
    final height = face.boundingBox.height;
    final width = face.boundingBox.width;
    final aspectRatio = width / height;

    // Print debug info for angle detection
    print(
        "[Face Angle Debug] Y: $yAngle, Z: $zAngle, Top: $top, Height: $height, Width: $width, Ratio: $aspectRatio");

    // For identification mode, be extremely lenient to improve success rate
    if (widget.isIdentifying) {
      // For identification, we mainly care about having a good frontal face
      if (angle == FaceAngle.front) {
        // Much more lenient front face detection for identification
        return yAngle.abs() < 30 && zAngle.abs() < 20;
      }
      
      // For other angles in identification mode, be very lenient
      switch (angle) {
        case FaceAngle.front:
          // Already handled above
          return true;
        case FaceAngle.left:
          return yAngle > 5;
        case FaceAngle.right:
          return yAngle < -5;
        case FaceAngle.up:
          return zAngle < -5;
        case FaceAngle.down:
          return zAngle > 5;
      }
    }
    
    // For registration mode, be more specific but still lenient for Asian faces
    switch (angle) {
      case FaceAngle.front:
        // More lenient front face detection for Asian faces
        return yAngle.abs() < 25 && zAngle.abs() < 18;

      case FaceAngle.left:
        // More lenient left angle detection
        return yAngle > 10;

      case FaceAngle.right:
        // More lenient right angle detection
        return yAngle < -10;

      case FaceAngle.up:
        // Adjusted for Asian facial features
        return (top > 290 && yAngle.abs() < 25) || zAngle < -8;

      case FaceAngle.down:
        // More lenient down angle detection for Asian faces
        // Nếu mặt nhỏ lại đáng kể (do cúi đầu) hoặc ở vị trí cao trên khung hoặc góc Z dương
        return height < 460 || top < 350 || zAngle > 8;
    }
  }

  // Move to the next angle or complete if all angles are detected
  void _moveToNextAngle() {
    // For registration, require all 5 angles to be detected
    // For identification, 3 angles would be sufficient
    bool allRequiredAnglesDetected = true;

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
      int detectedAnglesCount =
          _angleDetected.values.where((detected) => detected).length;
      allRequiredAnglesDetected = detectedAnglesCount >= 3;
    }

    if (allRequiredAnglesDetected) {
      // All required angles detected, show confirmation
      if (_controller?.value.isStreamingImages ?? false) {
        _controller?.stopImageStream();
      }

      setState(() {
        _showConfirmation = true;
      });
      return;
    }

    // Define a logical sequence for face angle detection
    // Start with front, then left/right, then up/down
    List<FaceAngle> angleSequence = [
      FaceAngle.front,
      FaceAngle.left,
      FaceAngle.right,
      FaceAngle.up,
      FaceAngle.down,
    ];

    // Find the next undetected angle in the sequence
    FaceAngle? nextAngle;
    for (var angle in angleSequence) {
      if (!_angleDetected[angle]!) {
        nextAngle = angle;
        break;
      }
    }

    // Default to front if all angles have been attempted
    nextAngle ??= FaceAngle.front;

    setState(() {
      _currentRequestedAngle = nextAngle!;
      _faceDetected = false;
    });
  }

  // Get icon for the current angle
  Widget _getAngleIcon(FaceAngle angle) {
    switch (angle) {
      case FaceAngle.front:
        return const Icon(Icons.face, color: Colors.white);
      case FaceAngle.left:
        return const Icon(Icons.arrow_back, color: Colors.white);
      case FaceAngle.right:
        return const Icon(Icons.arrow_forward, color: Colors.white);
      case FaceAngle.up:
        return const Icon(Icons.arrow_upward, color: Colors.white);
      case FaceAngle.down:
        return const Icon(Icons.arrow_downward, color: Colors.white);
    }
  }

  // Get instruction text for the current angle
  // Optimized with more detailed instructions for Asian faces
  String _getAngleInstruction(FaceAngle angle) {
    switch (angle) {
      case FaceAngle.front:
        return 'Nhìn thẳng vào camera, giữ nét mặt tự nhiên';
      case FaceAngle.left:
        return 'Quay mặt sang trái khoảng 30-45 độ';
      case FaceAngle.right:
        return 'Quay mặt sang phải khoảng 30-45 độ';
      case FaceAngle.up:
        return 'Ngẩng đầu lên trên một chút';
      case FaceAngle.down:
        return 'Cúi đầu xuống dưới một chút';
    }
  }

  // Method to retry face detection
  void _retryFaceDetection() {
    setState(() {
      _showConfirmation = false;
      _faceDetected = false;
      _detectionCount = 0;

      // Reset all angles
      for (var angle in FaceAngle.values) {
        _angleDetected[angle] = false;
      }

      // Start with front angle for better user experience
      _currentRequestedAngle = FaceAngle.front;
      _faceDataFromAngles.clear();
      _processedFaceData.clear();
    });

    // Restart the detection process
    _startDetectionLoop();
  }

  @override
  Widget build(BuildContext context) {
    // If we're showing the confirmation UI
    if (_showConfirmation) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.isIdentifying
              ? 'Xác nhận điểm danh'
              : 'Xác nhận khuôn mặt'),
          automaticallyImplyLeading: false,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.check_circle,
                  color: Colors.green,
                  size: 80,
                ),
                const SizedBox(height: 20),
                Text(
                  widget.isIdentifying
                      ? 'Đã nhận diện khuôn mặt thành công!'
                      : 'Đã quét khuôn mặt từ nhiều góc thành công!',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                widget.isIdentifying
                    ? const Text(
                        'Hệ thống sẽ tìm kiếm User Information dựa trên khuôn mặt.',
                        style: TextStyle(fontSize: 16),
                        textAlign: TextAlign.center,
                      )
                    : Column(
                        children: [
                          Text(
                            'Đã quét được ${_faceDataFromAngles.length} góc khuôn mặt. Bạn có muốn sử dụng khuôn mặt này để đăng ký không?',
                            style: const TextStyle(fontSize: 16),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.blue.shade200),
                            ),
                            child: const Text(
                              'Việc quét nhiều góc giúp tăng độ chính xác khi nhận diện khuôn mặt người châu Á',
                              style: TextStyle(
                                fontSize: 14,
                                fontStyle: FontStyle.italic,
                                color: Colors.blue,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                const SizedBox(height: 20),

                // CCCD input field for identification mode
                if (widget.isIdentifying)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20.0, vertical: 10.0),
                    child: TextFormField(
                      controller: _cccdController,
                      decoration: const InputDecoration(
                        labelText: 'CCCD/CMND (Nếu có)',
                        hintText: 'Nhập CCCD để tìm kiếm chính xác hơn',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),

                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _retryFaceDetection,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Thử lại'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: _confirmFaceDetection,
                      icon: const Icon(Icons.check),
                      label: const Text('Xác nhận'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Otherwise show the camera UI
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isIdentifying
            ? 'Quét khuôn mặt để điểm danh'
            : 'Quét khuôn mặt để đăng ký điểm danh'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            // Return false to indicate scan was cancelled
            Navigator.pop(context, false);
          },
        ),
      ),
      body: _isCameraInitialized &&
              _controller != null &&
              _controller!.value.isInitialized
          ? Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(_controller!),
                // Face outline guide
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 250,
                        height: 350,
                        decoration: BoxDecoration(
                          border: Border.all(
                              color:
                                  _faceDetected ? Colors.green : Colors.yellow,
                              width: 3),
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _faceDetected
                                  ? 'Khuôn mặt đã được nhận diện'
                                  : 'Đặt khuôn mặt của bạn vào trong khung',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: _faceDetected
                                      ? Colors.greenAccent
                                      : Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(height: 10),
                          // Progress indicator
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: FaceAngle.values.map((angle) {
                              return Container(
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _angleDetected[angle]!
                                      ? Colors.green
                                      : (angle == _currentRequestedAngle
                                          ? Colors.yellow
                                          : Colors.grey),
                                ),
                                child: _angleDetected[angle]!
                                    ? const Icon(Icons.check,
                                        size: 16, color: Colors.white)
                                    : null,
                              );
                            }).toList(),
                          ),

                          // Only show angle instructions for registration mode
                          if (!widget.isIdentifying) ...[
                            const SizedBox(height: 10),
                            // Current angle instruction
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.blue.withOpacity(0.7),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _getAngleIcon(_currentRequestedAngle),
                                  const SizedBox(width: 10),
                                  Text(
                                    _getAngleInstruction(
                                        _currentRequestedAngle),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                // Top instruction panel
                Positioned(
                  top: 20,
                  left: 0,
                  right: 0,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      children: [
                        Text(
                          widget.isIdentifying
                              ? 'Hướng dẫn quét khuôn mặt để điểm danh'
                              : 'Hướng dẫn quét khuôn mặt',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.isIdentifying
                              ? '1. Đảm bảo khuôn mặt nằm trong khung vàng\n'
                                  '2. Giữ điện thoại cách mặt 30-50cm\n'
                                  '3. Chỉ cần nhìn thẳng vào camera\n'
                                  '4. Đảm bảo ánh sáng đủ sáng\n'
                                  '5. Tháo kính, khẩu trang nếu có'
                              : '1. Đảm bảo khuôn mặt nằm trong khung vàng\n'
                                  '2. Giữ điện thoại cách mặt 30-50cm\n'
                                  '3. Làm theo hướng dẫn quay mặt các góc\n'
                                  '4. Đảm bảo ánh sáng đủ sáng\n'
                                  '5. Tháo kính, khẩu trang nếu có\n'
                                  '6. Giữ nét mặt tự nhiên',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
                // Status message at bottom
                Positioned(
                  bottom: 20,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.symmetric(
                        vertical: 12.0, horizontal: 20.0),
                    child: Text(
                      _isDetecting
                          ? 'Đang nhận diện khuôn mặt...'
                          : _faceDetected
                              ? 'Khuôn mặt đã được nhận diện!'
                              : 'Đang chuẩn bị camera...',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _faceDetected
                            ? Colors.greenAccent
                            : _isDetecting
                                ? Colors.yellowAccent
                                : Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}
