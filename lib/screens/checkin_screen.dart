import 'package:attendance_app/models/user_model.dart';
import 'package:attendance_app/screens/face_scan_screen.dart'; // Import FaceScanScreen
import 'package:attendance_app/services/face_recognition_service.dart'; // Import FaceRecognitionService
import 'package:attendance_app/services/location_service.dart';
import 'package:attendance_app/services/user_service.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

class CheckinScreen extends StatefulWidget {
  final String userName;
  final String cccd;

  const CheckinScreen({super.key, this.userName = '', this.cccd = ''});

  @override
  State<CheckinScreen> createState() => _CheckinScreenState();
}

class _CheckinScreenState extends State<CheckinScreen> {
  String _checkinMessage = '';
  bool _isCheckingIn = false;
  User? _userData;
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    if (widget.cccd.isNotEmpty) {
      _loadUserData(widget.cccd);
    } else {
      // Start face scanning immediately if no CCCD is provided
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startFaceScan();
      });
    }
  }

  Future<void> _startFaceScan() async {
    setState(() {
      _isCheckingIn = true;
      _checkinMessage = 'Đang quét khuôn mặt...';
    });

    bool faceVerified = await _verifyFace();

    if (!faceVerified) {
      setState(() {
        _checkinMessage = 'Xác thực khuôn mặt thất bại.';
        _isCheckingIn = false;
      });
    }

    // The _verifyFace method will handle the rest of the process
    // including finding the user and performing check-in
  }

  Future<void> _loadUserData(String cccd) async {
    setState(() {
      _isSearching = true;
    });

    if (cccd.isNotEmpty) {
      User? user = await UserService.findUserByCCCD(cccd);
      if (user != null) {
        setState(() {
          _userData = user;
          _isSearching = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Tìm thấy người dùng: ${user.name}'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        setState(() {
          _isSearching = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Không tìm thấy người dùng với CCCD này'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } else {
      setState(() {
        _isSearching = false;
      });
    }
  }

  Future<bool> _verifyFace() async {
    print("Navigating to Face Scan Screen for verification...");
    // Navigate to the FaceScanScreen and wait for a result
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => const FaceScanScreen(isIdentifying: true),
      ),
    );

    // Check if a face was detected
    if (result != null && result['faceDetected'] == true) {
      print("[leduytuanvu] Face detected for verification.");
      
      // Extract face data and embeddings from the result
      String? scannedFaceData = result['faceData'];
      List<List<double>>? faceEmbeddings;
      
      // Check if we have embeddings
      if (result['faceEmbeddings'] != null) {
        try {
          // Convert dynamic list to List<List<double>>
          faceEmbeddings = (result['faceEmbeddings'] as List)
              .map((embedding) => (embedding as List).map((e) => e as double).toList())
              .toList();
          
          print("[leduytuanvu] Got ${faceEmbeddings.length} face embeddings");
        } catch (e) {
          print("[leduytuanvu] Error converting embeddings: $e");
          faceEmbeddings = null;
        }
      }
      
      if (scannedFaceData != null) {
        print('[leduytuanvu] Scanned face data: $scannedFaceData');
        
        // Use the new multi-method approach to find the user
        User? matchedUser = await UserService.findUserByFaceDataMultiMethod(
          scannedFaceData,
          faceEmbeddings,
          cccd: result['cccd'],
          // Use standard thresholds for single-angle scans
          threshold: 0.70,
          geometricThreshold: 0.65,
        );

        if (matchedUser != null) {
          setState(() {
            _userData = matchedUser;
          });

          // User found, proceed with check-in
          _performCheckinWithUser(matchedUser);
          return true;
        }
        
        // Debug: Print all stored face data
        List<User> allUsers = await UserService.getUsers();
        for (var u in allUsers) {
          print('[leduytuanvu] Stored faceData for ${u.name}: ${u.faceData}');
        }
      }

      // Face detected but no user found - show message that face is not registered
      setState(() {
        _checkinMessage = 'Khuôn mặt chưa được đăng ký trong hệ thống. Vui lòng đăng ký trước khi điểm danh.';
        _isCheckingIn = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Khuôn mặt chưa được đăng ký!'),
          backgroundColor: Colors.red,
        ),
      );
      
      return false;
    } else {
      print(
          "[leduytuanvu] Face not detected or scan cancelled during verification.");
      return false;
    }
  }

  // Face recognition service
  final FaceRecognitionService _faceRecognitionService =
      FaceRecognitionService();

  // Face matching using TensorFlow Lite
  bool _isFaceMatch(String scannedFaceData, String storedFaceData) {
    try {
      // Check if the data is in embedding format (comma-separated values)
      if (scannedFaceData.contains(',') && storedFaceData.contains(',')) {
        // Convert string embeddings back to List<double>
        List<double> scannedEmbedding = _faceRecognitionService.stringToEmbedding(scannedFaceData);
        List<double> storedEmbedding = _faceRecognitionService.stringToEmbedding(storedFaceData);
        
        // Use the face recognition service to compare embeddings
        // Lower threshold (0.65) for Asian faces to improve recognition
        return _faceRecognitionService.isFaceMatch(scannedEmbedding, storedEmbedding, threshold: 0.65);
      } 
      
      // Fallback to dimension-based comparison for legacy data
      if (scannedFaceData.startsWith('face_') && storedFaceData.startsWith('face_')) {
        List<String> scannedParts = scannedFaceData.split('_');
        List<String> storedParts = storedFaceData.split('_');

        if (scannedParts.length < 6 || storedParts.length < 6) return false;

        // Extract face dimensions
        double scannedWidth = double.parse(scannedParts[3]);
        double storedWidth = double.parse(storedParts[3]);

        double scannedHeight = double.parse(scannedParts[4]);
        double storedHeight = double.parse(storedParts[4]);

        // Calculate differences with increased tolerance for Asian faces
        double widthDiff = (scannedWidth - storedWidth).abs();
        double heightDiff = (scannedHeight - storedHeight).abs();

        // Using a larger tolerance for better matching of Asian faces
        return widthDiff < 25.0 && heightDiff < 25.0;
      }
      
      // If format is unknown, return false
      return false;
    } catch (e) {
      print("Error matching faces: $e");
      return false;
    }
  }

  Future<void> _performCheckin() async {
    // Start with face verification which will also identify the user
    setState(() {
      _isCheckingIn = true;
      _checkinMessage = 'Đang kiểm tra...';
    });

    await _verifyFace();

    // The _verifyFace method will handle the rest of the check-in process
    // including calling _performCheckinWithUser if a user is found

    setState(() {
      _isCheckingIn = false;
    });
  }

  Future<void> _performCheckinWithUser(User user) async {
    // Check if widget is still mounted before setting state
    if (!mounted) return;
    
    setState(() {
      _isCheckingIn = true;
      _checkinMessage = 'Đang kiểm tra...';
    });

    // Get GPS Location
    Position? position = await LocationService.getCurrentPosition();
    if (position == null) {
      // Check if widget is still mounted before setting state
      if (!mounted) return;
      
      setState(() {
        _checkinMessage =
            'Failed to get location. Please check your location settings.';
        _isCheckingIn = false;
      });
      return;
    }

    // Get detailed address components from coordinates
    Map<String, String> addressComponents =
        await LocationService.getDetailedAddressComponents(
      position.latitude,
      position.longitude,
    );

    // Check if widget is still mounted before proceeding
    if (!mounted) return;

    // Format Success Message
    String currentTime =
        DateFormat('HH:mm:ss dd/MM/yyyy').format(DateTime.now());
    String locationInfo =
        'Lat: ${position.latitude.toStringAsFixed(4)}, Lon: ${position.longitude.toStringAsFixed(4)}';

    // Get user info
    String userName = user.name;
    String userDob = user.dob;
    String userCccd = user.cccd;

    // Build detailed message with enhanced address information
    String detailedMessage =
        'Xin chào $userName đã điểm danh lúc $currentTime\n';

    if (userDob.isNotEmpty) {
      detailedMessage += 'Ngày sinh: $userDob\n';
    }

    if (userCccd.isNotEmpty) {
      detailedMessage += 'CCCD: $userCccd\n';
    }

    // Add detailed address components
    detailedMessage += 'Địa chỉ: ${addressComponents['fullAddress']}\n';

    // Add specific address components if available
    if (addressComponents['houseNumber']?.isNotEmpty == true) {
      detailedMessage += 'Số nhà: ${addressComponents['houseNumber']}\n';
    }

    if (addressComponents['street']?.isNotEmpty == true) {
      detailedMessage += 'Đường: ${addressComponents['street']}\n';
    }

    if (addressComponents['ward']?.isNotEmpty == true) {
      detailedMessage += 'Phường/Xã: ${addressComponents['ward']}\n';
    }

    if (addressComponents['district']?.isNotEmpty == true) {
      detailedMessage += 'Quận/Huyện: ${addressComponents['district']}\n';
    }

    if (addressComponents['city']?.isNotEmpty == true) {
      detailedMessage += 'Thành phố/Tỉnh: ${addressComponents['city']}\n';
    }

    detailedMessage += 'Tọa độ: $locationInfo';

    // Save the address components with the user for future reference
    User updatedUser = User(
      name: user.name,
      dob: user.dob,
      cccd: user.cccd,
      faceScanned: user.faceScanned,
      faceData: user.faceData,
      allFaceData: user.allFaceData,
      registeredAt: user.registeredAt,
      addressComponents: addressComponents,
    );

    // Update user in storage with the latest location
    await UserService.saveUser(
        updatedUser); // Using saveUser instead of updateUser

    // Check if widget is still mounted before setting state
    if (!mounted) return;
    
    setState(() {
      _checkinMessage = detailedMessage;
      _isCheckingIn = false;
      _userData = updatedUser; // Update the local user data
    });

    // Check if widget is still mounted before showing snackbar
    if (!mounted) return;
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Điểm danh thành công!',
          textAlign: TextAlign.center,
        ),
        backgroundColor: Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Điểm danh'),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              // Check-in Button or Progress Indicator
              if (_isCheckingIn)
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 30),
                  child: const CircularProgressIndicator(),
                ),
              Expanded(
                child: SingleChildScrollView(
                  child: _checkinMessage.isEmpty
                      ? const SizedBox()
                      : _checkinMessage.contains('Xin chào')
                          ? _buildSuccessCheckinCard()
                          : Text(
                              _checkinMessage,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 16),
                            ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSuccessCheckinCard() {
    // Get user info directly from userData or widget parameters
    String userName = _userData?.name ?? widget.userName;

    // Extract information from check-in message
    List<String> lines = _checkinMessage.split('\n');

    // Default values in case parsing fails
    String checkinTime = '';
    String address = '';
    String coordinates = '';

    // Parse each line to extract information
    for (String line in lines) {
      if (line.contains('điểm danh lúc')) {
        // Extract time from "Xin chào [name] đã điểm danh lúc [time]"
        final parts = line.split('điểm danh lúc');
        if (parts.length > 1) {
          checkinTime = parts[1].trim();
        }
      } else if (line.startsWith('Địa chỉ:')) {
        address = line.substring('Địa chỉ:'.length).trim();
      } else if (line.startsWith('Tọa độ:')) {
        coordinates = line.substring('Tọa độ:'.length).trim();
      }
    }

    return Card(
      elevation: 4,
      color: Colors.green[50],
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Success header
            Center(
              child: Column(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 36),
                  const SizedBox(height: 8),
                  Text(
                    'Điểm danh thành công!',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: Colors.green[800],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(thickness: 1),
            const SizedBox(height: 12),

            // Simplified user information section with larger text
            Text(
              'Xin chào $userName đã điểm danh lúc $checkinTime tại $address',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
