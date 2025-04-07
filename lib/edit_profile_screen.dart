import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloudinary_public/cloudinary_public.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:bcrypt/bcrypt.dart';
import 'config.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'login.dart';

class EditProfileScreen extends StatefulWidget {
  final String driverId;
  final String initialProfileImgUrl;
  final String initialUsername;
  final String initialFullName;
  final String truckId; // Required for updating the truck record

  const EditProfileScreen({
    Key? key,
    required this.driverId,
    required this.initialProfileImgUrl,
    required this.initialUsername,
    required this.initialFullName,
    required this.truckId,
  }) : super(key: key);

  @override
  _EditProfileScreenState createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late TextEditingController _usernameController;
  late TextEditingController _fullNameController;
  late TextEditingController _currentPasswordController;
  late TextEditingController _newPasswordController;
  late TextEditingController _confirmPasswordController;

  // Error state booleans for password fields.
  bool _currentPasswordError = false;
  bool _newPasswordError = false;
  bool _confirmPasswordError = false;

  // Holds the current profile image URL; may be replaced if a new image is picked.
  String? _profileImgUrl;
  File? _selectedImage;
  final ImagePicker _picker = ImagePicker();

  // State variable to control the loading indicator.
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _profileImgUrl = widget.initialProfileImgUrl;
    _usernameController = TextEditingController(text: widget.initialUsername);
    _fullNameController = TextEditingController(text: widget.initialFullName);
    _currentPasswordController = TextEditingController();
    _newPasswordController = TextEditingController();
    _confirmPasswordController = TextEditingController();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _fullNameController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final pickedFile = await _picker.pickImage(source: ImageSource.gallery);
      if (pickedFile != null) {
        setState(() {
          _selectedImage = File(pickedFile.path);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error picking image: $e")),
        );
      }
    }
  }

  Future<String?> _uploadImageToCloudinary(File imageFile) async {
    final cloudinary = CloudinaryPublic(
      cloudinaryCloudName,
      cloudinaryUploadPreset,
      cache: false,
    );
    try {
      final response = await cloudinary.uploadFile(
        CloudinaryFile.fromFile(
          imageFile.path,
          resourceType: CloudinaryResourceType.Image,
        ),
      );
      return response.secureUrl;
    } catch (e) {
      print("Cloudinary upload error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Image upload failed")),
        );
      }
      return null;
    }
  }

  Future<void> _saveChanges() async {
    setState(() {
      _isSaving = true;
    });

    String? updatedImageUrl = _profileImgUrl;
    if (_selectedImage != null) {
      final uploadedUrl = await _uploadImageToCloudinary(_selectedImage!);
      if (uploadedUrl != null) {
        updatedImageUrl = uploadedUrl;
      } else {
        setState(() {
          _isSaving = false;
        });
        return;
      }
    }

    // Build the updated profile map.
    Map<String, dynamic> updatedProfile = {
      'imageUrl': updatedImageUrl,
      'username': _usernameController.text,
      'fullName': _fullNameController.text,
    };

    // Handle password update if any password field is filled.
    if (_currentPasswordController.text.isNotEmpty ||
        _newPasswordController.text.isNotEmpty ||
        _confirmPasswordController.text.isNotEmpty) {
      // Check that all fields are filled.
      if (_currentPasswordController.text.isEmpty ||
          _newPasswordController.text.isEmpty ||
          _confirmPasswordController.text.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Please fill in all password fields.")),
          );
        }
        setState(() {
          _isSaving = false;
        });
        return;
      }

      // Check if new password and confirm password match.
      if (_newPasswordController.text != _confirmPasswordController.text) {
        setState(() {
          _newPasswordError = true;
          _confirmPasswordError = true;
          _isSaving = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("New password and confirm password do not match.")),
          );
        }
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _newPasswordError = false;
              _confirmPasswordError = false;
            });
          }
        });
        return;
      }

      // Fetch the current driver's stored hashed password.
      final driverSnapshot = await FirebaseDatabase.instance
          .ref()
          .child('drivers')
          .child(widget.driverId)
          .get();
      if (!driverSnapshot.exists) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Driver not found.")),
          );
        }
        setState(() {
          _isSaving = false;
        });
        return;
      }
      final driverData = driverSnapshot.value as Map;
      final storedHashedPassword = driverData['password'];
      if (storedHashedPassword == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("No password set for this driver.")),
          );
        }
        setState(() {
          _isSaving = false;
        });
        return;
      }

      // Validate the current password.
      if (!BCrypt.checkpw(_currentPasswordController.text, storedHashedPassword)) {
        setState(() {
          _currentPasswordError = true;
          _isSaving = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Current password is incorrect.")),
          );
        }
        // Reset the error state after 2 seconds.
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _currentPasswordError = false;
            });
          }
        });
        return;
      }

      final newHashedPassword =
      BCrypt.hashpw(_newPasswordController.text, BCrypt.gensalt());
      updatedProfile['password'] = newHashedPassword;
    }

    // Update the driver's profile in the 'drivers' node.
    final DatabaseReference driverRef = FirebaseDatabase.instance
        .ref()
        .child('drivers')
        .child(widget.driverId);
    await driverRef.update(updatedProfile);

    // Update truck records: update vehicleDriver to the new full name.
    final DatabaseReference trucksRef =
    FirebaseDatabase.instance.ref().child('trucks');
    final DataSnapshot snapshot = await trucksRef
        .orderByChild('vehicleDriver')
        .equalTo(widget.initialFullName)
        .get();
    if (snapshot.exists) {
      for (final truck in snapshot.children) {
        await truck.ref.update({'vehicleDriver': _fullNameController.text});
      }
    }

    // Update SharedPreferences with the new profile details.
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('driverFullName', _fullNameController.text);
    await prefs.setString('driverUsername', _usernameController.text);
    await prefs.setString('driverProfileImgUrl', updatedImageUrl ?? '');

    if (mounted) {
      // If password was updated, log out.
      if (_newPasswordController.text.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Password Changed Successful. Logging out...")),
        );
        await Future.delayed(const Duration(seconds: 1));
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => DriverLoginPage()),
              (route) => false,
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Profile updated successfully!")),
        );
        await Future.delayed(const Duration(seconds: 1));
        Navigator.pop(context, updatedProfile);
      }
    }
    setState(() {
      _isSaving = false;
    });
  }

  void _cancelEdit() {
    Navigator.pop(context, null);
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      // Intercept back navigation to ensure we pass back a result.
      onWillPop: () async {
        _cancelEdit();
        return false;
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.green),
          centerTitle: true,
          title: const Text(
            "Edit Profile",
            style: TextStyle(
              color: Colors.green,
              fontWeight: FontWeight.bold,
              fontSize: 24,
            ),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // Profile image with edit icon overlay.
              Stack(
                children: [
                  CircleAvatar(
                    radius: 60,
                    backgroundColor: Colors.grey.shade300,
                    backgroundImage: _selectedImage != null
                        ? FileImage(_selectedImage!)
                        : (_profileImgUrl != null && _profileImgUrl!.isNotEmpty)
                        ? CachedNetworkImageProvider(_profileImgUrl!) as ImageProvider
                        : null,
                    child: ((_selectedImage == null) &&
                        (_profileImgUrl == null || _profileImgUrl!.isEmpty))
                        ? const Icon(Icons.person, size: 60, color: Colors.white)
                        : null,
                  ),
                  Positioned(
                    bottom: -14,
                    right: -15,
                    child: IconButton(
                      icon: const Icon(Icons.edit, color: Colors.black),
                      onPressed: _pickImage,
                    ),
                  ),
                ],
              ),
              // Increased space below the profile image.
              const SizedBox(height: 35),
              // Username text box
              TextFormField(
                controller: _usernameController,
                decoration: InputDecoration(
                  labelText: 'Username',
                  labelStyle: TextStyle(color: Colors.grey.shade600),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                style: const TextStyle(fontSize: 20),
              ),
              const SizedBox(height: 16),
              // Full Name text box
              TextFormField(
                controller: _fullNameController,
                decoration: InputDecoration(
                  labelText: 'Full Name',
                  labelStyle: TextStyle(color: Colors.grey.shade600),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                style: const TextStyle(fontSize: 20),
              ),
              const SizedBox(height: 16),
              // Current Password text box with conditional error decoration.
              TextFormField(
                controller: _currentPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Current Password',
                  labelStyle: TextStyle(
                      color: _currentPasswordError
                          ? Colors.red
                          : Colors.grey.shade600),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: _currentPasswordError
                          ? Colors.red
                          : Colors.grey.shade600,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: _currentPasswordError
                          ? Colors.red
                          : Colors.grey.shade600,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: _currentPasswordError ? Colors.red : Colors.green,
                    ),
                  ),
                ),
                style: const TextStyle(fontSize: 20),
              ),
              const SizedBox(height: 16),
              // New Password text box with conditional error decoration.
              TextFormField(
                controller: _newPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'New Password',
                  labelStyle: TextStyle(
                      color: _newPasswordError
                          ? Colors.red
                          : Colors.grey.shade600),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: _newPasswordError
                          ? Colors.red
                          : Colors.grey.shade600,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: _newPasswordError
                          ? Colors.red
                          : Colors.grey.shade600,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: _newPasswordError ? Colors.red : Colors.green,
                    ),
                  ),
                ),
                style: const TextStyle(fontSize: 20),
              ),
              const SizedBox(height: 16),
              // Confirm Password text box with conditional error decoration.
              TextFormField(
                controller: _confirmPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Confirm Password',
                  labelStyle: TextStyle(
                      color: _confirmPasswordError
                          ? Colors.red
                          : Colors.grey.shade600),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: _confirmPasswordError
                          ? Colors.red
                          : Colors.grey.shade600,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: _confirmPasswordError
                          ? Colors.red
                          : Colors.grey.shade600,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: _confirmPasswordError ? Colors.red : Colors.green,
                    ),
                  ),
                ),
                style: const TextStyle(fontSize: 20),
              ),
              const SizedBox(height: 24),
              // Centered Save Changes button (Cancel button removed)
              Center(
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _saveChanges,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 12),
                  ),
                  child: _isSaving
                      ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor:
                      AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                      : const Text(
                    "Save Changes",
                    style: TextStyle(color: Colors.white),
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
