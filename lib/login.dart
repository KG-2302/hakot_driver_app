import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'assignedroutes.dart'; // Ensure this file exists

class DriverLoginPage extends StatefulWidget {
  const DriverLoginPage({Key? key}) : super(key: key);

  @override
  _DriverLoginPageState createState() => _DriverLoginPageState();
}

class _DriverLoginPageState extends State<DriverLoginPage> {
  final DatabaseReference _database = FirebaseDatabase.instance.ref();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _login() async {
    setState(() => _isLoading = true);
    try {
      final username = _usernameController.text.trim();
      final password = _passwordController.text.trim();

      if (username.isEmpty || password.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter both username and password')),
        );
        setState(() => _isLoading = false);
        return;
      }

      // Fetch drivers data from Firebase.
      final driversSnapshot = await _database.child('drivers').get();
      if (!driversSnapshot.exists) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No drivers found in the database')),
        );
        setState(() => _isLoading = false);
        return;
      }

      bool isAuthenticated = false;
      String? fullName;
      String? driverProfileImgUrl;
      String? driverUsername;
      String? driverId;
      Map<String, List<Map<String, dynamic>>> routes = {};

      // Iterate through drivers to authenticate.
      for (var child in driversSnapshot.children) {
        if (child.value is Map) {
          final data = Map<String, dynamic>.from(child.value as Map);
          if (!data.containsKey('username') || !data.containsKey('password'))
            continue;
          if (data['username'] == username &&
              BCrypt.checkpw(password, data['password'])) {
            isAuthenticated = true;
            driverId = child.key; // Capture the driver's id.
            fullName = data['fullName']?.toString().trim();
            driverProfileImgUrl = data['imageUrl']?.toString().trim();
            driverUsername = data['username']?.toString().trim();
            break;
          }
        }
      }

      if (!isAuthenticated || fullName == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid username or password')),
        );
        setState(() => _isLoading = false);
        return;
      }

      print("Authenticated driver: $fullName");

      // Fetch truck schedules and truckId based on the driver's full name.
      final trucksSnapshot = await _database.child('trucks').get();
      String? assignedTruck;
      String? truckId; // Capture the truck's Firebase key.
      if (trucksSnapshot.exists) {
        for (var truck in trucksSnapshot.children) {
          if (truck.value is Map) {
            final truckData = Map<String, dynamic>.from(truck.value as Map);
            if (truckData['vehicleDriver'] != null &&
                truckData['vehicleDriver'].toString().trim() == fullName) {
              final vehicleName = truckData['vehicleName']?.toString().trim() ?? '';
              final plateNumber = truckData['plateNumber']?.toString().trim() ?? '';
              assignedTruck = "$vehicleName - $plateNumber";
              truckId = truck.key; // NEW: capture truckId.
              final schedules = truckData['schedules'] != null
                  ? (truckData['schedules']['days'] as Map?)
                  : null;
              if (schedules != null) {
                schedules.forEach((day, details) {
                  if (details is Map && details['places'] is List) {
                    final places = (details['places'] as List<dynamic>)
                        .map<Map<String, dynamic>>((place) {
                      if (place is Map) {
                        return Map<String, dynamic>.from(place);
                      }
                      return <String, dynamic>{};
                    }).toList();
                    routes[day.toString()] = places;
                  }
                });
              }
              break; // Found the matching truck.
            }
          }
        }
      }

      print("Routes: $routes");

      // Persist login state using SharedPreferences.
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isLoggedIn', true);
      await prefs.setString('driverId', driverId ?? '');
      await prefs.setString('driverProfileImgUrl', driverProfileImgUrl ?? '');
      await prefs.setString('driverUsername', driverUsername ?? '');
      await prefs.setString('driverFullName', fullName);
      await prefs.setString('assignedTruck', assignedTruck ?? '');
      await prefs.setString('truckId', truckId ?? ''); // Save truckId.

      // Navigate to AssignedRoutes.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => AssignedRoutes(
            schedules: routes,
            driverProfileImgUrl: driverProfileImgUrl ?? '',
            driverUsername: driverUsername ?? '',
            driverFullName: fullName!,
            assignedTruck: assignedTruck ?? '',
            truckId: truckId ?? '', // Pass truckId.
            driverId: driverId ?? '',
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${e.toString()}')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/images/hakot_2.png',
                  width: MediaQuery.of(context).size.width * 0.8,
                ),
                const SizedBox(height: 40),
                Text.rich(
                  TextSpan(
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                    children: <TextSpan>[
                      const TextSpan(text: 'Welcome '),
                      const TextSpan(
                        text: 'Driver',
                        style: TextStyle(color: Colors.green),
                      ),
                      const TextSpan(text: '!'),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _usernameController,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.person),
                    hintText: 'Username',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.lock),
                    hintText: 'Password',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _login,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.green,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _isLoading
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Text(
                      "Log In",
                      style: TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
