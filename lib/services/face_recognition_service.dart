import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:collection';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:path_provider/path_provider.dart';

class FaceRecognitionService {
  static final FaceRecognitionService _instance = FaceRecognitionService._internal();
  
  factory FaceRecognitionService() => _instance;
  
  FaceRecognitionService._internal();
  
  late Interpreter _interpreter;
  bool _isInitialized = false;
  
  // Face detector from ML Kit with accurate mode for better detection
  final _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      enableLandmarks: true,
      enableClassification: true, // Enable face classification (smiling, eyes open)
      performanceMode: FaceDetectorMode.accurate, // Use accurate mode for better results
      minFaceSize: 0.15, // Detect faces that occupy at least 15% of the image
    ),
  );
  
  // Model configurations
  final int inputSize = 112; // Face model input size
  final int embeddingSize = 128; // Size of face embedding vector
  
  // Initialize the TensorFlow Lite model
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      // Verify the model file exists in assets
      try {
        final modelPath = 'assets/models/face_recognition_model.tflite';
        final ByteData modelData = await rootBundle.load(modelPath);
        
        // Check if the model data is valid (at least has a minimum size)
        if (modelData.lengthInBytes < 1000) {
          print('Model file is too small, might be corrupted: ${modelData.lengthInBytes} bytes');
          throw Exception('Model file is too small, might be corrupted');
        }
        
        // Configure interpreter options
        final options = InterpreterOptions()
          ..threads = 4 // Use multiple threads for better performance
          ..useNnApiForAndroid = true; // Use Android Neural Networks API if available
        
        try {
          // Try to create interpreter directly from ByteData
          _interpreter = await Interpreter.fromBuffer(
            modelData.buffer.asUint8List(), 
            options: options
          );
          
          _isInitialized = true;
          print('Face recognition model initialized successfully directly from assets');
          return;
        } catch (bufferError) {
          print('Buffer loading failed: $bufferError');
          // Continue to file-based loading
        }
        
        // Alternative: Load model via temporary file
        final tempFile = await _loadModelToTempFile();
        
        // Verify the temp file exists and has content
        if (!await tempFile.exists() || await tempFile.length() < 1000) {
          print('Temp file is invalid or too small: ${await tempFile.length()} bytes');
          throw Exception('Temp file is invalid or too small');
        }
        
        // Create interpreter from file
        _interpreter = await Interpreter.fromFile(tempFile, options: options);
        _isInitialized = true;
        
        print('Face recognition model initialized successfully from temp file');
      } catch (assetError) {
        print('Asset loading failed: $assetError');
        throw assetError; // Re-throw to be caught by the outer try-catch
      }
    } catch (e) {
      print('Error initializing face recognition model: $e');
      
      // Instead of rethrowing, set a flag and continue with fallback behavior
      _isInitialized = false;
      print('Continuing with geometric face matching fallback behavior');
    }
  }
  
  // Load model from assets to a temporary file
  Future<File> _loadModelToTempFile() async {
    final modelPath = 'assets/models/face_recognition_model.tflite';
    try {
      // Try to load the model from assets
      final ByteData modelData = await rootBundle.load(modelPath);
      
      // Create a temporary file to ensure the model is properly loaded
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/face_recognition_model.tflite';
      final tempFile = File(tempPath);
      
      // Write the model data to the temporary file
      await tempFile.writeAsBytes(modelData.buffer.asUint8List());
      
      print('Model loaded successfully from assets and saved to temporary file');
      return tempFile;
    } catch (e) {
      print('Error loading model from assets to temp file: $e');
      rethrow;
    }
  }
  
  // Process a camera image and extract face embeddings
  Future<List<double>?> getFaceEmbedding(CameraImage cameraImage, Face face) async {
    // Try to initialize if not already initialized
    if (!_isInitialized) {
      await initialize();
      
      // If initialization failed, return null and use fallback
      if (!_isInitialized) {
        print('Face recognition model not initialized, using fallback behavior');
        return null;
      }
    }
    
    try {
      // Convert CameraImage to format suitable for TensorFlow Lite
      final inputTensor = await _preprocessFace(cameraImage, face);
      if (inputTensor == null) return null;
      
      // Prepare output tensor
      final outputTensor = List<double>.filled(embeddingSize, 0).reshape([1, embeddingSize]);
      
      // Run inference
      _interpreter.run(inputTensor, outputTensor);
      
      // Get the embedding from the output tensor
      final embedding = List<double>.from(outputTensor[0]);
      
      // Normalize the embedding (important for cosine similarity)
      return _normalizeEmbedding(embedding);
    } catch (e) {
      print('Error getting face embedding: $e');
      return null;
    }
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
  
  // Preprocess the face for the TensorFlow Lite model
  Future<List<List<List<List<double>>>>?> _preprocessFace(CameraImage cameraImage, Face face) async {
    try {
      // Convert CameraImage to img.Image
      img.Image? image = await _convertCameraImageToImage(cameraImage);
      if (image == null) return null;
      
      // Get face bounding box with padding for better results
      final faceRect = _getPaddedFaceRect(face.boundingBox, image.width, image.height);
      
      // Crop the face from the image
      final croppedFace = img.copyCrop(
        image,
        x: faceRect.left.toInt(),
        y: faceRect.top.toInt(),
        width: faceRect.width.toInt(),
        height: faceRect.height.toInt(),
      );
      
      // Resize to the input size expected by the model
      final resizedFace = img.copyResize(
        croppedFace,
        width: inputSize,
        height: inputSize,
        interpolation: img.Interpolation.cubic, // Better quality resizing
      );
      
      // Convert to float tensor [1, 112, 112, 3] with values normalized to [-1, 1]
      final tensor = List.generate(
        1,
        (_) => List.generate(
          inputSize,
          (y) => List.generate(
            inputSize,
            (x) => List<double>.filled(3, 0),
          ),
        ),
      );
      
      // Fill tensor with normalized pixel values
      for (int y = 0; y < inputSize; y++) {
        for (int x = 0; x < inputSize; x++) {
          final pixel = resizedFace.getPixel(x, y);
          // Normalize to [-1, 1] range
          tensor[0][y][x][0] = (pixel.r / 127.5) - 1.0; // R
          tensor[0][y][x][1] = (pixel.g / 127.5) - 1.0; // G
          tensor[0][y][x][2] = (pixel.b / 127.5) - 1.0; // B
        }
      }
      
      return tensor;
    } catch (e) {
      print('Error preprocessing face: $e');
      return null;
    }
  }
  
  // Add padding to face bounding box for better recognition
  Rect _getPaddedFaceRect(Rect faceRect, int imageWidth, int imageHeight) {
    // Add 20% padding around the face
    final centerX = faceRect.left + faceRect.width / 2;
    final centerY = faceRect.top + faceRect.height / 2;
    
    final paddedWidth = faceRect.width * 1.2;
    final paddedHeight = faceRect.height * 1.2;
    
    final left = (centerX - paddedWidth / 2).clamp(0.0, imageWidth.toDouble());
    final top = (centerY - paddedHeight / 2).clamp(0.0, imageHeight.toDouble());
    final right = (centerX + paddedWidth / 2).clamp(0.0, imageWidth.toDouble());
    final bottom = (centerY + paddedHeight / 2).clamp(0.0, imageHeight.toDouble());
    
    return Rect.fromLTRB(left, top, right, bottom);
  }
  
  // Convert CameraImage to img.Image
  Future<img.Image?> _convertCameraImageToImage(CameraImage cameraImage) async {
    try {
      // Handle YUV420 format (most common for camera images)
      if (cameraImage.format.group == ImageFormatGroup.yuv420) {
        final width = cameraImage.width;
        final height = cameraImage.height;
        
        // Create RGB image
        final rgbImage = img.Image(width: width, height: height);
        
        // YUV420 to RGB conversion
        final yPlane = cameraImage.planes[0].bytes;
        final uPlane = cameraImage.planes[1].bytes;
        final vPlane = cameraImage.planes[2].bytes;
        
        final yRowStride = cameraImage.planes[0].bytesPerRow;
        final uvRowStride = cameraImage.planes[1].bytesPerRow;
        final uvPixelStride = cameraImage.planes[1].bytesPerPixel ?? 1;
        
        // Convert YUV to RGB
        for (int y = 0; y < height; y++) {
          for (int x = 0; x < width; x++) {
            final yIndex = y * yRowStride + x;
            final uvIndex = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;
            
            // YUV to RGB conversion
            int Y = yPlane[yIndex];
            int U = uPlane[uvIndex];
            int V = vPlane[uvIndex];
            
            // Convert YUV to RGB using standard formula
            int r = (Y + 1.402 * (V - 128)).round().clamp(0, 255);
            int g = (Y - 0.344136 * (U - 128) - 0.714136 * (V - 128)).round().clamp(0, 255);
            int b = (Y + 1.772 * (U - 128)).round().clamp(0, 255);
            
            // Set the RGB pixel
            rgbImage.setPixelRgb(x, y, r, g, b);
          }
        }
        
        return rgbImage;
      } else if (cameraImage.format.group == ImageFormatGroup.bgra8888) {
        // Handle BGRA format
        final width = cameraImage.width;
        final height = cameraImage.height;
        final bytes = cameraImage.planes[0].bytes;
        final bytesPerRow = cameraImage.planes[0].bytesPerRow;
        
        // Create RGB image
        final rgbImage = img.Image(width: width, height: height);
        
        // Convert BGRA to RGB
        for (int y = 0; y < height; y++) {
          for (int x = 0; x < width; x++) {
            final pixelIndex = y * bytesPerRow + x * 4;
            final b = bytes[pixelIndex];
            final g = bytes[pixelIndex + 1];
            final r = bytes[pixelIndex + 2];
            
            // Set the RGB pixel
            rgbImage.setPixelRgb(x, y, r, g, b);
          }
        }
        
        return rgbImage;
      }
      
      print('Unsupported image format: ${cameraImage.format.group}');
      return null;
    } catch (e) {
      print('Error converting camera image: $e');
      return null;
    }
  }
  
  // Compare two face embeddings and return a similarity score
  double compareFaces(List<double> embedding1, List<double> embedding2) {
    if (embedding1.length != embedding2.length) {
      throw Exception('Embedding dimensions do not match');
    }
    
    // Calculate cosine similarity
    double dotProduct = 0.0;
    double norm1 = 0.0;
    double norm2 = 0.0;
    
    for (int i = 0; i < embedding1.length; i++) {
      dotProduct += embedding1[i] * embedding2[i];
      norm1 += embedding1[i] * embedding1[i];
      norm2 += embedding2[i] * embedding2[i];
    }
    
    // Avoid division by zero
    if (norm1 == 0 || norm2 == 0) return 0.0;
    
    return dotProduct / (math.sqrt(norm1) * math.sqrt(norm2));
  }
  
  // Check if two faces match based on a threshold
  bool isFaceMatch(List<double> embedding1, List<double> embedding2, {double threshold = 0.70}) {
    final similarity = compareFaces(embedding1, embedding2);
    return similarity >= threshold;
  }
  
  // Find best match from multiple embeddings
  Map<String, dynamic> findBestMatch(
    List<double> queryEmbedding, 
    Map<String, List<double>> registeredEmbeddings,
    {double threshold = 0.70}
  ) {
    String bestMatchId = '';
    double bestMatchScore = 0.0;
    bool isMatch = false;
    
    for (final entry in registeredEmbeddings.entries) {
      final similarity = compareFaces(queryEmbedding, entry.value);
      if (similarity > bestMatchScore) {
        bestMatchScore = similarity;
        bestMatchId = entry.key;
        isMatch = similarity >= threshold;
      }
    }
    
    return {
      'isMatch': isMatch,
      'matchId': bestMatchId,
      'score': bestMatchScore,
    };
  }
  
  // Geometric face matching as fallback when TFLite model fails
  // This compares faces based on their geometric properties
  Map<String, dynamic> findBestGeometricMatch(
    String queryFaceData,
    Map<String, String> registeredFaceData,
    {double threshold = 0.65} // Slightly lower threshold for geometric matching
  ) {
    String bestMatchId = '';
    double bestMatchScore = 0.0;
    bool isMatch = false;
    
    // Parse the query face data
    final queryFaceParams = _parseFallbackFaceData(queryFaceData);
    if (queryFaceParams == null) {
      return {
        'isMatch': false,
        'matchId': '',
        'score': 0.0,
        'method': 'geometric_failed',
      };
    }
    
    for (final entry in registeredFaceData.entries) {
      final registeredFaceParams = _parseFallbackFaceData(entry.value);
      if (registeredFaceParams == null) continue;
      
      final similarity = _compareGeometricFaceData(queryFaceParams, registeredFaceParams);
      if (similarity > bestMatchScore) {
        bestMatchScore = similarity;
        bestMatchId = entry.key;
        isMatch = similarity >= threshold;
      }
    }
    
    return {
      'isMatch': isMatch,
      'matchId': bestMatchId,
      'score': bestMatchScore,
      'method': 'geometric',
    };
  }
  
  // Parse fallback face data string into a map of parameters
  Map<String, double>? _parseFallbackFaceData(String faceData) {
    try {
      // Format: face_left_top_width_height_angleY_angleZ_timestamp
      final parts = faceData.split('_');
      if (parts.length < 8 || parts[0] != 'face') return null;
      
      return {
        'left': double.parse(parts[1]),
        'top': double.parse(parts[2]),
        'width': double.parse(parts[3]),
        'height': double.parse(parts[4]),
        'angleY': double.parse(parts[5]),
        'angleZ': double.parse(parts[6]),
        'timestamp': double.parse(parts[7]),
      };
    } catch (e) {
      print('Error parsing fallback face data: $e');
      return null;
    }
  }
  
  // Compare two faces based on their geometric properties
  double _compareGeometricFaceData(Map<String, double> face1, Map<String, double> face2) {
    // Calculate similarity based on face size, position, and angles
    
    // 1. Size similarity (face dimensions)
    final sizeSimilarity = _calculateSizeSimilarity(
      face1['width']!, face1['height']!,
      face2['width']!, face2['height']!
    );
    
    // 2. Position similarity (face position in frame)
    final positionSimilarity = _calculatePositionSimilarity(
      face1['left']!, face1['top']!,
      face2['left']!, face2['top']!
    );
    
    // 3. Angle similarity (face orientation)
    final angleSimilarity = _calculateAngleSimilarity(
      face1['angleY']!, face1['angleZ']!,
      face2['angleY']!, face2['angleZ']!
    );
    
    // Weighted combination of similarities
    // Give more weight to angle similarity as it's more distinctive
    return sizeSimilarity * 0.3 + positionSimilarity * 0.2 + angleSimilarity * 0.5;
  }
  
  // Calculate similarity between face sizes
  double _calculateSizeSimilarity(double width1, double height1, double width2, double height2) {
    // Calculate area ratio
    final area1 = width1 * height1;
    final area2 = width2 * height2;
    
    final ratio = area1 > area2 ? area2 / area1 : area1 / area2;
    
    // Calculate aspect ratio similarity
    final aspectRatio1 = width1 / height1;
    final aspectRatio2 = width2 / height2;
    
    final aspectRatioSimilarity = 1.0 - (aspectRatio1 - aspectRatio2).abs() / math.max(aspectRatio1, aspectRatio2);
    
    // Combine area ratio and aspect ratio similarity
    return (ratio * 0.7 + aspectRatioSimilarity * 0.3).clamp(0.0, 1.0);
  }
  
  // Calculate similarity between face positions
  double _calculatePositionSimilarity(double left1, double top1, double left2, double top2) {
    // Calculate normalized Euclidean distance
    final distance = math.sqrt(math.pow(left1 - left2, 2) + math.pow(top1 - top2, 2));
    
    // Convert distance to similarity (closer = more similar)
    // Normalize by assuming max screen dimension is 1000px
    final maxDistance = 1000.0;
    final similarity = 1.0 - (distance / maxDistance).clamp(0.0, 1.0);
    
    return similarity;
  }
  
  // Calculate similarity between face angles
  double _calculateAngleSimilarity(double angleY1, double angleZ1, double angleY2, double angleZ2) {
    // Calculate angle differences
    final yDiff = (angleY1 - angleY2).abs();
    final zDiff = (angleZ1 - angleZ2).abs();
    
    // Convert to similarity (smaller difference = more similar)
    // Normalize by assuming max angle difference is 90 degrees
    final ySimilarity = 1.0 - (yDiff / 90.0).clamp(0.0, 1.0);
    final zSimilarity = 1.0 - (zDiff / 90.0).clamp(0.0, 1.0);
    
    // Combine Y and Z angle similarities
    return (ySimilarity * 0.6 + zSimilarity * 0.4).clamp(0.0, 1.0);
  }
  
  // Convert face embedding to a string for storage
  String embeddingToString(List<double> embedding) {
    return embedding.join(',');
  }
  
  // Convert string back to face embedding
  List<double> stringToEmbedding(String embeddingString) {
    return embeddingString.split(',').map((e) => double.parse(e)).toList();
  }
  
  // Process a face from an image file
  Future<List<double>?> processImageFile(File imageFile) async {
    // Try to initialize if not already initialized
    if (!_isInitialized) {
      await initialize();
      
      // If initialization failed, return null and use fallback
      if (!_isInitialized) {
        print('Face recognition model not initialized, using fallback behavior for image file');
        return null;
      }
    }
    
    try {
      // Read image file
      final bytes = await imageFile.readAsBytes();
      final image = img.decodeImage(bytes);
      
      if (image == null) {
        print('Failed to decode image');
        return null;
      }
      
      // Detect faces in the image
      final inputImage = InputImage.fromFilePath(imageFile.path);
      final faces = await _faceDetector.processImage(inputImage);
      
      if (faces.isEmpty) {
        print('No face detected in the image');
        return null;
      }
      
      // Use the largest face (assuming it's the main subject)
      Face largestFace = faces.first;
      double largestArea = largestFace.boundingBox.width * largestFace.boundingBox.height;
      
      for (final face in faces) {
        final area = face.boundingBox.width * face.boundingBox.height;
        if (area > largestArea) {
          largestFace = face;
          largestArea = area;
        }
      }
      
      // Crop and process the face
      final faceRect = _getPaddedFaceRect(
        largestFace.boundingBox, 
        image.width, 
        image.height
      );
      
      final croppedFace = img.copyCrop(
        image,
        x: faceRect.left.toInt(),
        y: faceRect.top.toInt(),
        width: faceRect.width.toInt(),
        height: faceRect.height.toInt(),
      );
      
      // Resize to the input size expected by the model
      final resizedFace = img.copyResize(
        croppedFace,
        width: inputSize,
        height: inputSize,
        interpolation: img.Interpolation.cubic,
      );
      
      // Convert to float tensor [1, 112, 112, 3] with values normalized to [-1, 1]
      final tensor = List.generate(
        1,
        (_) => List.generate(
          inputSize,
          (y) => List.generate(
            inputSize,
            (x) => List<double>.filled(3, 0),
          ),
        ),
      );
      
      // Fill tensor with normalized pixel values
      for (int y = 0; y < inputSize; y++) {
        for (int x = 0; x < inputSize; x++) {
          final pixel = resizedFace.getPixel(x, y);
          // Normalize to [-1, 1] range
          tensor[0][y][x][0] = (pixel.r / 127.5) - 1.0; // R
          tensor[0][y][x][1] = (pixel.g / 127.5) - 1.0; // G
          tensor[0][y][x][2] = (pixel.b / 127.5) - 1.0; // B
        }
      }
      
      // Prepare output tensor
      final outputTensor = List<double>.filled(embeddingSize, 0).reshape([1, embeddingSize]);
      
      // Run inference
      _interpreter.run(tensor, outputTensor);
      
      // Get the embedding from the output tensor
      final embedding = List<double>.from(outputTensor[0]);
      
      // Normalize the embedding
      return _normalizeEmbedding(embedding);
    } catch (e) {
      print('Error processing image file: $e');
      return null;
    }
  }
  
  // Clean up resources
  void dispose() {
    if (_isInitialized) {
      _interpreter.close();
      _faceDetector.close();
    }
  }
}
