import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'login.dart';
import 'assignedroutes.dart';

class LoadingScreenPage extends StatefulWidget {
  const LoadingScreenPage({super.key});

  @override
  _LoadingScreenPageState createState() => _LoadingScreenPageState();
}

class _LoadingScreenPageState extends State<LoadingScreenPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );

    _fadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(_controller);

    // Always wait 3 seconds, then start the fade-out.
    Future.delayed(const Duration(seconds: 3), () {
      _controller.forward().whenComplete(() {
        _navigateBasedOnLogin();
      });
    });
  }

  Future<void> _navigateBasedOnLogin() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    bool isLoggedIn = prefs.getBool('isLoggedIn') ?? false;

    if (isLoggedIn) {
      // Retrieve stored driver details.
      String driverId = prefs.getString('driverId') ?? '';
      String driverProfileImgUrl = prefs.getString('driverProfileImgUrl') ?? '';
      String driverUsername = prefs.getString('driverUsername') ?? '';
      String driverFullName = prefs.getString('driverFullName') ?? '';
      String assignedTruck = prefs.getString('assignedTruck') ?? '';
      // Also retrieve the truck ID.
      String truckId = prefs.getString('truckId') ?? '';

      // If you plan to re-fetch schedules from your database, adjust here.
      Map<String, List<Map<String, dynamic>>> schedules = {};

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => AssignedRoutes(
            schedules: schedules,
            driverProfileImgUrl: driverProfileImgUrl,
            driverUsername: driverUsername,
            driverFullName: driverFullName,
            assignedTruck: assignedTruck,
            truckId: truckId, // NEW: pass truckId
            driverId: driverId,
          ),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const DriverLoginPage()),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const SizedBox(height: 20),
                // Main logo and text.
                Column(
                  children: [
                    Image.asset(
                      'assets/images/Hakot.png',
                      width: MediaQuery.of(context).size.width * 0.8,
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
                // Bottom logos/images.
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Image.asset(
                      'assets/images/Cenro.png',
                      width: MediaQuery.of(context).size.width * 0.2,
                    ),
                    Image.asset(
                      'assets/images/TagumCity.png',
                      width: MediaQuery.of(context).size.width * 0.4,
                    ),
                    Image.asset(
                      'assets/images/UMLogo.png',
                      width: MediaQuery.of(context).size.width * 0.2,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
