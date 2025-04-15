import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_model.dart';
import '../services/face_recognition_service.dart';

class UserService {
  static const String _usersKey = 'users';

  // Save a user to SharedPreferences
  static Future<bool> saveUser(User user) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Get existing users
      List<User> users = await getUsers();

      // Check if user with same CCCD already exists
      int existingIndex = users.indexWhere((u) => u.cccd == user.cccd);
      if (existingIndex != -1) {
        // Replace existing user
        users[existingIndex] = user;
      } else {
        // Add new user
        users.add(user);
      }

      // Convert users to JSON string and save
      List<String> usersJson =
          users.map((u) => jsonEncode(u.toJson())).toList();
      await prefs.setStringList(_usersKey, usersJson);

      return true;
    } catch (e) {
      print('Error saving user: $e');
      return false;
    }
  }

  // Get all users from SharedPreferences
  static Future<List<User>> getUsers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String>? usersJson = prefs.getStringList(_usersKey);

      if (usersJson == null || usersJson.isEmpty) {
        return [];
      }

      return usersJson
          .map((userJson) => User.fromJson(jsonDecode(userJson)))
          .toList();
    } catch (e) {
      print('Error getting users: $e');
      return [];
    }
  }

  // Find a user by CCCD
  static Future<User?> findUserByCCCD(String cccd) async {
    try {
      List<User> users = await getUsers();
      return users.firstWhere(
        (user) => user.cccd == cccd,
        orElse: () => throw Exception('User not found'),
      );
    } catch (e) {
      print('Error finding user: $e');
      return null;
    }
  }

  // Find a user by face data
  static Future<User?> findUserByFaceData(String faceData,
      {bool Function(String, String)? matchFunction}) async {
    try {
      List<User> users = await getUsers();

      // If a custom match function is provided, use it
      if (matchFunction != null) {
        for (User user in users) {
          if (user.faceData != null &&
              matchFunction(faceData, user.faceData!)) {
            return user;
          }
        }
        return null;
      }

      // Otherwise, look for an exact match
      return users.firstWhere(
        (user) => user.faceData == faceData,
        orElse: () => throw Exception('User not found'),
      );
    } catch (e) {
      print('Error finding user by face data: $e');
      return null;
    }
  }
  
  // Find a user by face data using geometric matching
  // This is used when the TFLite model fails to load
  static Future<User?> findUserByGeometricFaceMatch(String faceData, {double threshold = 0.65}) async {
    try {
      print('[leduytuanvu] Finding user by geometric face match');
      List<User> users = await getUsers();
      
      // Create a map of user IDs to face data strings for all users
      Map<String, String> registeredFaceData = {};
      for (User user in users) {
        if (user.faceData != null) {
          registeredFaceData[user.cccd] = user.faceData!;
        }
      }
      
      // Use the FaceRecognitionService to find the best geometric match
      final faceRecognitionService = FaceRecognitionService();
      final matchResult = faceRecognitionService.findBestGeometricMatch(
        faceData, 
        registeredFaceData,
        threshold: threshold
      );
      
      print('[leduytuanvu] Geometric match result: $matchResult');
      
      // If a match was found, return the corresponding user
      if (matchResult['isMatch']) {
        String matchId = matchResult['matchId'];
        return users.firstWhere(
          (user) => user.cccd == matchId,
          orElse: () => throw Exception('Matched user not found'),
        );
      }
      
      return null;
    } catch (e) {
      print('Error finding user by geometric face match: $e');
      return null;
    }
  }
  
  // Find a user by face data using multiple methods
  // This tries both embedding-based and geometric matching
  static Future<User?> findUserByFaceDataMultiMethod(
    String faceData,
    List<List<double>>? faceEmbeddings,
    {String? cccd, double threshold = 0.65, double geometricThreshold = 0.60}
  ) async {
    try {
      // If CCCD is provided, try to find the user by CCCD first
      if (cccd != null && cccd.isNotEmpty) {
        final userByCCCD = await findUserByCCCD(cccd);
        if (userByCCCD != null) {
          print('[leduytuanvu] User found by CCCD: ${userByCCCD.name}');
          return userByCCCD;
        }
      }
      
      // If embeddings are provided, try to find the user by embeddings
      if (faceEmbeddings != null && faceEmbeddings.isNotEmpty) {
        final faceRecognitionService = FaceRecognitionService();
        List<User> users = await getUsers();
        
        // For each user with face data, try to convert it to an embedding
        for (User user in users) {
          if (user.faceData == null) continue;
          
          // Check if the user's face data is an embedding string
          if (user.faceData!.contains(',')) {
            try {
              // Convert the user's face data to an embedding
              final userEmbedding = faceRecognitionService.stringToEmbedding(user.faceData!);
              
              // Compare with each of the query embeddings
              for (final queryEmbedding in faceEmbeddings) {
                final similarity = faceRecognitionService.compareFaces(queryEmbedding, userEmbedding);
                print('[leduytuanvu] Embedding similarity with ${user.name}: $similarity');
                
                if (similarity >= threshold) {
                  print('[leduytuanvu] User found by embedding: ${user.name}');
                  return user;
                }
              }
            } catch (e) {
              print('Error converting user face data to embedding: $e');
              // Continue to the next user if this one fails
            }
          }
        }
      }
      
      // If no match found by embeddings, try geometric matching
      final userByGeometric = await findUserByGeometricFaceMatch(faceData, threshold: geometricThreshold);
      if (userByGeometric != null) {
        print('[leduytuanvu] User found by geometric matching: ${userByGeometric.name}');
        return userByGeometric;
      }
      
      // If still no match, try exact match as a last resort
      final userByExact = await findUserByFaceData(faceData);
      if (userByExact != null) {
        print('[leduytuanvu] User found by exact match: ${userByExact.name}');
        return userByExact;
      }
      
      return null;
    } catch (e) {
      print('Error finding user by multi-method: $e');
      return null;
    }
  }

  // Delete a user by CCCD
  static Future<bool> deleteUser(String cccd) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      List<User> users = await getUsers();
      users.removeWhere((user) => user.cccd == cccd);

      List<String> usersJson =
          users.map((u) => jsonEncode(u.toJson())).toList();
      await prefs.setStringList(_usersKey, usersJson);

      return true;
    } catch (e) {
      print('Error deleting user: $e');
      return false;
    }
  }

  // Delete all users
  static Future<bool> deleteAllUsers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_usersKey); // Xóa key 'users'
      return true;
    } catch (e) {
      print('Error deleting all users: $e');
      return false;
    }
  }
}
