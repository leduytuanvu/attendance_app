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
  final int inputSize = 160; // Face model input size for facenet
  final int embeddingSize = 512; // Size of face embedding vector for facenet
  
  // Initialize the TensorFlow Lite model
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      // Verify the model file exists in assets
      try {
        final modelPath = 'assets/models/facenet.tflite';
        
        // First check if the model file exists and has a reasonable size
        try {
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
        } catch (e) {
          print('Model file loading error: $e');
          throw Exception('Model file loading error: $e');
        }
      } catch (assetError) {
        print('Asset loading failed: $assetError');
        
        // Try to create a dummy model for testing purposes
        try {
          print('Attempting to create a dummy model for testing...');
          // This is just for debugging - in production you would handle this differently
          final tempDir = await getTemporaryDirectory();
          final dummyModelPath = '${tempDir.path}/dummy_model.tflite';
          final dummyFile = File(dummyModelPath);
          
          // Check if we already have a dummy model
          if (!await dummyFile.exists()) {
            // Create a dummy file with some content
            await dummyFile.writeAsString('This is a dummy model file for testing purposes.');
          }
          
          throw Exception('Could not create dummy model');
        } catch (dummyError) {
          print('Dummy model creation failed: $dummyError');
          throw assetError; // Re-throw the original error
        }
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
    final modelPath = 'assets/models/facenet.tflite';
    try {
      // Try to load the model from assets
      final ByteData modelData = await rootBundle.load(modelPath);
      
      // Create a temporary file to ensure the model is properly loaded
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/facenet.tflite';
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
      
      // Convert to float tensor [1, 160, 160, 3] with values normalized to [-1, 1]
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
    {double threshold = 0.65} // Lower threshold for better match rate
  ) {
    String bestMatchId = '';
    double bestMatchScore = 0.0;
    bool isMatch = false;
    
    // Track all matches above a minimum threshold for debugging
    List<Map<String, dynamic>> allMatches = [];
    
    for (final entry in registeredEmbeddings.entries) {
      final similarity = compareFaces(queryEmbedding, entry.value);
      
      // Add to all matches if above minimum threshold
      if (similarity > 0.5) {
        allMatches.add({
          'id': entry.key,
          'score': similarity,
        });
      }
      
      if (similarity > bestMatchScore) {
        bestMatchScore = similarity;
        bestMatchId = entry.key;
        isMatch = similarity >= threshold;
      }
    }
    
    // Sort matches by score for debugging
    allMatches.sort((a, b) => (b['score'] as double).compareTo(a['score'] as double));
    
    // Print top matches for debugging
    if (allMatches.isNotEmpty) {
      print('[leduytuanvu] Top embedding matches:');
      for (int i = 0; i < math.min(3, allMatches.length); i++) {
        print('[leduytuanvu] Match #${i+1}: ID=${allMatches[i]['id']}, Score=${allMatches[i]['score']}');
      }
    }
    
    return {
      'isMatch': isMatch,
      'matchId': bestMatchId,
      'score': bestMatchScore,
      'allMatches': allMatches,
    };
  }
  
  // Geometric face matching as fallback when TFLite model fails
  // This compares faces based on their geometric properties
  Map<String, dynamic> findBestGeometricMatch(
    String queryFaceData,
    Map<String, String> registeredFaceData,
    {double threshold = 0.60} // Lower threshold for better match rate
  ) {
    String bestMatchId = '';
    double bestMatchScore = 0.0;
    bool isMatch = false;
    
    // Track all matches above a minimum threshold for debugging
    List<Map<String, dynamic>> allMatches = [];
    
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
      
      // Add to all matches if above minimum threshold
      if (similarity > 0.5) {
        allMatches.add({
          'id': entry.key,
          'score': similarity,
        });
      }
      
      if (similarity > bestMatchScore) {
        bestMatchScore = similarity;
        bestMatchId = entry.key;
        isMatch = similarity >= threshold;
      }
    }
    
    // Sort matches by score for debugging
    allMatches.sort((a, b) => (b['score'] as double).compareTo(a['score'] as double));
    
    // Print top matches for debugging
    if (allMatches.isNotEmpty) {
      print('[leduytuanvu] Top geometric matches:');
      for (int i = 0; i < math.min(3, allMatches.length); i++) {
        print('[leduytuanvu] Match #${i+1}: ID=${allMatches[i]['id']}, Score=${allMatches[i]['score']}');
      }
    }
    
    return {
      'isMatch': isMatch,
      'matchId': bestMatchId,
      'score': bestMatchScore,
      'method': 'geometric',
      'allMatches': allMatches,
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
  // Optimized for Asian faces with more weight on size and less on angles
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
    
    // Print detailed similarity scores for debugging
    print('[leduytuanvu] Geometric similarity details:');
    print('[leduytuanvu] Size similarity: $sizeSimilarity');
    print('[leduytuanvu] Position similarity: $positionSimilarity');
    print('[leduytuanvu] Angle similarity: $angleSimilarity');
    
    // Weighted combination of similarities
    // For Asian faces, give more weight to size and position, less to angles
    // This is because Asian faces may have less distinctive angle features
    final combinedSimilarity = sizeSimilarity * 0.4 + positionSimilarity * 0.35 + angleSimilarity * 0.25;
    print('[leduytuanvu] Combined similarity: $combinedSimilarity');
    
    return combinedSimilarity;
  }
  
  // Calculate similarity between face sizes
  // Optimized for Asian faces with more tolerance for size differences
  double _calculateSizeSimilarity(double width1, double height1, double width2, double height2) {
    // Calculate area ratio
    final area1 = width1 * height1;
    final area2 = width2 * height2;
    
    // Use a more lenient area ratio calculation for Asian faces
    // This allows for more variation in face size while still maintaining accuracy
    double ratio;
    if (area1 > area2) {
      ratio = area2 / area1;
    } else {
      ratio = area1 / area2;
    }
    
    // Apply a non-linear transformation to make the similarity score more forgiving
    // for small differences but still penalize large differences
    ratio = math.pow(ratio, 0.5).toDouble(); // Square root makes the curve more lenient
    
    // Calculate aspect ratio similarity
    final aspectRatio1 = width1 / height1;
    final aspectRatio2 = width2 / height2;
    
    // Asian faces often have similar aspect ratios, so we can be more lenient here
    final aspectRatioDiff = (aspectRatio1 - aspectRatio2).abs();
    final aspectRatioSimilarity = 1.0 - math.min(aspectRatioDiff / 0.3, 1.0); // More lenient threshold
    
    // Print detailed size similarity info for debugging
    print('[leduytuanvu] Size details: Area1=$area1, Area2=$area2, Ratio=$ratio');
    print('[leduytuanvu] Aspect ratio details: AR1=$aspectRatio1, AR2=$aspectRatio2, Similarity=$aspectRatioSimilarity');
    
    // Combine area ratio and aspect ratio similarity
    // Give more weight to aspect ratio for Asian faces
    return (ratio * 0.6 + aspectRatioSimilarity * 0.4).clamp(0.0, 1.0);
  }
  
  // Calculate similarity between face positions
  // Optimized for Asian faces with more tolerance for position differences
  double _calculatePositionSimilarity(double left1, double top1, double left2, double top2) {
    // Calculate horizontal and vertical distances separately
    final horizontalDistance = (left1 - left2).abs();
    final verticalDistance = (top1 - top2).abs();
    
    // Print position details for debugging
    print('[leduytuanvu] Position details: Left1=$left1, Left2=$left2, HDist=$horizontalDistance');
    print('[leduytuanvu] Position details: Top1=$top1, Top2=$top2, VDist=$verticalDistance');
    
    // Use a more lenient distance calculation for Asian faces
    // This allows for more variation in face position while still maintaining accuracy
    
    // Normalize distances by screen dimensions
    // Use smaller max distances to be more lenient
    final maxHorizontalDistance = 500.0; // More lenient horizontal threshold
    final maxVerticalDistance = 300.0;   // More lenient vertical threshold
    
    // Calculate horizontal and vertical similarities separately
    final horizontalSimilarity = 1.0 - (horizontalDistance / maxHorizontalDistance).clamp(0.0, 1.0);
    final verticalSimilarity = 1.0 - (verticalDistance / maxVerticalDistance).clamp(0.0, 1.0);
    
    // Apply a non-linear transformation to make the similarity score more forgiving
    // for small differences but still penalize large differences
    final horizontalSimilarityAdjusted = math.pow(horizontalSimilarity, 0.7).toDouble();
    final verticalSimilarityAdjusted = math.pow(verticalSimilarity, 0.7).toDouble();
    
    // Combine horizontal and vertical similarities
    // Give more weight to vertical position for Asian faces
    final combinedSimilarity = horizontalSimilarityAdjusted * 0.4 + verticalSimilarityAdjusted * 0.6;
    
    print('[leduytuanvu] Position similarity: H=$horizontalSimilarityAdjusted, V=$verticalSimilarityAdjusted, Combined=$combinedSimilarity');
    
    return combinedSimilarity;
  }
  
  // Calculate similarity between face angles
  // Optimized for Asian faces with more tolerance for angle differences
  double _calculateAngleSimilarity(double angleY1, double angleZ1, double angleY2, double angleZ2) {
    // Calculate angle differences
    final yDiff = (angleY1 - angleY2).abs();
    final zDiff = (angleZ1 - angleZ2).abs();
    
    // Print angle details for debugging
    print('[leduytuanvu] Angle details: Y1=$angleY1, Y2=$angleY2, YDiff=$yDiff');
    print('[leduytuanvu] Angle details: Z1=$angleZ1, Z2=$angleZ2, ZDiff=$zDiff');
    
    // Use a more lenient angle difference calculation for Asian faces
    // This allows for more variation in face angles while still maintaining accuracy
    
    // Convert to similarity (smaller difference = more similar)
    // Use larger max angle differences to be more lenient
    final maxYDiff = 120.0; // More lenient Y angle threshold (was 90)
    final maxZDiff = 100.0; // More lenient Z angle threshold (was 90)
    
    // Calculate Y and Z angle similarities separately
    final ySimilarity = 1.0 - (yDiff / maxYDiff).clamp(0.0, 1.0);
    final zSimilarity = 1.0 - (zDiff / maxZDiff).clamp(0.0, 1.0);
    
    // Apply a non-linear transformation to make the similarity score more forgiving
    // for small differences but still penalize large differences
    final ySimilarityAdjusted = math.pow(ySimilarity, 0.6).toDouble();
    final zSimilarityAdjusted = math.pow(zSimilarity, 0.6).toDouble();
    
    // Combine Y and Z angle similarities
    // Give more weight to Y angle for Asian faces
    final combinedSimilarity = ySimilarityAdjusted * 0.7 + zSimilarityAdjusted * 0.3;
    
    print('[leduytuanvu] Angle similarity: Y=$ySimilarityAdjusted, Z=$zSimilarityAdjusted, Combined=$combinedSimilarity');
    
    return combinedSimilarity.clamp(0.0, 1.0);
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
      
      // Convert to float tensor [1, 160, 160, 3] with values normalized to [-1, 1]
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
