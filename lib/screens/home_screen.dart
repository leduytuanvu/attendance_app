import 'package:attendance_app/screens/checkin_screen.dart';
import 'package:attendance_app/screens/register_screen.dart';
import 'package:attendance_app/services/user_service.dart';
import 'package:flutter/material.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _hasRegistered = false;

  @override
  void initState() {
    // TODO: implement initState
    UserService.deleteAllUsers();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // appBar: AppBar(
      //   title: const Text('Attendance App'),
      //   centerTitle: true,
      // ),

      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(height: 60),
              // App logo or icon could go here
              const Icon(
                Icons.face_retouching_natural,
                size: 100,
                color: Colors.blue,
              ),
              const SizedBox(height: 40),
              const Text(
                'Hệ thống điểm danh nhận dạng khuôn mặt',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 60),
              // Registration button
              if (!_hasRegistered)
                ElevatedButton(
                  onPressed: () async {
                    final registered = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const RegisterScreen()),
                    );

                    if (registered == true) {
                      setState(() {
                        _hasRegistered = true;
                      });
                    }
                  },
                  child: Container(
                    height: 58,
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.app_registration),
                        SizedBox(width: 10),
                        Text('Đăng ký người dùng mới'),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              // Check-in button
              if (_hasRegistered)
                ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const CheckinScreen()),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 40, vertical: 15),
                    minimumSize: const Size(double.infinity, 60),
                    backgroundColor: Colors.green,
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle_outline, size: 28),
                      SizedBox(width: 10),
                      Text(
                        'Điểm danh',
                        style: TextStyle(fontSize: 18),
                      ),
                    ],
                  ),
                ),

              // const SizedBox(height: 20),
              // View Registered Faces button
              // ElevatedButton(
              //   onPressed: () {
              //     Navigator.push(
              //       context,
              //       MaterialPageRoute(builder: (context) => const RegisteredFacesScreen()),
              //     );
              //   },
              //   style: ElevatedButton.styleFrom(
              //     padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
              //     minimumSize: const Size(double.infinity, 60),
              //     backgroundColor: Colors.orange,
              //   ),
              //   child: const Row(
              //     mainAxisAlignment: MainAxisAlignment.center,
              //     children: [
              //       Icon(Icons.people_alt_outlined, size: 28),
              //       SizedBox(width: 10),
              //       Text(
              //         'Xem Khuôn Mặt Đã Đăng Ký',
              //         style: TextStyle(fontSize: 18),
              //       ),
              //     ],
              //   ),
              // ),

              // Information text
              // const SizedBox(height: 30),
              // const Padding(
              //   padding: EdgeInsets.symmetric(horizontal: 20),
              //   child: Text(
              //     'Lưu ý: Bạn cần đăng ký trước khi điểm danh. Khi điểm danh, hãy nhập CCCD đã đăng ký.',
              //     textAlign: TextAlign.center,
              //     style: TextStyle(
              //       fontSize: 14,
              //       fontStyle: FontStyle.italic,
              //       color: Colors.grey,
              //     ),
              //   ),
              // ),
            ],
          ),
        ),
      ),
    );
  }
}
