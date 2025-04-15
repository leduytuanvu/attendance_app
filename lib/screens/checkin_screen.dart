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

    // Add a post-frame callback to set up navigation prevention
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Prevent the screen from being popped automatically
      // No need to add a will pop callback - allow direct back navigation
      // as requested by the user

      // Start the check-in process
      if (widget.cccd.isNotEmpty) {
        _loadUserData(widget.cccd);
      } else {
        // Start face scanning immediately if no CCCD is provided
        _startFaceScan();
      }
    });
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
    try {
      print("Navigating to Face Scan Screen for verification...");

      // No need to prevent back navigation as requested by the user

      // Navigate to the FaceScanScreen and wait for a result
      final result = await Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
          builder: (context) => const FaceScanScreen(isIdentifying: true),
        ),
      );

      // Check if we're still mounted after returning from face scan
      if (!mounted) {
        print("[leduytuanvu] Widget not mounted after face scan");
        return false;
      }

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
                .map((embedding) =>
                    (embedding as List).map((e) => e as double).toList())
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
            // Check if we're still mounted before updating state
            if (!mounted) return false;

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
        // Check if we're still mounted before updating state
        if (!mounted) return false;

        setState(() {
          _checkinMessage =
              'Khuôn mặt chưa được đăng ký trong hệ thống. Vui lòng đăng ký trước khi điểm danh.';
          _isCheckingIn = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Khuôn mặt chưa được đăng ký!'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 5),
          ),
        );

        return false;
      } else {
        print(
            "[leduytuanvu] Face not detected or scan cancelled during verification.");

        // Check if we're still mounted before updating state
        if (!mounted) return false;

        setState(() {
          _checkinMessage =
              'Quét khuôn mặt bị hủy hoặc không phát hiện khuôn mặt.';
          _isCheckingIn = false;
        });

        return false;
      }
    } catch (e) {
      print("[leduytuanvu] Error during face verification: $e");

      // Check if we're still mounted before updating state
      if (!mounted) return false;

      setState(() {
        _checkinMessage = 'Có lỗi xảy ra khi xác thực khuôn mặt: $e';
        _isCheckingIn = false;
      });

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
        List<double> scannedEmbedding =
            _faceRecognitionService.stringToEmbedding(scannedFaceData);
        List<double> storedEmbedding =
            _faceRecognitionService.stringToEmbedding(storedFaceData);

        // Use the face recognition service to compare embeddings
        // Lower threshold (0.60) for Asian faces to improve recognition
        final similarity = _faceRecognitionService.compareFaces(scannedEmbedding, storedEmbedding);
        print('[leduytuanvu] Embedding similarity: $similarity');
        
        return similarity >= 0.60; // Lower threshold for better matching
      }

      // Fallback to dimension-based comparison for legacy data
      if (scannedFaceData.startsWith('face_') &&
          storedFaceData.startsWith('face_')) {
        List<String> scannedParts = scannedFaceData.split('_');
        List<String> storedParts = storedFaceData.split('_');

        if (scannedParts.length < 6 || storedParts.length < 6) return false;

        // Extract face dimensions
        double scannedWidth = double.parse(scannedParts[3]);
        double storedWidth = double.parse(storedParts[3]);

        double scannedHeight = double.parse(scannedParts[4]);
        double storedHeight = double.parse(storedParts[4]);
        
        double scannedY = double.parse(scannedParts[5]);
        double storedY = double.parse(storedParts[5]);
        
        double scannedZ = double.parse(scannedParts[6]);
        double storedZ = double.parse(storedParts[6]);

        // Calculate differences with increased tolerance for Asian faces
        double widthDiff = (scannedWidth - storedWidth).abs();
        double heightDiff = (scannedHeight - storedHeight).abs();
        
        // Calculate size similarity
        double sizeRatio = (scannedWidth * scannedHeight) / (storedWidth * storedHeight);
        if (sizeRatio > 1.0) sizeRatio = 1.0 / sizeRatio;
        
        // Calculate position similarity
        double leftDiff = (double.parse(scannedParts[1]) - double.parse(storedParts[1])).abs();
        double topDiff = (double.parse(scannedParts[2]) - double.parse(storedParts[2])).abs();
        
        // Calculate angle similarity
        double yDiff = (scannedY - storedY).abs();
        double zDiff = (scannedZ - storedZ).abs();
        
        // Print detailed matching info for debugging
        print('[leduytuanvu] Geometric matching details:');
        print('[leduytuanvu] Width diff: $widthDiff, Height diff: $heightDiff');
        print('[leduytuanvu] Size ratio: $sizeRatio');
        print('[leduytuanvu] Position diff: Left=$leftDiff, Top=$topDiff');
        print('[leduytuanvu] Angle diff: Y=$yDiff, Z=$zDiff');
        
        // Using a more sophisticated matching algorithm for Asian faces
        // Size similarity is most important, followed by position, then angles
        bool isSizeSimilar = sizeRatio > 0.7 && widthDiff < 40.0 && heightDiff < 40.0;
        bool isPositionSimilar = leftDiff < 100.0 && topDiff < 100.0;
        bool isAngleSimilar = yDiff < 120.0 && zDiff < 100.0;
        
        // Combined similarity score
        double combinedScore = (isSizeSimilar ? 0.6 : 0.0) + 
                              (isPositionSimilar ? 0.3 : 0.0) + 
                              (isAngleSimilar ? 0.1 : 0.0);
        
        print('[leduytuanvu] Combined geometric score: $combinedScore');
        
        return combinedScore >= 0.6; // 60% similarity is enough
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

    try {
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

      // Update the UI with the check-in result
      // This is the most important part - we're directly updating the UI state
      // without any navigation that could cause issues
      setState(() {
        _checkinMessage = detailedMessage;
        _isCheckingIn = false;
        _userData = updatedUser; // Update the local user data
      });

      // Check if widget is still mounted before showing snackbar
      if (!mounted) return;

      // Use a more persistent snackbar that doesn't auto-dismiss
      // ScaffoldMessenger.of(context).showSnackBar(
      //   SnackBar(
      //     content: const Text(
      //       'Điểm danh thành công!',
      //       textAlign: TextAlign.center,
      //       style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      //     ),
      //     backgroundColor: Colors.green,
      //     duration: const Duration(seconds: 10), // Even longer duration
      //     action: SnackBarAction(
      //       label: 'OK',
      //       textColor: Colors.white,
      //       onPressed: () {
      //         // This prevents auto-navigation by giving the user control
      //         ScaffoldMessenger.of(context).hideCurrentSnackBar();
      //       },
      //     ),
      //   ),
      // );

      // IMPORTANT: We're NOT using Navigator.pushReplacement here anymore
      // as it was causing issues with the navigation stack
      // Instead, we're just updating the UI state directly

      // No need to prevent back navigation as requested by the user
    } catch (e) {
      print("Error during check-in: $e");

      // Handle errors gracefully
      if (mounted) {
        setState(() {
          _checkinMessage = 'Có lỗi xảy ra khi điểm danh: $e';
          _isCheckingIn = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Điểm danh thất bại!',
              textAlign: TextAlign.center,
            ),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
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
      elevation: 8, // Higher elevation for more prominence
      color: Colors.green[50],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.green.shade300, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Success header
            Center(
              child: Column(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    'ĐIỂM DANH THÀNH CÔNG!',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 22,
                      color: Colors.green[800],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(thickness: 2, color: Colors.green),
            const SizedBox(height: 16),

            // User name and time section
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.grey.withOpacity(0.2),
                    spreadRadius: 1,
                    blurRadius: 3,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.person, color: Colors.blue, size: 24),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Xin chào $userName',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 20,
                            color: Colors.blue,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.access_time,
                          color: Colors.orange, size: 24),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Đã điểm danh lúc: $checkinTime',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Location section
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.grey.withOpacity(0.2),
                    spreadRadius: 1,
                    blurRadius: 3,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.location_on,
                          color: Colors.red, size: 24),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Vị trí điểm danh:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    address,
                    style: const TextStyle(
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    coordinates,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
