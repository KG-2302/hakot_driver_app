import 'package:flutter/material.dart';
import 'login.dart';
import 'edit_profile_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ProfileScreen extends StatefulWidget {
  final String driverId;
  final String driverProfileImgUrl;
  final String driverUsername;
  final String driverFullName;
  final String assignedTruck;
  final String truckId; // New required parameter
  final Map<String, List<Map<String, dynamic>>> schedules;

  const ProfileScreen({
    Key? key,
    required this.driverId,
    required this.driverProfileImgUrl,
    required this.driverUsername,
    required this.driverFullName,
    required this.assignedTruck,
    required this.truckId,
    required this.schedules,
  }) : super(key: key);

  @override
  _ProfileScreenState createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late String _profileImgUrl;
  late String _username;
  late String _fullName;
  late String _assignedTruck;

  @override
  void initState() {
    super.initState();
    _profileImgUrl = widget.driverProfileImgUrl;
    _username = widget.driverUsername;
    _fullName = widget.driverFullName;
    _assignedTruck = widget.assignedTruck;
  }

  Future<void> _navigateToEditProfile() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => EditProfileScreen(
          driverId: widget.driverId,
          initialProfileImgUrl: _profileImgUrl,
          initialUsername: _username,
          initialFullName: _fullName,
          truckId: widget.truckId,
        ),
      ),
    );

    if (result != null && result is Map<String, dynamic>) {
      setState(() {
        _profileImgUrl = result['imageUrl'] ?? _profileImgUrl;
        _username = result['username'] ?? _username;
        _fullName = result['fullName'] ?? _fullName;
      });
    }
  }

  void _logout() async {
    // Clear persistent login data using SharedPreferences.
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    // Navigate to the login page and remove all previous routes.
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => DriverLoginPage()),
          (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      // When popping, return the updated data.
      onWillPop: () async {
        Navigator.pop(context, {
          'driverProfileImgUrl': _profileImgUrl,
          'driverUsername': _username,
          'driverFullName': _fullName,
          'assignedTruck': _assignedTruck,
        });
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.white, // White background
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.green),
          centerTitle: true,
          title: const Text(
            "Profile",
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.green,
              fontSize: 24,
            ),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // Profile image with grey background
              CircleAvatar(
                radius: 60,
                backgroundColor: Colors.grey.shade300,
                backgroundImage: _profileImgUrl.isNotEmpty
                    ? CachedNetworkImageProvider(_profileImgUrl)
                    : null,
                child: _profileImgUrl.isEmpty
                    ? const Icon(Icons.person, size: 60, color: Colors.white)
                    : null,
              ),
              const SizedBox(height: 10),
              // "Edit Profile" text button centered below the avatar
              Center(
                child: TextButton(
                  onPressed: _navigateToEditProfile,
                  child: const Text(
                    'Edit Profile',
                    style: TextStyle(
                      color: Colors.green,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Header for profile details
              Align(
                alignment: Alignment.centerLeft,
                child: const Text(
                  "Profile Details",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                    color: Colors.green,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Read-only input box for Username
              TextFormField(
                key: ValueKey(_username),
                decoration: InputDecoration(
                  labelText: 'Username',
                  labelStyle: TextStyle(color: Colors.grey.shade600),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                readOnly: true,
                initialValue: _username,
              ),
              const SizedBox(height: 16),
              // Read-only input box for Full Name
              TextFormField(
                key: ValueKey(_fullName),
                decoration: InputDecoration(
                  labelText: 'Full Name',
                  labelStyle: TextStyle(color: Colors.grey.shade600),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                readOnly: true,
                initialValue: _fullName,
              ),
              const SizedBox(height: 16),
              // Read-only input box for Assigned Truck
              TextFormField(
                decoration: InputDecoration(
                  labelText: 'Assigned Truck',
                  labelStyle: TextStyle(color: Colors.grey.shade600),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                readOnly: true,
                initialValue: _assignedTruck,
              ),
              const SizedBox(height: 24),
              // Logout button
              Center(
                child: ElevatedButton(
                  onPressed: _logout,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFAF3F1B),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    "Logout",
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
