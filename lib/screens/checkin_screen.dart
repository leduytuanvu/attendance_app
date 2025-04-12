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

    // Check if a face was detected and if it matches a registered user
    if (result != null && result['faceDetected'] == true) {
      print("[leduytuanvu] Face detected for verification.");

      // Try to find user by CCCD first if provided
      if (result['cccd'] != null && result['cccd'].isNotEmpty) {
        await _loadUserData(result['cccd']);
        if (_userData != null) {
          // User found, proceed with check-in
          _performCheckinWithUser(_userData!);
          return true;
        }
      }

      // If CCCD didn't find a user or wasn't provided, try to match by face data
      if (result['faceData'] != null) {
        String scannedFaceData = result['faceData'];
        User? matchedUser = await UserService.findUserByFaceData(
          scannedFaceData,
          matchFunction: _isFaceMatch,
        );

        print('[leduytuanvu] Scanned face data: $scannedFaceData');

        List<User> allUsers = await UserService.getUsers();
        for (var u in allUsers) {
          print('[leduytuanvu] Stored faceData: ${u.faceData}');
        }

        if (matchedUser != null) {
          setState(() {
            _userData = matchedUser;
          });

          // User found by face, proceed with check-in
          _performCheckinWithUser(matchedUser);
          return true;
        }
      }

      // Face detected but no user found
      setState(() {
        _checkinMessage = 'Khuôn mặt chưa được đăng ký trong hệ thống.';
      });
      return true;
    } else {
      print(
          "[leduytuanvu] Face not detected or scan cancelled during verification.");
      return false;
    }
  }

  // Face recognition service
  final FaceRecognitionService _faceRecognitionService = FaceRecognitionService();
  
  // Face matching using TensorFlow Lite
  bool _isFaceMatch(String scannedFaceData, String storedFaceData) {
    try {
      // In a real app with TensorFlow Lite, we would:
      // 1. Convert the string face data back to embeddings
      // 2. Use the face recognition service to compare the embeddings
      
      // For this example, we'll use a simple comparison
      List<String> scannedParts = scannedFaceData.split('_');
      List<String> storedParts = storedFaceData.split('_');
      
      if (scannedParts.length < 6 || storedParts.length < 6) return false;
      
      // Extract face dimensions
      double scannedWidth = double.parse(scannedParts[3]);
      double storedWidth = double.parse(storedParts[3]);
      
      double scannedHeight = double.parse(scannedParts[4]);
      double storedHeight = double.parse(storedParts[4]);
      
      // Calculate differences
      double widthDiff = (scannedWidth - storedWidth).abs();
      double heightDiff = (scannedHeight - storedHeight).abs();
      
      // Check if the dimensions are similar enough
      // Using a larger tolerance for better matching
      return widthDiff < 20.0 && heightDiff < 20.0;
    } catch (e) {
      print("Error matching faces: $e");
      return false;
    }
  }

  Future<void> _performCheckin() async {
    // Start with face verification which will also identify the user
    setState(() {
      _isCheckingIn = true;
      _checkinMessage = 'Đang điểm danh...';
    });

    await _verifyFace();

    // The _verifyFace method will handle the rest of the check-in process
    // including calling _performCheckinWithUser if a user is found

    setState(() {
      _isCheckingIn = false;
    });
  }

  Future<void> _performCheckinWithUser(User user) async {
    setState(() {
      _isCheckingIn = true;
      _checkinMessage = 'Đang điểm danh...';
    });

    // Get GPS Location
    Position? position = await LocationService.getCurrentPosition();
    if (position == null) {
      setState(() {
        _checkinMessage =
            'Failed to get location. Please check your location settings.';
        _isCheckingIn = false;
      });
      return;
    }

    // Get detailed address components from coordinates
    Map<String, String> addressComponents = await LocationService.getDetailedAddressComponents(
      position.latitude,
      position.longitude,
    );

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
    await UserService.saveUser(updatedUser); // Using saveUser instead of updateUser

    setState(() {
      _checkinMessage = detailedMessage;
      _isCheckingIn = false;
      _userData = updatedUser; // Update the local user data
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Điểm danh thành công!'),
        backgroundColor: Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Check In'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              // Instructions Card
              Card(
                elevation: 4,
                margin: const EdgeInsets.only(bottom: 20),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Điểm danh bằng khuôn mặt:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Hệ thống sẽ tự động nhận diện khuôn mặt của bạn để điểm danh. Nếu bạn chưa đăng ký, vui lòng đăng ký trước.',
                        style: TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      if (_isSearching)
                        const Center(child: CircularProgressIndicator())
                      else if (_userData == null && !_isCheckingIn)
                        Center(
                          child: ElevatedButton.icon(
                            onPressed: _startFaceScan,
                            icon: const Icon(Icons.face),
                            label: const Text('Quét khuôn mặt'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 30, vertical: 15),
                              textStyle: const TextStyle(fontSize: 18),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // User Information Card
              if (_userData != null)
                Card(
                  elevation: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Thông tin người dùng:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('Họ tên: ${_userData!.name}'),
                        Text('Ngày sinh: ${_userData!.dob}'),
                        Text('CCCD: ${_userData!.cccd}'),
                      ],
                    ),
                  ),
                ),

              // Check-in Button or Progress Indicator
              if (_isCheckingIn)
                const CircularProgressIndicator()
              else if (_userData != null)
                ElevatedButton.icon(
                  onPressed: () => _performCheckinWithUser(_userData!),
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Xác nhận điểm danh'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 30, vertical: 15),
                    textStyle: const TextStyle(fontSize: 18),
                    backgroundColor: Colors.green,
                  ),
                ),
              const SizedBox(height: 30),
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
    String userCccd = _userData?.cccd ?? widget.cccd;

    // Extract information from check-in message
    List<String> lines = _checkinMessage.split('\n');

    // Default values in case parsing fails
    String checkinTime = '';
    String address = '';
    String coordinates = '';
    Map<String, String> addressDetails = {};

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
      } else if (line.startsWith('Số nhà:')) {
        addressDetails['houseNumber'] = line.substring('Số nhà:'.length).trim();
      } else if (line.startsWith('Đường:')) {
        addressDetails['street'] = line.substring('Đường:'.length).trim();
      } else if (line.startsWith('Phường/Xã:')) {
        addressDetails['ward'] = line.substring('Phường/Xã:'.length).trim();
      } else if (line.startsWith('Quận/Huyện:')) {
        addressDetails['district'] = line.substring('Quận/Huyện:'.length).trim();
      } else if (line.startsWith('Thành phố/Tỉnh:')) {
        addressDetails['city'] = line.substring('Thành phố/Tỉnh:'.length).trim();
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

            // User information section with larger text and better spacing
            const Text(
              'Thông tin người dùng:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.person, size: 20, color: Colors.blue[700]),
                      const SizedBox(width: 8),
                      const Text('Họ tên: ',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      Expanded(
                          child: Text(userName,
                              style: const TextStyle(fontSize: 16))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.credit_card,
                          size: 20, color: Colors.blue[700]),
                      const SizedBox(width: 8),
                      const Text('CCCD: ',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      Expanded(
                          child: Text(userCccd,
                              style: const TextStyle(fontSize: 16))),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Check-in details section
            const Text(
              'Chi tiết điểm danh:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (checkinTime.isNotEmpty)
                    Row(
                      children: [
                        Icon(Icons.access_time,
                            size: 20, color: Colors.orange[700]),
                        const SizedBox(width: 8),
                        const Text('Thời gian: ',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        Expanded(
                            child: Text(checkinTime,
                                style: const TextStyle(fontSize: 16))),
                      ],
                    ),
                  if (checkinTime.isNotEmpty) const SizedBox(height: 8),
                  
                  // Address information
                  if (address.isNotEmpty)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.location_on,
                            size: 20, color: Colors.red[700]),
                        const SizedBox(width: 8),
                        const Text('Địa chỉ: ',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        Expanded(
                            child: Text(address,
                                style: const TextStyle(fontSize: 16))),
                      ],
                    ),
                  if (address.isNotEmpty) const SizedBox(height: 8),
                  
                  // Detailed address components
                  if (addressDetails.isNotEmpty) ...[
                    const Text('Chi tiết địa chỉ:',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 4),
                    
                    if (addressDetails['houseNumber']?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(left: 16.0, top: 4.0),
                        child: Row(
                          children: [
                            Icon(Icons.home, size: 16, color: Colors.brown[700]),
                            const SizedBox(width: 8),
                            const Text('Số nhà: ',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            Expanded(
                                child: Text(addressDetails['houseNumber']!,
                                    style: const TextStyle(fontSize: 14))),
                          ],
                        ),
                      ),
                      
                    if (addressDetails['street']?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(left: 16.0, top: 4.0),
                        child: Row(
                          children: [
                            Icon(Icons.add_road, size: 16, color: Colors.brown[700]),
                            const SizedBox(width: 8),
                            const Text('Đường: ',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            Expanded(
                                child: Text(addressDetails['street']!,
                                    style: const TextStyle(fontSize: 14))),
                          ],
                        ),
                      ),
                      
                    if (addressDetails['ward']?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(left: 16.0, top: 4.0),
                        child: Row(
                          children: [
                            Icon(Icons.location_city, size: 16, color: Colors.brown[700]),
                            const SizedBox(width: 8),
                            const Text('Phường/Xã: ',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            Expanded(
                                child: Text(addressDetails['ward']!,
                                    style: const TextStyle(fontSize: 14))),
                          ],
                        ),
                      ),
                      
                    if (addressDetails['district']?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(left: 16.0, top: 4.0),
                        child: Row(
                          children: [
                            Icon(Icons.location_city, size: 16, color: Colors.brown[700]),
                            const SizedBox(width: 8),
                            const Text('Quận/Huyện: ',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            Expanded(
                                child: Text(addressDetails['district']!,
                                    style: const TextStyle(fontSize: 14))),
                          ],
                        ),
                      ),
                      
                    if (addressDetails['city']?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(left: 16.0, top: 4.0),
                        child: Row(
                          children: [
                            Icon(Icons.location_city, size: 16, color: Colors.brown[700]),
                            const SizedBox(width: 8),
                            const Text('Thành phố/Tỉnh: ',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            Expanded(
                                child: Text(addressDetails['city']!,
                                    style: const TextStyle(fontSize: 14))),
                          ],
                        ),
                      ),
                    
                    const SizedBox(height: 8),
                  ],
                  
                  if (coordinates.isNotEmpty)
                    Row(
                      children: [
                        Icon(Icons.gps_fixed,
                            size: 20, color: Colors.purple[700]),
                        const SizedBox(width: 8),
                        const Text('Tọa độ: ',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        Expanded(
                            child: Text(coordinates,
                                style: const TextStyle(fontSize: 16))),
                      ],
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
