import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_background/flutter_background.dart' as fb;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'config.dart';
import 'package:flutter/services.dart';

/// Widget to measure the size of its child and report it via a callback.
typedef OnWidgetSizeChange = void Function(Size size);

class MeasureSize extends StatefulWidget {
  final Widget child;
  final OnWidgetSizeChange onChange;

  const MeasureSize({
    Key? key,
    required this.onChange,
    required this.child,
  }) : super(key: key);

  @override
  _MeasureSizeState createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<MeasureSize> {
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _notifySize());
    return widget.child;
  }

  void _notifySize() {
    if (!mounted) return;
    final Size newSize = context.size ?? Size.zero;
    widget.onChange(newSize);
  }
}

class MapScreen extends StatefulWidget {
  final String day;
  final List<Map<String, dynamic>> locations;
  final String truckName;       // Only truck name (without plate).
  final String truckId;         // The truck's Firebase key.
  final String driverFullName;  // Needed to query schedules by driver.

  const MapScreen({
    Key? key,
    required this.day,
    required this.locations,
    required this.truckName,
    required this.truckId,
    required this.driverFullName,
  }) : super(key: key);

  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  List<LatLng> routePoints = [];
  bool isTracking = false;
  bool isTraveling = false;
  bool isRoutingStarted = false;

  StreamSubscription<Position>? _positionStreamSubscription;
  LatLng? currentLocation;
  LatLng? _lastTravelLocation;
  LatLng? _targetLocation;

  Timer? _travelTimer;
  Duration travelDuration = Duration.zero;

  double? startupFuel;
  double? startupOdometer;
  double _metersTraveled = 0.0;
  double? _disposedWeight;

  bool _showTrashInput = false;
  bool isTruckFull = false;
  bool isAtLandfill = false;
  String? finalStage;
  String? _targetLocationName;
  String _locationName = "Loading Current Location...";

  List<Map<String, dynamic>> _displayLocations = [];
  List<List<LatLng>> alternativeRoutes = [];

  bool _isGpsLoading = false;
  bool _isTravelLoading = false;
  bool _isRouteLoading = false;

  double _bottomOverlayHeight = 0;

