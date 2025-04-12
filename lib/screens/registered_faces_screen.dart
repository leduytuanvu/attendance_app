import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:attendance_app/models/user_model.dart';
import 'package:attendance_app/services/user_service.dart';

class RegisteredFacesScreen extends StatefulWidget {
  const RegisteredFacesScreen({super.key});

  @override
  State<RegisteredFacesScreen> createState() => _RegisteredFacesScreenState();
}

class _RegisteredFacesScreenState extends State<RegisteredFacesScreen> {
  List<User> _users = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final users = await UserService.getUsers();
      // Only show users with face data
      final usersWithFace = users
          .where((user) => user.faceScanned && user.faceData != null)
          .toList();

      setState(() {
        _users = usersWithFace;
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading users: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Khuôn Mặt Đã Đăng Ký'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadUsers,
            tooltip: 'Làm mới',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _users.isEmpty
              ? const Center(
                  child: Text(
                    'Không tìm thấy khuôn mặt đã đăng ký',
                    style: TextStyle(fontSize: 18),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadUsers,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16.0),
                    itemCount: _users.length,
                    itemBuilder: (context, index) {
                      final user = _users[index];
                      return _buildUserCard(user);
                    },
                  ),
                ),
    );
  }

  Widget _buildUserCard(User user) {
    // Extract face data for visualization
    String? faceDataString = user.faceData;

    return Card(
      elevation: 4,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Face visualization
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: faceDataString != null
                      ? _buildFaceVisualization(faceDataString)
                      : const Icon(Icons.face, size: 60, color: Colors.grey),
                ),
                const SizedBox(width: 16),
                // User information
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('CCCD/CMND: ${user.cccd}'),
                      const SizedBox(height: 4),
                      Text('Ngày sinh: ${user.dob}'),
                      const SizedBox(height: 4),
                      Text(
                        'Đăng ký: ${_formatDate(user.registeredAt)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            // Face data information
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Số góc khuôn mặt: ${user.allFaceData?.length ?? 1}',
                  style: const TextStyle(fontSize: 14),
                ),
                if (user.allFaceData != null && user.allFaceData!.length > 1)
                  TextButton(
                    onPressed: () {
                      _showAllFaceAngles(context, user);
                    },
                    child: const Text('Xem tất cả góc'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (user.addressComponents != null &&
                user.addressComponents!.isNotEmpty)
              Text(
                'Địa chỉ: ${_formatAddress(user.addressComponents!)}',
                style: const TextStyle(fontSize: 14),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFaceVisualization(String faceDataString) {
    // This is a more detailed visualization of face data
    // In a real app, you would save and display actual face images
    
    try {
      final parts = faceDataString.split('_');
      if (parts.length >= 5) {
        // Extract values for visualization
        final double left = double.tryParse(parts[1]) ?? 0;
        final double top = double.tryParse(parts[2]) ?? 0;
        final double width = double.tryParse(parts[3]) ?? 0;
        final double height = double.tryParse(parts[4]) ?? 0;
        final double yAngle = double.tryParse(parts[5]) ?? 0;
        final double zAngle = double.tryParse(parts[6]) ?? 0;
        
        // Create a more detailed face visualization based on angles
        return Stack(
          children: [
            // Background color based on angles
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.blue.withOpacity(0.2),
                    Colors.lightBlue.withOpacity(0.3),
                  ],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            // Face visualization
            CustomPaint(
              painter: EnhancedFaceVisualizationPainter(
                left: left,
                top: top,
                width: width,
                height: height,
                yAngle: yAngle,
                zAngle: zAngle,
              ),
            ),
            // Overlay text showing this is a visualization
            Positioned(
              bottom: 2,
              right: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'Mô phỏng',
                  style: TextStyle(color: Colors.white, fontSize: 8),
                ),
              ),
            ),
          ],
        );
      }
    } catch (e) {
      print('Error parsing face data: $e');
    }
    
    // Fallback
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.face, size: 40, color: Colors.blue),
            SizedBox(height: 4),
            Text(
              'Mô phỏng khuôn mặt',
              style: TextStyle(fontSize: 10, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _formatAddress(Map<String, String> addressComponents) {
    final components = <String>[];

    if (addressComponents.containsKey('street')) {
      components.add(addressComponents['street']!);
    }
    if (addressComponents.containsKey('city')) {
      components.add(addressComponents['city']!);
    }
    if (addressComponents.containsKey('state')) {
      components.add(addressComponents['state']!);
    }

    return components.join(', ');
  }
  
  // Show a dialog with all face angles
  void _showAllFaceAngles(BuildContext context, User user) {
    if (user.allFaceData == null || user.allFaceData!.isEmpty) {
      return;
    }
    
    // Define angle names for display
    final angleNames = {
      0: 'Chính diện',
      1: 'Trái',
      2: 'Phải',
      3: 'Trên',
      4: 'Dưới',
    };
    
    showDialog(
      context: context,
      builder: (context) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Khuôn mặt của ${user.name}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Các góc khuôn mặt đã quét:',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: GridView.builder(
                  shrinkWrap: true,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 1.0,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: user.allFaceData!.length,
                  itemBuilder: (context, index) {
                    final faceData = user.allFaceData![index];
                    return Column(
                      children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: _buildFaceVisualization(faceData),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          angleNames[index] ?? 'Góc ${index + 1}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              const Center(
                child: Text(
                  'Lưu ý: Đây là mô phỏng khuôn mặt, không phải ảnh thật',
                  style: TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Enhanced custom painter for face visualization
class EnhancedFaceVisualizationPainter extends CustomPainter {
  final double left;
  final double top;
  final double width;
  final double height;
  final double yAngle;
  final double zAngle;

  EnhancedFaceVisualizationPainter({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.yAngle,
    required this.zAngle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final outlinePaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    
    final fillPaint = Paint()
      ..color = Colors.blue.withOpacity(0.1)
      ..style = PaintingStyle.fill;
    
    // Calculate face position based on angles
    final xOffset = (yAngle / 45) * size.width * 0.1;
    final yOffset = (zAngle / 30) * size.height * 0.1;
    
    // Draw a face oval with offset based on angles
    final rect = Rect.fromLTWH(
      size.width * 0.2 + xOffset,
      size.height * 0.2 + yOffset,
      size.width * 0.6,
      size.height * 0.6,
    );
    canvas.drawOval(rect, fillPaint);
    canvas.drawOval(rect, outlinePaint);

    // Draw eyes with offset
    final eyeRadius = size.width * 0.08;
    final leftEyeCenter = Offset(
      size.width * 0.35 + xOffset, 
      size.height * 0.4 + yOffset
    );
    final rightEyeCenter = Offset(
      size.width * 0.65 + xOffset, 
      size.height * 0.4 + yOffset
    );
    
    // Eye whites
    final eyeWhitePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(leftEyeCenter, eyeRadius, eyeWhitePaint);
    canvas.drawCircle(rightEyeCenter, eyeRadius, eyeWhitePaint);
    
    // Eye outlines
    canvas.drawCircle(leftEyeCenter, eyeRadius, outlinePaint);
    canvas.drawCircle(rightEyeCenter, eyeRadius, outlinePaint);
    
    // Pupils with offset based on angles
    final pupilPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    
    final pupilOffset = Offset(
      (yAngle / 45) * eyeRadius * 0.6,
      (zAngle / 30) * eyeRadius * 0.6
    );
    
    canvas.drawCircle(
      leftEyeCenter + pupilOffset, 
      eyeRadius * 0.4, 
      pupilPaint
    );
    canvas.drawCircle(
      rightEyeCenter + pupilOffset, 
      eyeRadius * 0.4, 
      pupilPaint
    );

    // Draw mouth with curvature based on angles
    final mouthRect = Rect.fromLTWH(
      size.width * 0.3 + xOffset,
      size.height * 0.6 + yOffset,
      size.width * 0.4,
      size.height * 0.1 - (zAngle * 0.003),
    );
    
    // Smile more or less based on z-angle (looking up or down)
    final startAngle = 0.0;
    final sweepAngle = 3.14 - (zAngle * 0.02);
    
    canvas.drawArc(mouthRect, startAngle, sweepAngle, false, outlinePaint);
    
    // Draw nose
    final nosePath = Path();
    final noseTop = Offset(size.width * 0.5 + xOffset, size.height * 0.45 + yOffset);
    final noseBottom = Offset(size.width * 0.5 + xOffset, size.height * 0.55 + yOffset);
    final noseLeft = Offset(size.width * 0.45 + xOffset, size.height * 0.53 + yOffset);
    final noseRight = Offset(size.width * 0.55 + xOffset, size.height * 0.53 + yOffset);
    
    nosePath.moveTo(noseTop.dx, noseTop.dy);
    nosePath.lineTo(noseLeft.dx, noseLeft.dy);
    nosePath.moveTo(noseTop.dx, noseTop.dy);
    nosePath.lineTo(noseRight.dx, noseRight.dy);
    nosePath.moveTo(noseLeft.dx, noseLeft.dy);
    nosePath.lineTo(noseBottom.dx, noseBottom.dy);
    nosePath.lineTo(noseRight.dx, noseRight.dy);
    
    canvas.drawPath(nosePath, outlinePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}
