import 'package:attendance_app/models/user_model.dart';
import 'package:attendance_app/screens/checkin_screen.dart'; // Import CheckinScreen
import 'package:attendance_app/screens/face_scan_screen.dart'; // Import FaceScanScreen
import 'package:attendance_app/services/location_service.dart'; // Import LocationService
import 'package:attendance_app/services/user_service.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart'; // Import Geolocator

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _dobController = TextEditingController();
  final _cccdController = TextEditingController();
  // Placeholder for face data - will be updated later
  bool _faceScanned = false; // Use boolean to track scan success
  
  // Removed location data

  @override
  void dispose() {
    _nameController.dispose();
    _dobController.dispose();
    _cccdController.dispose();
    super.dispose();
  }

  Future<void> _selectDate() async {
    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        // Format the date as needed, e.g., YYYY-MM-DD
        _dobController.text =
            "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
      });
    }
  }

  // Store face data for registration
  String? _faceData;
  List<String>? _allFaceData;
  
  // Removed location functionality

  Future<void> _scanFace() async {
    print("Navigating to Face Scan Screen for multi-angle registration...");
    // Navigate to the FaceScanScreen and wait for a result
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (context) => const FaceScanScreen()),
    );

    // Check if the screen returned a successful scan result
    if (result != null &&
        result['success'] == true &&
        result['faceData'] != null) {
      setState(() {
        _faceScanned = true; // Mark face as scanned
        _faceData = result['faceData']; // Store the primary face data

        // Store all face angles data if available
        if (result['allFaceData'] != null) {
          _allFaceData = List<String>.from(result['allFaceData']);
          print(
              "[leduytuanvu] Multiple face angles captured: ${_allFaceData!.length}");
        }
      });

      print("[leduytuanvu] Primary face data received: $_faceData");

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(_allFaceData != null && _allFaceData!.length > 1
                ? 'Face Scan Successful! ${_allFaceData!.length} angles captured.'
                : 'Face Scan Successful!'),
            backgroundColor: Colors.green),
      );
    } else {
      setState(() {
        _faceScanned = false; // Reset if scan failed or was cancelled
        _faceData = null; // Clear face data
        _allFaceData = null; // Clear all face data
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Face Scan Failed or Cancelled.'),
            backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _registerUser() async {
    if (_formKey.currentState!.validate()) {
      if (!_faceScanned) {
        // Check the boolean flag
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please scan your face before registering.')),
        );
        return;
      }

      String name = _nameController.text;
      String dob = _dobController.text;
      String cccd = _cccdController.text;

      // Create a new user object with multi-angle face data (without location)
      User newUser = User(
        name: name,
        dob: dob,
        cccd: cccd,
        faceScanned: _faceScanned,
        faceData: _faceData, // Include the primary face data
        allFaceData: _allFaceData, // Include all face angles data
        registeredAt: DateTime.now(),
        addressComponents: null, // No location data during registration
      );

      // Save user to SharedPreferences
      bool saved = await UserService.saveUser(newUser);

      print('[leduytuanvu] newUser: ${newUser.faceData}');
      print('[leduytuanvu] Save user result: $saved');

      if (!saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save user data. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      print('[leduytuanvu] Registering User:');
      print('[leduytuanvu] Name: $name');
      print('[leduytuanvu] DOB: $dob');
      print('[leduytuanvu] CCCD: $cccd');
      print('[leduytuanvu] Face Scanned: $_faceScanned'); // Print scan status
      if (_allFaceData != null) {
        print('[leduytuanvu] Face angles captured: ${_allFaceData!.length}');
      }

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Registration successful!'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );

      // Clear form after successful registration
      setState(() {
        _nameController.clear();
        _dobController.clear();
        _cccdController.clear();
        _faceScanned = false;
        _faceData = null;
        _allFaceData = null;
      });

      // Option to navigate to CheckinScreen
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Registration Successful'),
            content: const Text('Do you want to check in now?'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context); // Close dialog
                },
                child: const Text('No'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context); // Close dialog
                  // Navigate to CheckinScreen without replacing the RegisterScreen
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) =>
                            CheckinScreen(userName: name, cccd: cccd)),
                  );
                },
                child: const Text('Yes'),
              ),
            ],
          );
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register User'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            // Use ListView for scrollability on smaller screens
            children: [
              TextFormField(
                controller: _nameController,
                decoration:
                    const InputDecoration(labelText: 'Họ và Tên (Name)'),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _dobController,
                decoration: const InputDecoration(
                  labelText: 'Ngày tháng năm sinh (Date of Birth)',
                  hintText: 'YYYY-MM-DD',
                  suffixIcon: Icon(Icons.calendar_today),
                ),
                readOnly: true, // Prevent manual editing
                onTap: _selectDate,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please select your date of birth';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _cccdController,
                decoration:
                    const InputDecoration(labelText: 'CCCD/CMND (Citizen ID)'),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your Citizen ID';
                  }
                  // Add more specific validation if needed
                  return null;
                },
              ),
              const SizedBox(height: 24),
              // Location section removed
              ElevatedButton.icon(
                onPressed: _scanFace,
                icon: Icon(_faceScanned
                    ? Icons.check_circle
                    : Icons.face_retouching_natural),
                label: Text(
                    _faceScanned ? 'Face Scanned Successfully' : 'Scan Face'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _faceScanned
                      ? Colors.green
                      : Theme.of(context)
                          .primaryColor, // Use theme color or green
                  foregroundColor: Colors.white, // Ensure text is visible
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _registerUser,
                child: const Text('Register'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
