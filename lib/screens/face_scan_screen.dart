import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'; // Import for WriteBuffer
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:attendance_app/services/face_recognition_service.dart';

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
  static const int _requiredDetections = 2; // Detections needed per angle
  bool _showConfirmation = false;

  // Store the last detected face for face data generation
  Face? _lastDetectedFace;

  // For identification mode
  final TextEditingController _cccdController = TextEditingController();

  // Face angle tracking
  Map<FaceAngle, bool> _angleDetected = {
    FaceAngle.front: false,
    FaceAngle.left: false,
    FaceAngle.right: false,
    FaceAngle.up: false,
    FaceAngle.down: false,
  };
  FaceAngle _currentRequestedAngle = FaceAngle.left; // Start with left angle instead of front

  // Combined face data from multiple angles
  List<String> _faceDataFromAngles = [];

  @override
  void initState() {
    super.initState();
    _initializeCameraAndDetector();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _faceDetector?.close();
    _detectionTimer?.cancel();
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
      enableContours: false, // Disable contours for better performance
      enableLandmarks: false, // Disable landmarks for better performance
      performanceMode: FaceDetectorMode.fast, // Prioritize speed over accuracy
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
              // For check-in, just need a front-facing image
              if (_isCorrectFaceAngle(face, FaceAngle.front)) {
                // Mark front angle as detected
                setState(() {
                  _angleDetected[FaceAngle.front] = true;
                  _faceDetected = true;
                  _isDetecting = false;

                  // Store face data
                  _storeFaceDataForAngle(face, FaceAngle.front);

                  // Show confirmation immediately for faster check-in
                  _showConfirmation = true;

                  // Stop image stream
                  if (_controller?.value.isStreamingImages ?? false) {
                    _controller?.stopImageStream();
                  }
                });
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

  // Generate face data using TensorFlow Lite
  Future<String> _generateFaceData(Face face) async {
    if (_controller == null || !_controller!.value.isInitialized) {
      // Fallback to simple face data if camera is not available
      return "face_${face.boundingBox.left.toStringAsFixed(2)}_"
          "${face.boundingBox.top.toStringAsFixed(2)}_"
          "${face.boundingBox.width.toStringAsFixed(2)}_"
          "${face.boundingBox.height.toStringAsFixed(2)}_"
          "${face.headEulerAngleY?.toStringAsFixed(2) ?? '0.00'}_"
          "${face.headEulerAngleZ?.toStringAsFixed(2) ?? '0.00'}_"
          "${DateTime.now().millisecondsSinceEpoch}";
    }

    try {
      // Take a single image from the camera
      final image = await _controller!.takePicture();

      // Process the image with TensorFlow Lite
      // In a real app, you would use the face recognition service to get embeddings
      // For this example, we'll use a placeholder

      // Return a string representation of the face data
      return "face_${face.boundingBox.left.toStringAsFixed(2)}_"
          "${face.boundingBox.top.toStringAsFixed(2)}_"
          "${face.boundingBox.width.toStringAsFixed(2)}_"
          "${face.boundingBox.height.toStringAsFixed(2)}_"
          "${face.headEulerAngleY?.toStringAsFixed(2) ?? '0.00'}_"
          "${face.headEulerAngleZ?.toStringAsFixed(2) ?? '0.00'}_"
          "${DateTime.now().millisecondsSinceEpoch}";
    } catch (e) {
      print("Error generating face data: $e");
      // Fallback to simple face data
      return "face_${face.boundingBox.left.toStringAsFixed(2)}_"
          "${face.boundingBox.top.toStringAsFixed(2)}_"
          "${face.boundingBox.width.toStringAsFixed(2)}_"
          "${face.boundingBox.height.toStringAsFixed(2)}_"
          "${face.headEulerAngleY?.toStringAsFixed(2) ?? '0.00'}_"
          "${face.headEulerAngleZ?.toStringAsFixed(2) ?? '0.00'}_"
          "${DateTime.now().millisecondsSinceEpoch}";
    }
  }

  // Method to confirm face detection and return to previous screen
  Future<void> _confirmFaceDetection() async {
    await _stopDetectionAndCamera();

    // Check if we have collected face data from multiple angles
    if (_faceDataFromAngles.isEmpty && _lastDetectedFace != null) {
      // Fallback to last detected face if no multi-angle data
      String faceData = await _generateFaceData(_lastDetectedFace!);
      _faceDataFromAngles.add(faceData);
    }

    if (widget.isIdentifying) {
      // Return a map with face detection result and CCCD for identification
      if (_faceDataFromAngles.isNotEmpty) {
        // Use the first face data for identification (could be enhanced to use all angles)
        String faceData = _faceDataFromAngles.first;
        Navigator.pop(context, {
          'faceDetected': true,
          'cccd': _cccdController.text,
          'faceData': faceData,
          'allFaceData':
              _faceDataFromAngles, // Include all face angles for better matching
        });
      } else {
        Navigator.pop(context, {
          'faceDetected': true,
          'cccd': _cccdController.text,
          'faceData': null,
        });
      }
    } else {
      // For registration, return success and face data
      if (_faceDataFromAngles.isNotEmpty) {
        // Use the first face data as primary, but include all angles
        String faceData = _faceDataFromAngles.first;
        Navigator.pop(context, {
          'success': true,
          'faceData': faceData,
          'allFaceData':
              _faceDataFromAngles, // Include all face angles for better matching
        });
      } else {
        Navigator.pop(context, {'success': true});
      }
    }
  }

  // Check if the face is at the correct angle based on the requested angle
  bool _isCorrectFaceAngle(Face face, FaceAngle requestedAngle) {
    // Get the face angles
    final double? yAngle = face.headEulerAngleY; // Left/Right rotation
    final double? zAngle = face.headEulerAngleZ; // Up/Down rotation

    if (yAngle == null || zAngle == null) return false;

    // Print current angles for debugging
    print(
        "Current face angles - Y (left/right): $yAngle, Z (up/down): $zAngle");

    switch (requestedAngle) {
      case FaceAngle.front:
        // Face is looking straight ahead - more lenient threshold
        return yAngle.abs() < 20 && zAngle.abs() < 20;
      case FaceAngle.left:
        // Face is turned to the left - more lenient threshold
        // Fixed: Positive Y angle means the face is turned to the left from camera perspective
        return yAngle > 15;
      case FaceAngle.right:
        // Face is turned to the right - more lenient threshold
        // Fixed: Negative Y angle means the face is turned to the right from camera perspective
        return yAngle < -15;
      case FaceAngle.up:
        // Face is looking up - more sensitive threshold
        return zAngle < -5;  // Changed from -10 to -5 to make it more sensitive
      case FaceAngle.down:
        // Face is looking down - more sensitive threshold
        return zAngle > 5;   // Changed from 10 to 5 to make it more sensitive
    }
  }

  // Store face data for the current angle
  Future<void> _storeFaceDataForAngle(Face face, FaceAngle angle) async {
    String faceData = await _generateFaceData(face);
    _faceDataFromAngles.add(faceData);
    print("Stored face data for angle: $angle - $faceData");
  }

  // Move to the next angle or complete if all angles are detected
  void _moveToNextAngle() {
    // Check if we have enough angles detected (at least 3 angles)
    int detectedAnglesCount = _angleDetected.values.where((detected) => detected).length;
    bool sufficientAnglesDetected = detectedAnglesCount >= 3;
    
    if (sufficientAnglesDetected) {
      // Sufficient angles detected, show confirmation
      if (_controller?.value.isStreamingImages ?? false) {
        _controller?.stopImageStream();
      }
      
      setState(() {
        _showConfirmation = true;
      });
      return;
    }
    
    // Find the next angle to detect, skipping front angle initially
    FaceAngle nextAngle = FaceAngle.left; // Default to left instead of front
    
    // Skip front angle and start with left/right angles
    if (!_angleDetected[FaceAngle.left]!) {
      nextAngle = FaceAngle.left;
    } else if (!_angleDetected[FaceAngle.right]!) {
      nextAngle = FaceAngle.right;
    } else if (!_angleDetected[FaceAngle.up]!) {
      nextAngle = FaceAngle.up;
    } else if (!_angleDetected[FaceAngle.down]!) {
      nextAngle = FaceAngle.down;
    } else if (!_angleDetected[FaceAngle.front]!) {
      // Only check front angle if all others are done
      nextAngle = FaceAngle.front;
    }
    
    setState(() {
      _currentRequestedAngle = nextAngle;
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
  String _getAngleInstruction(FaceAngle angle) {
    switch (angle) {
      case FaceAngle.front:
        return 'Nhìn thẳng vào camera';
      case FaceAngle.left:
        return 'Quay mặt sang trái';
      case FaceAngle.right:
        return 'Quay mặt sang phải';
      case FaceAngle.up:
        return 'Ngẩng đầu lên trên';
      case FaceAngle.down:
        return 'Cúi đầu xuống dưới';
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

      // Start with left angle instead of front
      _currentRequestedAngle = FaceAngle.left;
      _faceDataFromAngles.clear();
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
                        'Hệ thống sẽ tìm kiếm thông tin người dùng dựa trên khuôn mặt.',
                        style: TextStyle(fontSize: 16),
                        textAlign: TextAlign.center,
                      )
                    : Text(
                        'Đã quét được ${_faceDataFromAngles.length} góc khuôn mặt. Bạn có muốn sử dụng khuôn mặt này để đăng ký không?',
                        style: const TextStyle(fontSize: 16),
                        textAlign: TextAlign.center,
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
            : 'Quét khuôn mặt để đăng ký'),
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
                              : 'Hướng dẫn quét khuôn mặt để đăng ký',
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
                                  '3. Nhìn thẳng vào camera'
                              : '1. Đảm bảo khuôn mặt nằm trong khung vàng\n'
                                  '2. Giữ điện thoại cách mặt 30-50cm\n'
                                  '3. Làm theo hướng dẫn quay mặt các góc\n'
                                  '4. Tháo kính, khẩu trang nếu có',
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
