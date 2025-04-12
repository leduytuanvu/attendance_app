import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:collection'; // Add this import for UnmodifiableUint8ListView
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
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
  
  // Face detector from ML Kit
  final _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      enableLandmarks: true,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );
  
  // Model configurations
  final int inputSize = 112; // Face model input size
  final int embeddingSize = 128; // Size of face embedding vector
  
  // Initialize the TensorFlow Lite model
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      // Load the TFLite model
      final options = InterpreterOptions();
      
      // In a real app, you would download a pre-trained face recognition model
      // For this example, we'll create a placeholder for the model
      final modelPath = await _getModelPath();
      
      _interpreter = await Interpreter.fromFile(File(modelPath), options: options);
      _isInitialized = true;
      
      print('Face recognition model initialized successfully');
    } catch (e) {
      print('Error initializing face recognition model: $e');
      // For demo purposes, we'll still set initialized to true
      // In a real app, you would handle this error properly
      _isInitialized = true;
    }
  }
  
  // Get the path to the TFLite model
  Future<String> _getModelPath() async {
    // In a real app, you would download a pre-trained model
    // For this example, we'll create a placeholder file
    final directory = await getApplicationDocumentsDirectory();
    final modelPath = '${directory.path}/face_recognition_model.tflite';
    
    // Check if the model file exists
    if (!File(modelPath).existsSync()) {
      // Create a placeholder file
      // In a real app, you would download the model from a server
      await File(modelPath).writeAsBytes(Uint8List(0));
    }
    
    return modelPath;
  }
  
  // Process a camera image and extract face embeddings
  Future<List<double>?> getFaceEmbedding(CameraImage cameraImage, Face face) async {
    if (!_isInitialized) await initialize();
    
    try {
      // Convert CameraImage to format suitable for TensorFlow Lite
      final inputImage = _preprocessFace(cameraImage, face);
      if (inputImage == null) return null;
      
      // Run inference
      final output = List<double>.filled(embeddingSize, 0).reshape([1, embeddingSize]);
      
      // In a real app, you would run the model on the input image
      // For this example, we'll generate a random embedding
      final embedding = List<double>.generate(embeddingSize, (i) => i.toDouble() / embeddingSize);
      
      return embedding;
    } catch (e) {
      print('Error getting face embedding: $e');
      return null;
    }
  }
  
  // Preprocess the face for the TensorFlow Lite model
  Uint8List? _preprocessFace(CameraImage cameraImage, Face face) {
    try {
      // Convert CameraImage to img.Image
      img.Image? image = _convertCameraImageToImage(cameraImage);
      if (image == null) return null;
      
      // Crop the face from the image
      final faceRect = face.boundingBox;
      final croppedFace = img.copyCrop(
        image,
        x: faceRect.left.toInt().clamp(0, image.width - 1),
        y: faceRect.top.toInt().clamp(0, image.height - 1),
        width: faceRect.width.toInt().clamp(1, image.width),
        height: faceRect.height.toInt().clamp(1, image.height),
      );
      
      // Resize to the input size expected by the model
      final resizedFace = img.copyResize(
        croppedFace,
        width: inputSize,
        height: inputSize,
      );
      
      // Convert to bytes
      return Uint8List.fromList(img.encodePng(resizedFace));
    } catch (e) {
      print('Error preprocessing face: $e');
      return null;
    }
  }
  
  // Convert CameraImage to img.Image
  img.Image? _convertCameraImageToImage(CameraImage cameraImage) {
    try {
      // This is a simplified conversion - in a real app, you would handle different image formats
      if (cameraImage.format.group == ImageFormatGroup.yuv420) {
        final width = cameraImage.width;
        final height = cameraImage.height;
        
        // Create a new image
        final image = img.Image(width: width, height: height);
        
        // In a real app, you would convert YUV to RGB
        // For this example, we'll create a placeholder image
        return image;
      }
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
  bool isFaceMatch(List<double> embedding1, List<double> embedding2, {double threshold = 0.7}) {
    final similarity = compareFaces(embedding1, embedding2);
    return similarity >= threshold;
  }
  
  // Convert face embedding to a string for storage
  String embeddingToString(List<double> embedding) {
    return embedding.join(',');
  }
  
  // Convert string back to face embedding
  List<double> stringToEmbedding(String embeddingString) {
    return embeddingString.split(',').map((e) => double.parse(e)).toList();
  }
  
  // Clean up resources
  void dispose() {
    if (_isInitialized) {
      _interpreter.close();
      _faceDetector.close();
    }
  }
}
