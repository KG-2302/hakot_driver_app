import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'profile_screen.dart';
import 'mapscreen.dart';

class AssignedRoutes extends StatefulWidget {
  final Map<String, List<Map<String, dynamic>>> schedules;
  final String driverProfileImgUrl;
  final String driverUsername;
  final String driverFullName;
  final String assignedTruck;
  final String truckId; // The truck's Firebase key.
  final String driverId;

  const AssignedRoutes({
    Key? key,
    required this.schedules,
    required this.driverProfileImgUrl,
    required this.driverUsername,
    required this.driverFullName,
    required this.assignedTruck,
    required this.truckId,
    required this.driverId,
  }) : super(key: key);

  @override
  _AssignedRoutesState createState() => _AssignedRoutesState();
}

class _AssignedRoutesState extends State<AssignedRoutes> {
  late Map<String, List<Map<String, dynamic>>> _schedules;
  late Map<String, List<Map<String, dynamic>>> _originalSchedules;
  late String _driverProfileImgUrl;
  final List<String> _daysOrder = const [
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday"
  ];

  @override
  void initState() {
    super.initState();
    _schedules = widget.schedules;
    // Save a copy of the original schedules (for resetting at end of day)
    _originalSchedules = Map.from(widget.schedules);
    _driverProfileImgUrl = widget.driverProfileImgUrl;
    _refreshData();
    _setupEndOfDayRefresh();
  }

  /// Sets up a timer to reset the schedule at midnight.
  void _setupEndOfDayRefresh() {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final durationUntilMidnight = tomorrow.difference(now);
    Future.delayed(durationUntilMidnight, () {
      // Reset the schedule to the original values, then re-fetch updated data.
      setState(() {
        _schedules = Map.from(_originalSchedules);
      });
      _refreshData();
      // Set up for the next day.
      _setupEndOfDayRefresh();
    });
  }

  /// Fetches updated truck schedules from Firebase and updates the driver image URL.
  Future<void> _refreshData() async {
    final newSchedules = await _fetchTruckSchedules();
    final updatedProfileImgUrl = await _fetchDriverProfileImgUrl();
    // Optional delay for smoother UI transition.
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    setState(() {
      _schedules = newSchedules;
      _driverProfileImgUrl = updatedProfileImgUrl;
    });
  }

  /// Queries Firebase for the truck's schedules and filters out completed routes.
  Future<Map<String, List<Map<String, dynamic>>>> _fetchTruckSchedules() async {
    final Map<String, List<Map<String, dynamic>>> schedules = {};

    // Query trucks by vehicleDriver using the driver's full name.
    final query = FirebaseDatabase.instance
        .ref()
        .child('trucks')
        .orderByChild('vehicleDriver')
        .equalTo(widget.driverFullName);
    final snapshot = await query.get();

    print("Fetched truck schedules snapshot: ${snapshot.value}");
    if (snapshot.exists) {
      for (final truck in snapshot.children) {
        if (truck.value is Map) {
          final truckData = Map<String, dynamic>.from(truck.value as Map);
          final schedulesData = truckData['schedules']?['days'];
          if (schedulesData is Map) {
            schedulesData.forEach((day, details) {
              if (details is Map && details['places'] is List) {
                // Filter out routes where "completed" is true.
                final places = (details['places'] as List)
                    .where((place) =>
                place is Map &&
                    (place["completed"] == null || place["completed"] != true))
                    .map<Map<String, dynamic>>(
                        (place) => Map<String, dynamic>.from(place))
                    .toList();
                schedules[day.toString()] = places;
              }
            });
          }
          break; // Only need the first matching truck.
        }
      }
    }
    print("Schedules after filtering completed: $schedules");
    return schedules;
  }

  /// Fetches the driver's profile image URL from Firebase.
  Future<String> _fetchDriverProfileImgUrl() async {
    String imageUrl = widget.driverProfileImgUrl;
    final driverSnapshot = await FirebaseDatabase.instance
        .ref()
        .child('drivers')
        .child(widget.driverId)
        .get();
    if (driverSnapshot.exists && driverSnapshot.value is Map) {
      final driverData =
      Map<String, dynamic>.from(driverSnapshot.value as Map);
      imageUrl = driverData['imageUrl']?.toString().trim() ?? imageUrl;
    }
    return imageUrl;
  }

  /// Builds the UI for a specific day, listing its remaining routes.
  Widget _buildDaySection(String day, List<Map<String, dynamic>> places) {
    // Filter out any completed routes.
    final remainingPlaces = places.where((place) {
      return place["completed"] != true;
    }).toList();

    return GestureDetector(
      onTap: () async {
        // Navigate to MapScreen with the remaining places for the day.
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => MapScreen(
              day: day,
              locations: remainingPlaces,
              truckName: widget.assignedTruck.split(' - ').first,
              truckId: widget.truckId,
            ),
          ),
        );
        // After returning from MapScreen, refresh the data.
        _refreshData();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              day,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 20,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.green,
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(12.0),
              child: remainingPlaces.isEmpty
                  ? const Text(
                "No routes available.",
                style: TextStyle(color: Colors.white, fontSize: 16),
              )
                  : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: remainingPlaces
                    .map((place) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Text(
                    place['name'] ?? '',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 16),
                  ),
                ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final todayIndex = DateTime.now().weekday - 1;
    final currentDay = _daysOrder[todayIndex];
    final todaySchedule = _schedules[currentDay] ?? [];
    final upcomingDays = List.generate(
      6,
          (i) => _daysOrder[(todayIndex + i + 1) % _daysOrder.length],
    );

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
        shadowColor: Colors.transparent,
        scrolledUnderElevation: 0,
        iconTheme: const IconThemeData(color: Colors.green),
        title: const Text(
          "Assigned Routes",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.green,
            fontSize: 24,
          ),
        ),
        actions: [
          IconButton(
            padding: const EdgeInsets.only(right: 16.0),
            icon: CircleAvatar(
              radius: 20,
              backgroundImage: NetworkImage(_driverProfileImgUrl),
              backgroundColor: Colors.grey,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ProfileScreen(
                    driverId: widget.driverId,
                    driverProfileImgUrl: _driverProfileImgUrl,
                    driverUsername: widget.driverUsername,
                    driverFullName: widget.driverFullName,
                    assignedTruck: widget.assignedTruck,
                    truckId: widget.truckId,
                    schedules: _schedules,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshData,
        child: ListView(
          children: [
            Padding(
              padding:
              const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
              child: Text(
                "Schedule for Today ($currentDay)",
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                    color: Colors.green),
              ),
            ),
            _buildDaySection(currentDay, todaySchedule),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
              child: Text(
                "Upcoming Schedule",
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                    color: Colors.green),
              ),
            ),
            ...upcomingDays.map((day) {
              final scheduleForDay = _schedules[day] ?? [];
              return _buildDaySection(day, scheduleForDay);
            }).toList(),
          ],
        ),
      ),
    );
  }
}