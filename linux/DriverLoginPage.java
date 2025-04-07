import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:bcrypt/bcrypt.dart'; // For validating encrypted passwords
import 'assignedroutes.dart'; // AssignedRoutes page

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

      // Fetch drivers data from Firebase
      final driversSnapshot = await _database.child('drivers').get();

      if (!driversSnapshot.exists) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No drivers found in the database')),
        );
        setState(() => _isLoading = false);
        return;
      }

      bool isAuthenticated = false;
      String? fullname;
      Map<String, List<Map<String, dynamic>>> routes = {};

      // Iterate through drivers to authenticate
      for (var child in driversSnapshot.children) {
        final Map<String, dynamic>? data = (child.value as Map?)?.map((key, value) => MapEntry(key, value));

        if (data == null || !data.containsKey('username') || !data.containsKey('password')) {
          continue;
        }

        try {
          if (data['username'] == username && BCrypt.checkpw(password, data['password'])) {
            isAuthenticated = true;
            fullname = data['fullname'];
            break;
          }
        } catch (e) {
          continue;
        }
      }

      if (!isAuthenticated || fullname == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid username or password')),
        );
        setState(() => _isLoading = false);
        return;
      }

      // Fetch truck schedules based on the driver's fullname
      final trucksSnapshot = await _database.child('trucks').get();

      if (trucksSnapshot.exists) {
        for (var truck in trucksSnapshot.children) {
          final Map<String, dynamic>? truckData = (truck.value as Map?)?.map((key, value) => MapEntry(key, value));

          if (truckData != null && truckData['vehicleDriver'] == fullname) {
            final Map<String, dynamic>? schedules = (truckData['schedules'] as Map?)?.map((key, value) => MapEntry(key, value));

            if (schedules != null) {
              schedules.forEach((day, details) {
                final List<Map<String, dynamic>> places = (details['places'] as List?)
                    ?.map((place) => {
                          'name': place['name'],
                          'latitude': place['latitude'],
                          'longitude': place['longitude'],
                        })
                    .toList() ?? [];

                routes[day] = places;
              });
            }
          }
        }
      }

      // Navigate to AssignedRoutes page with the fetched routes
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => AssignedRoutes(schedules: routes)),
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
                Column(
                  children: [
                    Image.asset(
                      'assets/images/hakot_2.png',
                      width: MediaQuery.of(context).size.width * 0.8,
                    ),
                  ],
                ),
                const SizedBox(height: 40),
                const Text(
                  "Welcome Driver!",
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
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
