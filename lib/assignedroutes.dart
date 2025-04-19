import 'dart:async';
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
  final String truckId;
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

class _AssignedRoutesState extends State<AssignedRoutes> with WidgetsBindingObserver {
  late Map<String, List<Map<String, dynamic>>> _schedules;
  late String _driverProfileImgUrl;

  final List<String> _daysOrder = const [
    "Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schedules = widget.schedules;
    _driverProfileImgUrl = widget.driverProfileImgUrl;
    _refreshData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refreshData() async {
    final newSchedules = await _fetchTruckSchedules();
    final newImg = await _fetchDriverProfileImgUrl();
    if (!mounted) return;
    setState(() {
      _schedules = newSchedules;
      _driverProfileImgUrl = newImg;
    });
  }

  Future<Map<String, List<Map<String, dynamic>>>> _fetchTruckSchedules() async {
    final Map<String, List<Map<String, dynamic>>> schedules = {};
    final snap = await FirebaseDatabase.instance
        .ref('trucks')
        .orderByChild('vehicleDriver')
        .equalTo(widget.driverFullName)
        .get();

    if (snap.exists) {
      for (final truck in snap.children) {
        final data = truck.value as Map<dynamic, dynamic>;
        final days = data['schedules']?['days'];
        if (days is Map) {
          days.forEach((day, details) {
            if (details is Map && details['places'] is List) {
              final places = (details['places'] as List)
                  .where((p) => p is Map && p['completed'] != true)
                  .map((p) => Map<String, dynamic>.from(p as Map))
                  .toList();
              schedules[day] = places;
            }
          });
        }
        break; // just the first matching truck
      }
    }
    return schedules;
  }

  Future<String> _fetchDriverProfileImgUrl() async {
    String url = widget.driverProfileImgUrl;
    final snap = await FirebaseDatabase.instance
        .ref('drivers')
        .child(widget.driverId)
        .get();
    if (snap.exists && snap.value is Map) {
      final data = Map<String, dynamic>.from(snap.value as Map);
      url = data['imageUrl']?.toString().trim() ?? url;
    }
    return url;
  }

  Widget _buildDaySection(
      String day,
      List<Map<String, dynamic>> places,
      double screenWidth,
      double screenHeight,
      TextStyle titleStyle,
      TextStyle placeStyle,
      ) {
    final remaining = places.where((p) => p['completed'] != true).toList();
    final containerPadding = screenWidth * .04;
    final verticalSpace = screenHeight * .01;

    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MapScreen(
              day: day,
              locations: remaining,
              truckName: widget.assignedTruck.split(' - ').first,
              truckId: widget.truckId,
              driverFullName: widget.driverFullName,
            ),
          ),
        );
        _refreshData();
      },
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: verticalSpace,
          horizontal: containerPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(day, style: titleStyle),
            SizedBox(height: verticalSpace),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.green,
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(screenWidth * .02),
              ),
              padding: EdgeInsets.all(containerPadding),
              child: remaining.isEmpty
                  ? Text("No routes available.", style: placeStyle)
                  : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: remaining.map((p) {
                  return Padding(
                    padding: EdgeInsets.symmetric(vertical: verticalSpace / 2),
                    child: Text(p['name'] ?? '', style: placeStyle),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Responsive sizing
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // TextStyles
    final headerStyle = TextStyle(
      fontSize: screenWidth * .055,
      fontWeight: FontWeight.bold,
      color: Colors.green,
    );
    final sectionTitleStyle = TextStyle(
      fontSize: screenWidth * .05,
      fontWeight: FontWeight.bold,
      color: Colors.black,
    );
    final placeTextStyle = TextStyle(
      fontSize: screenWidth * .045,
      color: Colors.white,
    );

    final todayIndex = DateTime.now().weekday - 1;
    final today = _daysOrder[todayIndex];
    final todayPlaces = _schedules[today] ?? [];
    final upcomingDays = List.generate(
      6,
          (i) => _daysOrder[(todayIndex + i + 1) % _daysOrder.length],
    );

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.green),
        title: const Text(
          "Assigned Routes",
          style: TextStyle(
            color: Colors.green,
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: screenWidth * .04),
            child: GestureDetector(
              onTap: () {
                // navigate to profile
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProfileScreen(
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
              child: CircleAvatar(
                radius: screenWidth * .06,
                backgroundImage: NetworkImage(_driverProfileImgUrl),
                backgroundColor: Colors.grey.shade300,
              ),
            ),
          )
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshData,
        child: ListView(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(
                vertical: screenHeight * .015,
                horizontal: screenWidth * .04,
              ),
              child: Text("Schedule for Today ($today)", style: headerStyle),
            ),
            _buildDaySection(
              today,
              todayPlaces,
              screenWidth,
              screenHeight,
              sectionTitleStyle,
              placeTextStyle,
            ),
            SizedBox(height: screenHeight * .02),
            Padding(
              padding: EdgeInsets.symmetric(
                vertical: screenHeight * .015,
                horizontal: screenWidth * .04,
              ),
              child: Text("Upcoming Schedule", style: headerStyle),
            ),
            ...upcomingDays.map((d) => _buildDaySection(
              d,
              _schedules[d] ?? [],
              screenWidth,
              screenHeight,
              sectionTitleStyle,
              placeTextStyle,
            )),
            SizedBox(height: screenHeight * .05),
          ],
        ),
      ),
    );
  }
}
