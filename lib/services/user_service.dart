import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_model.dart';

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
      List<String> usersJson = users.map((u) => jsonEncode(u.toJson())).toList();
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
          if (user.faceData != null && matchFunction(faceData, user.faceData!)) {
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

  // Delete a user by CCCD
  static Future<bool> deleteUser(String cccd) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      List<User> users = await getUsers();
      users.removeWhere((user) => user.cccd == cccd);
      
      List<String> usersJson = users.map((u) => jsonEncode(u.toJson())).toList();
      await prefs.setStringList(_usersKey, usersJson);
      
      return true;
    } catch (e) {
      print('Error deleting user: $e');
      return false;
    }
  }
}