  String truckType = 'default';
  final LatLng landfillLatLng = LatLng(7.506667, 125.818111);
  final LatLng motorpoolLatLng = LatLng(7.4493, 125.8255);

  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    _initBackgroundExecution();
    _displayLocations = List<Map<String, dynamic>>.from(widget.locations);
    _initRoute();
    _fetchTruckType();
  }

  /// Fetch the truck type from Firebase.
  Future<void> _fetchTruckType() async {
    DatabaseReference truckRef =
    FirebaseDatabase.instance.ref().child('trucks').child(widget.truckId);
    final snapshot = await truckRef.get();
    if (snapshot.exists && snapshot.value is Map) {
      final truckData =
      Map<String, dynamic>.from(snapshot.value as Map<dynamic, dynamic>);
      setState(() {
        truckType = truckData['truckType'] ?? 'default';
      });
    }
  }

  /// Check for an active data connection.
  Future<bool> _checkConnectivity() async {
    var result = await Connectivity().checkConnectivity();
    return result != ConnectivityResult.none;
  }

  /// If there are at least two destinations, fetch the full route.
  void _initRoute() async {
    if (_displayLocations.length >= 2 && await _checkConnectivity()) {
      await _fetchRoute();
    }
  }

  Future<void> _initBackgroundExecution() async {
    final androidConfig = fb.FlutterBackgroundAndroidConfig(
      notificationTitle: "Hakot Driver App",
      notificationText: "Tracking location and travel time in background",
      notificationIcon:
      fb.AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
    );
    await fb.FlutterBackground.initialize(androidConfig: androidConfig);
  }

  /// Reverse geocoding via ORS.
  Future<void> _updateLocationName() async {
    if (currentLocation == null) return;
    if (!await _checkConnectivity()) {
      setState(() => _locationName = "No data connection");
      return;
    }
    try {
      final url =
          "https://api.openrouteservice.org/geocode/reverse?api_key=$openRouteServiceApiKey"
          "&point.lat=${currentLocation!.latitude}&point.lon=${currentLocation!.longitude}&size=1";
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final label = data["features"]?[0]?["properties"]?["label"];
        setState(() => _locationName = label ?? "Unknown location");
      } else {
        setState(() => _locationName = "Unknown location");
      }
    } catch (_) {
      setState(() => _locationName = "Error retrieving location");
    }
  }

  String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return "${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}";
    }
    return "${two(d.inMinutes)}:${two(d.inSeconds.remainder(60))}";
  }

  int _getNearestDestinationIndex(
      LatLng current, List<Map<String, dynamic>> destinations) {
    if (destinations.isEmpty) return -1;
    int nearestIndex = 0;
    double nearestDistance = Distance().as(
      LengthUnit.Meter,
      current,
      LatLng(destinations[0]['latitude'] as double,
          destinations[0]['longitude'] as double),
    );
    for (int i = 1; i < destinations.length; i++) {
      double d = Distance().as(
        LengthUnit.Meter,
        current,
        LatLng(destinations[i]['latitude'] as double,
            destinations[i]['longitude'] as double),
      );
      if (d < nearestDistance) {
        nearestDistance = d;
        nearestIndex = i;
      }
    }
    return nearestIndex;
  }

  /// Fetch the full route via ORS.
  Future<void> _fetchRoute() async {
    if (!await _checkConnectivity()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No data connection.")),
      );
      return;
    }
    final coords = _displayLocations
        .map((loc) => [loc['longitude'] as double, loc['latitude'] as double])
        .toList();
    final response = await http.post(
      Uri.parse('https://api.openrouteservice.org/v2/directions/driving-car/geojson'),
      headers: {
        'Authorization': openRouteServiceApiKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'coordinates': coords}),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final geometry = data['features']?[0]?['geometry'];
      if (geometry?['type'] == 'LineString') {
        final coordsList = geometry['coordinates'] as List;
        final points = coordsList
            .map<LatLng>((c) => LatLng(c[1] as double, c[0] as double))
            .toList();
        setState(() => routePoints = points);
      }
    }
  }

  /// Updates the dynamic route from start to destination.
  Future<void> _updateDynamicRoute(LatLng start, LatLng destination) async {
    if (!await _checkConnectivity()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No data connection.")),
      );
      return;
    }
    final body = jsonEncode({
      "coordinates": [
        [start.longitude, start.latitude],
        [destination.longitude, destination.latitude]
      ],
      "preference": "shortest",
      "alternative_routes": {"share_factor": 0.6, "target_count": 3}
    });
    final response = await http.post(
      Uri.parse('https://api.openrouteservice.org/v2/directions/driving-car/geojson'),
      headers: {
        'Authorization': openRouteServiceApiKey,
        'Content-Type': 'application/json',
      },
      body: body,
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final features = data['features'] as List;
      if (features.isNotEmpty) {
        final mainGeo = features[0]['geometry'];
        final coordsList = mainGeo['coordinates'] as List;
        final mainRoute = coordsList
            .map<LatLng>((c) => LatLng(c[1] as double, c[0] as double))
            .toList();
        setState(() => routePoints = mainRoute);
      }
      if (features.length > 1) {
        final alts = <List<LatLng>>[];
        for (int i = 1; i < features.length; i++) {
          final geo = features[i]['geometry'];
          final coordsList = geo['coordinates'] as List;
          alts.add(coordsList
              .map<LatLng>((c) => LatLng(c[1] as double, c[0] as double))
              .toList());
        }
        setState(() => alternativeRoutes = alts);
      } else {
        setState(() => alternativeRoutes = []);
      }
    }
  }

  /// Marks a destination as completed in Firebase using the same logic as AssignedRoutes.
  Future<void> _markDestinationAsCompleted(Map<String, dynamic> destination) async {
    try {
      final daysOrder = [
        "Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"
      ];
      final currentDay = daysOrder[ DateTime.now().weekday - 1 ];

      // 1) Query by driverFullName
      final truckQuery = FirebaseDatabase.instance
          .ref()
          .child('trucks')
          .orderByChild('vehicleDriver')
          .equalTo(widget.driverFullName);
      final truckSnap = await truckQuery.get();
      if (!truckSnap.exists) return;

      final truckKey = truckSnap.children.first.key!;
      final dayRef = FirebaseDatabase.instance
          .ref()
          .child('trucks')
          .child(truckKey)
          .child('schedules')
          .child('days')
          .child(currentDay);

      // 2) Fetch that day's data
      final daySnap = await dayRef.get();
      if (!daySnap.exists) return;

      // ↘️ Here’s the fix ↙️
      final raw = daySnap.value as Map<dynamic, dynamic>;
      final dayData = raw.cast<String, dynamic>();

      if (dayData['places'] is! List) return;
      final places = List<Map<String, dynamic>>.from(
          (dayData['places'] as List).map((e) => Map<String, dynamic>.from(e as Map))
      );

      // 3) Find & mark the right place
      final idx = places.indexWhere((p) {
        if (p['id'] != null && destination['id'] != null) {
          return p['id'] == destination['id'];
        }
        return p['name'] == destination['name']
            && p['latitude'] == destination['latitude']
            && p['longitude'] == destination['longitude'];
      });
      if (idx == -1) return;

      places[idx]['completed'] = true;
      await dayRef.child('places').set(places);
      print("Marked place $idx on $currentDay completed");
    } catch (e) {
      print("Error marking destination as completed: $e");
    }
  }

  /// Toggles routing on/off.
  Future<void> _toggleRouting() async {
    setState(() => _isRouteLoading = true);
    if (isRoutingStarted) {
      setState(() {
        isRoutingStarted = false;
        routePoints = [];
        alternativeRoutes = [];
        _targetLocation = null;
        _targetLocationName = null;
      });
    } else {
      if (currentLocation == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Current location not available.")),
        );
      } else if (_displayLocations.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No destinations available.")),
        );
      } else {
        setState(() => isRoutingStarted = true);
        final nearestIdx =
        _getNearestDestinationIndex(currentLocation!, _displayLocations);
        final nextDest = _displayLocations[nearestIdx];
        final destLatLng = LatLng(
          nextDest['latitude'] as double,
          nextDest['longitude'] as double,
        );
        setState(() {
          _targetLocation = destLatLng;
          _targetLocationName = nextDest['name'] ?? "Unknown Destination";
        });
        await _updateDynamicRoute(currentLocation!, destLatLng);
        if (!isTraveling) {
          await _startTravel();
        }
      }
    }
    setState(() => _isRouteLoading = false);
  }

  /// Updated _toggleGPSTracking prevents turning off GPS when travel is active.
  Future<void> _toggleGPSTracking() async {
    setState(() => _isGpsLoading = true);
    try {
      if (isTracking) {
        if (isTraveling) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Cannot turn off GPS while travel is active."),
            ),
          );
          return;
        }
        await _positionStreamSubscription?.cancel();
        await fb.FlutterBackground.disableBackgroundExecution();
        setState(() { isTracking = false; currentLocation = null; });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Location turned OFF")),
        );
      } else {
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          perm = await Geolocator.requestPermission();
          if (perm != LocationPermission.whileInUse &&
              perm != LocationPermission.always) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Location permission not granted")),
            );
            return;
          }
        }
        await fb.FlutterBackground.enableBackgroundExecution();
        _positionStreamSubscription = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          ),
        ).listen((pos) async {
          setState(() => currentLocation = LatLng(pos.latitude, pos.longitude));
          _updateLocationName();
          if (isRoutingStarted && currentLocation != null) {
            _mapController.move(currentLocation!, _mapController.zoom);
          }
          // Update truck location on Firebase
          FirebaseDatabase.instance
              .ref()
              .child('trucks')
              .child(widget.truckId)
              .update({
            'truckCurrentLocation': {
              'latitude': pos.latitude,
              'longitude': pos.longitude,
            },
          });
          // Distance traveled logic...
          if (isTraveling && currentLocation != null && _lastTravelLocation != null) {
            final d = Distance().as(LengthUnit.Meter, _lastTravelLocation!, currentLocation!);
            setState(() => _metersTraveled += d);
          }
          _lastTravelLocation = currentLocation;
          // Check arrival to destinations/landfill...
        });
        setState(() => isTracking = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Location turned ON")),
        );
      }
    } catch (e) {
      print("Error in GPS tracking: $e");
    } finally {
      setState(() => _isGpsLoading = false);
    }
  }

  /// Starts travel by prompting for "Fuel Loaded" and "Odometer Reading".
  Future<void> _startTravel() async {
    setState(() => _isTravelLoading = true);
    final result = await showFuelAndOdometerDialog(context);
    if (result == null) {
      setState(() => _isTravelLoading = false);
      return;
    }
    startupFuel = result['fuel'];
    startupOdometer = result['odometer'];
    setState(() {
      isTraveling = true;
      travelDuration = Duration.zero;
      _metersTraveled = 0.0;
      _lastTravelLocation = currentLocation;
    });
    _travelTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => travelDuration += const Duration(seconds: 1));
    });
    setState(() => _isTravelLoading = false);
  }

  /// Stops travel and submits a report.
  Future<void> _stopTravelAndSubmitReport() async {
    _travelTimer?.cancel();
    setState(() => isTraveling = false);
    await fb.FlutterBackground.disableBackgroundExecution();

    if (_disposedWeight == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter disposed weight.")),
      );
      return;
    }

    final fuelUsed = startupFuel ?? 0.0;
    final kmTraveled = _metersTraveled / 1000;
    final report = {
      'truckName': widget.truckName,
      'date': DateTime.now().toIso8601String(),
      'timeTravel': travelDuration.inSeconds,
      'fuelUsed': fuelUsed,
      'odometerReading': startupOdometer,
      'disposedTrashWeight': _disposedWeight,
      'kilometersTraveled': kmTraveled,
    };
    await FirebaseDatabase.instance
        .ref()
        .child('reports')
        .child('truckusagedata')
        .push()
        .set(report);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Travel report submitted")),
    );
    setState(() {
      _disposedWeight = null;
      travelDuration = Duration.zero;
      _metersTraveled = 0.0;
      startupFuel = null;
      startupOdometer = null;
    });
  }

  void _recenterMap() {
    if (currentLocation != null) {
      _mapController.move(currentLocation!, 16.0);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Current location not available")),
      );
    }
  }

  Future<void> _editDisposedWeight() async {
    final controller = TextEditingController();
    double? input;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Enter Disposed Trash Weight (kg)"),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))
          ],
          decoration: const InputDecoration(hintText: "Enter value"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          TextButton(
            onPressed: () {
              input = double.tryParse(controller.text);
              Navigator.pop(context);
            },
            child: const Text("OK"),
          ),
        ],
      ),
    );
    if (input != null) {
      setState(() => _disposedWeight = (_disposedWeight ?? 0) + input!);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Disposed weight: $_disposedWeight kg")),
      );
    }
  }

  Widget _buildFloatingButtons() {
    if (finalStage == "landfill") {
      return FloatingActionButton(
        onPressed: () async => await _handleFinalTrashInputAndRouteToMotorpool(),
        child: const Icon(Icons.delete, color: Colors.white),
        backgroundColor: Colors.green,
        tooltip: "Enter Trash Weight at Landfill",
      );
    }
    if (finalStage == "motorpool") {
      return FloatingActionButton(
        onPressed: () async {
          await _stopTravelAndSubmitReport();
          Navigator.of(context).pop(true);
        },
        child: const Icon(Icons.check, color: Colors.white),
        backgroundColor: Colors.green,
        tooltip: "Stop Travel",
      );
    }
    if (isTraveling && isRoutingStarted) {
      return FloatingActionButton(
        onPressed: () async {
          if (_showTrashInput) {
            await _handleLandfillTrashInput();
            setState(() => _showTrashInput = false);
          } else {
            setState(() => _showTrashInput = true);
            await _handleTruckFull();
          }
        },
        child: Icon(
          _showTrashInput ? Icons.delete : Icons.local_shipping,
          color: Colors.white,
        ),
        backgroundColor: _showTrashInput ? Colors.green : Colors.red,
        tooltip: _showTrashInput
            ? "Enter Trash Weight at Landfill"
            : "Truck is Full – route to Landfill",
      );
    }
    return Container();
  }

  Future<void> _handleTruckFull() async {
    if (currentLocation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Current location not available.")),
      );
      return;
    }
    setState(() {
      isTruckFull = true;
      _targetLocation = landfillLatLng;
      _targetLocationName = "Landfill";
    });
    await _updateDynamicRoute(currentLocation!, landfillLatLng);
  }

  Future<void> _handleLandfillTrashInput() async {
    await _editDisposedWeight();
    if (_displayLocations.isNotEmpty) {
      final idx = _getNearestDestinationIndex(currentLocation!, _displayLocations);
      final next = _displayLocations[idx];
      final nextLatLng = LatLng(next['latitude'] as double, next['longitude'] as double);
      setState(() {
        isTruckFull = false;
        isAtLandfill = false;
        _targetLocation = nextLatLng;
        _targetLocationName = next['name'] ?? "Unknown Destination";
      });
      await _updateDynamicRoute(currentLocation!, nextLatLng);
    } else {
      setState(() {
        finalStage = "landfill";
        isTruckFull = false;
        isAtLandfill = false;
        _targetLocation = landfillLatLng;
        _targetLocationName = "Landfill";
      });
      await _updateDynamicRoute(currentLocation!, landfillLatLng);
    }
  }

  Future<void> _handleFinalTrashInputAndRouteToMotorpool() async {
    await _editDisposedWeight();
    setState(() {
      _targetLocation = motorpoolLatLng;
      _targetLocationName = "Motorpool";
    });
    await _updateDynamicRoute(currentLocation!, motorpoolLatLng);
    setState(() => finalStage = "motorpool");
  }

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    _travelTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    List<Marker> markers = _displayLocations.map((location) {
      return Marker(
        point: LatLng(location['latitude'] as double, location['longitude'] as double),
        width: 40,
        height: 40,
        child: GestureDetector(
          onLongPress: () async {
            await _markDestinationAsCompleted(location);
            setState(() => _displayLocations.remove(location));
            if (!isRoutingStarted && _displayLocations.length >= 2) {
              await _fetchRoute();
            }
            if (isRoutingStarted) {
              if (_displayLocations.isNotEmpty && currentLocation != null) {
                final idx = _getNearestDestinationIndex(currentLocation!, _displayLocations);
                final next = _displayLocations[idx];
                final latlng = LatLng(next['latitude'] as double, next['longitude'] as double);
                setState(() {
                  _targetLocation = latlng;
                  _targetLocationName = next['name'] ?? "Unknown Destination";
                });
                await _updateDynamicRoute(currentLocation!, latlng);
              } else {
                setState(() {
                  isRoutingStarted = false;
                  routePoints = [];
                  alternativeRoutes = [];
                  _targetLocation = landfillLatLng;
                  _targetLocationName = "Landfill";
                  finalStage = "landfill";
                });
                await _updateDynamicRoute(currentLocation!, landfillLatLng);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("All destinations reached. Routing to Landfill.")),
                );
              }
            }
          },
          child: const Icon(Icons.location_pin, color: Colors.green, size: 40),
        ),
      );
    }).toList();

    String assetPath = 'assets/images/default-truck.png';
    if (truckType == 'Garbage Truck') {
      assetPath = 'assets/images/garbage-truck.png';
    } else if (truckType == 'Sewage Truck') {
      assetPath = 'assets/images/sewage-truck.png';
    }

    if (currentLocation != null) {
      markers.add(
        Marker(
          point: currentLocation!,
          width: 50,
          height: 50,
          child: Image.asset(assetPath, fit: BoxFit.contain),
        ),
      );
    }

    return WillPopScope(
      onWillPop: () async {
        if (isTraveling) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Travel mode active. Back button disabled.")),
          );
          return false;
        }
        return true;
      },
      child: Scaffold(
        floatingActionButton: Padding(
          padding: EdgeInsets.only(bottom: _bottomOverlayHeight + 10),
          child: _buildFloatingButtons(),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        body: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: currentLocation ??
                    (_displayLocations.isNotEmpty
                        ? LatLng(_displayLocations[0]['latitude'] as double,
                        _displayLocations[0]['longitude'] as double)
                        : const LatLng(7.4413, 125.8043)),
                initialZoom: 14.0,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                ),
                if (routePoints.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      Polyline(points: routePoints, strokeWidth: 4.0, color: Colors.blue),
                    ],
                  ),
                for (var alt in alternativeRoutes)
                  PolylineLayer(
                    polylines: [
                      Polyline(points: alt, strokeWidth: 4.0, color: Colors.green.withOpacity(0.5)),
                    ],
                  ),
                MarkerLayer(markers: markers),
              ],
            ),
            Positioned(
              top: 25,
              left: 15,
              right: 15,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.green),
                      onPressed: () {
                        if (isTraveling) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("Travel mode active.")),
                          );
                        } else {
                          Navigator.of(context).pop(true);
                        }
                      },
                    ),
                    Expanded(
                      child: Text(
                        _locationName,
                        style: const TextStyle(color: Colors.green, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.my_location, color: Colors.blue),
                      onPressed: _recenterMap,
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: screenHeight * 0.02,
              left: screenWidth * 0.05,
              right: screenWidth * 0.05,
              child: MeasureSize(
                onChange: (size) {
                  if (_bottomOverlayHeight != size.height) {
                    setState(() => _bottomOverlayHeight = size.height);
                  }
                },
                child: Container(
                  padding: EdgeInsets.symmetric(
                    vertical: screenHeight * 0.015,
                    horizontal: screenWidth * 0.05,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(10.0),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_targetLocation != null)
                        Text(
                          'Routing to: ${_targetLocationName ?? '(${_targetLocation!.latitude.toStringAsFixed(4)}, ${_targetLocation!.longitude.toStringAsFixed(4)})'}',
                          style: TextStyle(
                              color: Colors.green,
                              fontSize: screenWidth * 0.035,
                              fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      if (_targetLocation != null) SizedBox(height: screenHeight * 0.015),
                      Text(
                        'Collection Schedule: ${widget.day}',
                        style: TextStyle(
                            color: Colors.green,
                            fontSize: screenWidth * 0.035,
                            fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: screenHeight * 0.015),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: _toggleGPSTracking,
                              child: Column(
                                children: [
                                  _isGpsLoading
                                      ? SizedBox(
                                    width: 30,
                                    height: 30,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                                    ),
                                  )
                                      : Icon(
                                    isTracking ? Icons.gps_fixed : Icons.gps_not_fixed,
                                    color: Colors.green,
                                    size: 30,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "GPS",
                                    style: TextStyle(color: Colors.green, fontSize: screenWidth * 0.035),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () async {
                                if (isTraveling) {
                                  await _stopTravelAndSubmitReport();
                                } else {
                                  await _startTravel();
                                  if (!isRoutingStarted) {
                                    await _toggleRouting();
                                  }
                                }
                              },
                              child: Column(
                                children: [
                                  _isTravelLoading
                                      ? SizedBox(
                                    width: 30,
                                    height: 30,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                                    ),
                                  )
                                      : Icon(
                                    isTraveling ? Icons.stop : Icons.play_arrow,
                                    color: Colors.green,
                                    size: 30,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    isTraveling ? _formatDuration(travelDuration) : "Start Travel",
                                    style: TextStyle(color: Colors.green, fontSize: screenWidth * 0.035),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: _toggleRouting,
                              child: Column(
                                children: [
                                  _isRouteLoading
                                      ? SizedBox(
                                    width: 30,
                                    height: 30,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                                    ),
                                  )
                                      : const Icon(Icons.navigation, color: Colors.green, size: 30),
                                  const SizedBox(height: 4),
                                  Text(
                                    isRoutingStarted ? "Stop Route" : "Start Route",
                                    style: TextStyle(color: Colors.green, fontSize: screenWidth * 0.035),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Custom centered modal dialog prompt for fuel and odometer readings.
Future<Map<String, double>?> showFuelAndOdometerDialog(BuildContext context) async {
  final fuelController = TextEditingController();
  final odoController = TextEditingController();

  return await showDialog<Map<String, double>>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: EdgeInsets.zero,
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.green.shade600, Colors.green.shade400],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.local_shipping, color: Colors.white, size: 28),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        "Enter Truck Details",
                        style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                child: Column(
                  children: [
                    TextField(
                      controller: fuelController,
                      decoration: InputDecoration(
                        labelText: "Fuel Loaded (liters)",
                        prefixIcon: Icon(Icons.local_gas_station, color: Colors.green.shade400, size: 28),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: odoController,
                      decoration: InputDecoration(
                        labelText: "Odometer Reading",
                        prefixIcon: Icon(Icons.speed, color: Colors.green.shade400, size: 28),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade400,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        final fuelValue = double.tryParse(fuelController.text);
                        final odoValue = double.tryParse(odoController.text);
                        if (fuelValue != null && odoValue != null) {
                          Navigator.of(context).pop({
                            'fuel': fuelValue,
                            'odometer': odoValue,
                          });
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("Please enter valid values.")),
                          );
                        }
                      },
                      child: const Text("Submit"),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
