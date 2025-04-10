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
    final context = this.context;
    if (!mounted) return;
    final Size newSize = context.size ?? Size.zero;
    widget.onChange(newSize);
  }
}

class MapScreen extends StatefulWidget {
  final String day;
  final List<Map<String, dynamic>> locations;
  // For reporting purposes:
  final String truckName; // Only truck name (without plate) will be used.
  final String truckId; // The truck's Firebase key.

  const MapScreen({
    Key? key,
    required this.day,
    required this.locations,
    required this.truckName,
    required this.truckId,
  }) : super(key: key);

  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // Existing state variables.
  List<LatLng> routePoints = [];
  bool isTracking = false;
  StreamSubscription<Position>? _positionStreamSubscription;
  LatLng? currentLocation;

  // Travel Timer variables.
  Timer? _travelTimer;
  Duration travelDuration = Duration.zero;
  bool isTraveling = false;
  double? startupFuel;

  // Distance traveled.
  double _metersTraveled = 0.0;
  LatLng? _lastTravelLocation;

  // Routing variables.
  bool isRoutingStarted = false;
  late List<Map<String, dynamic>> _displayLocations;
  List<List<LatLng>> alternativeRoutes = [];

  // Loading flags.
  bool _isGpsLoading = false;
  bool _isTravelLoading = false;
  bool _isRouteLoading = false;

  // Reverse geocoding location name.
  String _locationName = "Loading Current Location...";

  // Dynamic routing target.
  LatLng? _targetLocation;
  String? _targetLocationName;

  // Disposed trash weight.
  double? _disposedWeight;

  // Truck type (for custom marker).
  String truckType = 'default';

  // Used to adjust overlay position.
  double _bottomOverlayHeight = 0;

  // New state variables for the landfill process.
  bool isTruckFull = false;
  bool isAtLandfill = false;
  // Toggle between truck and trash icons during travel.
  bool _showTrashInput = false;
  // Final stage variable: "landfill" means route to landfill; "motorpool" means route to motorpool.
  String? finalStage;

  // Landfill coordinates (7°30'24.0"N, 125°49'05.2"E).
  final LatLng landfillLatLng = LatLng(7.506667, 125.818111);
  // Motorpool coordinates (7.4493° N, 125.8255° E).
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
    DatabaseReference truckRef = FirebaseDatabase.instance
        .ref()
        .child('trucks')
        .child(widget.truckId);
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
    List<ConnectivityResult> results =
    await Connectivity().checkConnectivity();
    return results.any((result) => result != ConnectivityResult.none);
  }

  /// If there are at least two destinations, fetch the full route.
  void _initRoute() async {
    if (_displayLocations.length >= 2) {
      bool connected = await _checkConnectivity();
      if (connected) {
        await _fetchRoute();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("No data connection. Cannot fetch full route.")),
        );
      }
    }
  }

  Future<void> _initBackgroundExecution() async {
    final androidConfig = fb.FlutterBackgroundAndroidConfig(
      notificationTitle: "Hakot Driver App",
      notificationText: "Tracking location and travel time in background",
      notificationIcon:
      fb.AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
    );
    bool initialized =
    await fb.FlutterBackground.initialize(androidConfig: androidConfig);
    print("Background execution initialized: $initialized");
  }

  /// Reverse geocoding via ORS.
  Future<void> _updateLocationName() async {
    if (currentLocation != null) {
      if (!await _checkConnectivity()) {
        setState(() {
          _locationName = "No data connection";
        });
        return;
      }
      try {
        final url =
            "https://api.openrouteservice.org/geocode/reverse?api_key=$openRouteServiceApiKey&point.lat=${currentLocation!.latitude}&point.lon=${currentLocation!.longitude}&size=1";
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data["features"] != null && data["features"].isNotEmpty) {
            String label =
                data["features"][0]["properties"]["label"] ?? "Unknown location";
            setState(() {
              _locationName = label;
            });
          } else {
            setState(() {
              _locationName = "Unknown location";
            });
          }
        } else {
          setState(() {
            _locationName = "Unknown location";
          });
        }
      } catch (e) {
        setState(() {
          _locationName = "Error retrieving location";
        });
      }
    }
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return "${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}";
    } else {
      return "${twoDigits(minutes)}:${twoDigits(seconds)}";
    }
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
        const SnackBar(
            content: Text("No data connection. Please check your network.")),
      );
      return;
    }
    List<List<double>> coordinates = _displayLocations.map((location) {
      return [location['longitude'] as double, location['latitude'] as double];
    }).toList();

    final url = Uri.parse(
        'https://api.openrouteservice.org/v2/directions/driving-car/geojson');
    final body = jsonEncode({'coordinates': coordinates});
    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': openRouteServiceApiKey,
          'Content-Type': 'application/json',
        },
        body: body,
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['features'] != null && data['features'].isNotEmpty) {
          final geometry = data['features'][0]['geometry'];
          if (geometry != null &&
              geometry['type'] == 'LineString' &&
              geometry['coordinates'] is List) {
            List<dynamic> coords = geometry['coordinates'];
            List<LatLng> points = coords.map<LatLng>((coord) {
              return LatLng(coord[1] as double, coord[0] as double);
            }).toList();
            setState(() {
              routePoints = points;
            });
          }
        }
      } else {
        print('ORS error: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      print("Error fetching route: $e");
    }
  }

  /// Updates the dynamic route from start to destination.
  Future<void> _updateDynamicRoute(
      LatLng start, LatLng destination) async {
    if (!await _checkConnectivity()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("No data connection. Please check your network.")),
      );
      return;
    }
    final url = Uri.parse(
        'https://api.openrouteservice.org/v2/directions/driving-car/geojson');
    Map<String, dynamic> bodyMap = {
      "coordinates": [
        [start.longitude, start.latitude],
        [destination.longitude, destination.latitude]
      ],
      "preference": "shortest",
      "alternative_routes": {"share_factor": 0.6, "target_count": 3}
    };
    final body = jsonEncode(bodyMap);
    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': openRouteServiceApiKey,
          'Content-Type': 'application/json',
        },
        body: body,
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['features'] != null && data['features'].isNotEmpty) {
          final geometry = data['features'][0]['geometry'];
          if (geometry != null &&
              geometry['type'] == 'LineString' &&
              geometry['coordinates'] is List) {
            List<dynamic> coords = geometry['coordinates'];
            List<LatLng> mainRoute = coords.map<LatLng>((coord) {
              return LatLng(coord[1] as double, coord[0] as double);
            }).toList();
            setState(() {
              routePoints = mainRoute;
            });
          }
          if (data['features'].length > 1) {
            List<List<LatLng>> alternatives = [];
            for (int i = 1; i < data['features'].length; i++) {
              final altGeometry = data['features'][i]['geometry'];
              if (altGeometry != null &&
                  altGeometry['type'] == 'LineString' &&
                  altGeometry['coordinates'] is List) {
                List<dynamic> altCoords = altGeometry['coordinates'];
                List<LatLng> altRoute = altCoords.map<LatLng>((coord) {
                  return LatLng(coord[1] as double, coord[0] as double);
                }).toList();
                alternatives.add(altRoute);
              }
            }
            setState(() {
              alternativeRoutes = alternatives;
            });
          } else {
            setState(() {
              alternativeRoutes = [];
            });
          }
        }
      } else {
        print('ORS error: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      print("Error fetching dynamic route: $e");
    }
  }

  /// Marks a destination as completed in Firebase.
  Future<void> _markDestinationAsCompleted(
      Map<String, dynamic> destination) async {
    try {
      DatabaseReference dayRef = FirebaseDatabase.instance
          .ref()
          .child('trucks')
          .child(widget.truckId)
          .child('schedules')
          .child('days')
          .child(widget.day);
      DataSnapshot snapshot = await dayRef.get();
      print("Day snapshot: ${snapshot.value}");
      if (snapshot.exists && snapshot.value is Map) {
        final dayData =
        Map<String, dynamic>.from(snapshot.value as Map<dynamic, dynamic>);
        if (dayData['places'] is List) {
          List places = List.from(dayData['places']);
          int index = places.indexWhere((place) {
            if (place is Map) {
              if (destination.containsKey('id') && place.containsKey('id')) {
                return place['id'] == destination['id'];
              }
              double destLat =
                  double.tryParse(destination['latitude'].toString()) ?? 0;
              double destLng =
                  double.tryParse(destination['longitude'].toString()) ?? 0;
              double placeLat =
                  double.tryParse(place['latitude'].toString()) ?? 0;
              double placeLng =
                  double.tryParse(place['longitude'].toString()) ?? 0;
              return (place['name'] == destination['name']) &&
                  (placeLat == destLat) &&
                  (placeLng == destLng);
            }
            return false;
          });
          print("Matching destination index: $index");
          if (index != -1) {
            Map<String, dynamic> updatedPlace =
            Map<String, dynamic>.from(places[index]);
            updatedPlace['completed'] = true;
            places[index] = updatedPlace;
            await dayRef.child('places').set(places);
            print("Marked destination at index $index as completed.");
          } else {
            print("Destination not found in the day's places.");
          }
        } else {
          print("No 'places' list found in the day's data.");
        }
      } else {
        print("Day data not found for ${widget.day}");
      }
    } catch (e) {
      print("Error marking destination as completed: $e");
    }
  }

  /// Optionally, resets the schedule to the original if needed.
  Future<void> _resetScheduleToOriginal() async {
    DatabaseReference dayRef = FirebaseDatabase.instance
        .ref()
        .child('trucks')
        .child(widget.truckId)
        .child('schedules')
        .child('days')
        .child(widget.day);
    DataSnapshot originalSnapshot = await FirebaseDatabase.instance
        .ref()
        .child('trucks')
        .child(widget.truckId)
        .child('schedules')
        .child('originalSchedules')
        .child(widget.day)
        .get();
    if (originalSnapshot.exists) {
      await dayRef.set(originalSnapshot.value);
    }
  }

  /// Toggles routing on/off.
  Future<void> _toggleRouting() async {
    setState(() {
      _isRouteLoading = true;
    });

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
        setState(() {
          isRoutingStarted = true;
        });
        int nearestIndex =
        _getNearestDestinationIndex(currentLocation!, _displayLocations);
        Map<String, dynamic> nextDest = _displayLocations[nearestIndex];
        LatLng destination = LatLng(
          nextDest['latitude'] as double,
          nextDest['longitude'] as double,
        );
        setState(() {
          _targetLocation = destination;
          _targetLocationName =
              nextDest["name"] ?? "Unknown Destination";
        });
        await _updateDynamicRoute(currentLocation!, destination);
        if (!isTraveling) {
          await _startTravel();
        }
      }
    }
    setState(() {
      _isRouteLoading = false;
    });
  }

  Future<void> _toggleGPSTracking() async {
    setState(() {
      _isGpsLoading = true;
    });
    try {
      if (isTracking) {
        await _positionStreamSubscription?.cancel();
        await fb.FlutterBackground.disableBackgroundExecution();
        setState(() {
          isTracking = false;
          currentLocation = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Location turned OFF")),
        );
      } else {
        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          permission = await Geolocator.requestPermission();
          if (permission != LocationPermission.whileInUse &&
              permission != LocationPermission.always) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Location permission not granted")),
            );
            return;
          }
        }
        await fb.FlutterBackground.enableBackgroundExecution();
        _positionStreamSubscription =
            Geolocator.getPositionStream(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 10,
              ),
            ).listen((Position position) async {
              setState(() {
                currentLocation = LatLng(position.latitude, position.longitude);
              });
              _updateLocationName();
              if (isRoutingStarted && currentLocation != null) {
                _mapController.move(currentLocation!, _mapController.zoom);
              }
              // Update truck location on Firebase.
              DatabaseReference truckRef = FirebaseDatabase.instance
                  .ref()
                  .child('trucks')
                  .child(widget.truckId);
              truckRef.update({
                'truckCurrentLocation': {
                  'latitude': position.latitude,
                  'longitude': position.longitude,
                },
              });
              // Calculate distance traveled.
              if (isTraveling && currentLocation != null) {
                if (_lastTravelLocation != null) {
                  double d = Distance().as(
                      LengthUnit.Meter, _lastTravelLocation!, currentLocation!);
                  setState(() {
                    _metersTraveled += d;
                  });
                }
                _lastTravelLocation = currentLocation;
              }
              // Check if routing is on and update destination if near.
              if (isRoutingStarted && currentLocation != null) {
                if (isTruckFull) {
                  double landfillDistance = Distance().as(
                      LengthUnit.Meter, currentLocation!, landfillLatLng);
                  if (landfillDistance < 50 && !isAtLandfill) {
                    setState(() {
                      isAtLandfill = true;
                    });
                  }
                } else {
                  int nearestIndex =
                  _getNearestDestinationIndex(currentLocation!, _displayLocations);
                  Map<String, dynamic> nearestDest =
                  _displayLocations[nearestIndex];
                  LatLng destLatLng = LatLng(
                    nearestDest['latitude'] as double,
                    nearestDest['longitude'] as double,
                  );
                  double distance = Distance().as(
                      LengthUnit.Meter, currentLocation!, destLatLng);
                  // Debug print the current distance and remaining destinations.
                  print("Distance to destination: $distance meters. Remaining destinations: ${_displayLocations.length}");
                  if (distance < 50) {
                    // Mark destination as completed.
                    await _markDestinationAsCompleted(nearestDest);
                    setState(() {
                      _displayLocations.removeAt(nearestIndex);
                    });
                    // Debug print after removal.
                    print("Destination removed. Remaining: ${_displayLocations.length}");
                    if (_displayLocations.isEmpty) {
                      // All destinations reached.
                      print("All destinations reached, routing to landfill");
                      setState(() {
                        finalStage = "landfill";
                        isTruckFull = false;
                        isAtLandfill = false;
                        _targetLocation = landfillLatLng;
                        _targetLocationName = "Landfill";
                      });
                      await _updateDynamicRoute(currentLocation!, landfillLatLng);
                      _mapController.move(landfillLatLng, _mapController.zoom);
                    } else {
                      int newNearestIndex =
                      _getNearestDestinationIndex(currentLocation!, _displayLocations);
                      Map<String, dynamic> newDest =
                      _displayLocations[newNearestIndex];
                      LatLng newDestLatLng = LatLng(
                        newDest['latitude'] as double,
                        newDest['longitude'] as double,
                      );
                      setState(() {
                        _targetLocation = newDestLatLng;
                        _targetLocationName =
                            newDest["name"] ?? "Unknown Destination";
                      });
                      await _updateDynamicRoute(currentLocation!, newDestLatLng);
                    }
                  }
                }
              }
            });
        setState(() {
          isTracking = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Location turned ON")),
        );
      }
    } catch (e) {
      print("Error in GPS tracking: $e");
    } finally {
      setState(() {
        _isGpsLoading = false;
      });
    }
  }

  Future<void> _startTravel() async {
    setState(() {
      _isTravelLoading = true;
    });
    double? fuel = await _showFuelDialog("Enter Startup Fuel (liters)");
    if (fuel == null) {
      setState(() {
        _isTravelLoading = false;
      });
      return;
    }
    startupFuel = fuel;
    await fb.FlutterBackground.enableBackgroundExecution();
    setState(() {
      isTraveling = true;
      travelDuration = Duration.zero;
      _metersTraveled = 0;
      _lastTravelLocation = currentLocation;
    });
    _travelTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        travelDuration += const Duration(seconds: 1);
      });
    });
    setState(() {
      _isTravelLoading = false;
    });
  }

  /// Stops travel and submits a report.
  Future<void> _stopTravelAndSubmitReport() async {
    _travelTimer?.cancel();
    setState(() {
      isTraveling = false;
    });
    await fb.FlutterBackground.disableBackgroundExecution();

    double? remainingFuel =
    await _showFuelDialog("Enter Remaining Fuel (liters)");
    if (remainingFuel == null) return;

    double fuelUsed = (startupFuel ?? 0) - remainingFuel;
    double kilometersTraveled = _metersTraveled / 1000;

    if (_disposedWeight == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                "Please enter disposed trash weight using the trash icon.")),
      );
      return;
    }

    Map<String, dynamic> report = {
      'truckName': widget.truckName.split(' - ').first,
      'date': DateTime.now().toIso8601String(),
      'timeTravel': travelDuration.inSeconds,
      'fuelUsed': fuelUsed,
      'disposedTrashWeight': _disposedWeight,
      'kilometersTraveled': kilometersTraveled,
    };

    DatabaseReference reportsRef = FirebaseDatabase.instance
        .ref()
        .child('reports')
        .child('truckusagedata');
    await reportsRef.push().set(report);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Travel report submitted")),
    );

    setState(() {
      _disposedWeight = null;
      travelDuration = Duration.zero;
      _metersTraveled = 0;
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
    TextEditingController controller = TextEditingController();
    double? inputWeight;
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Enter Disposed Trash Weight (kg)"),
          content: TextField(
            controller: controller,
            keyboardType:
            const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))
            ],
            decoration: const InputDecoration(hintText: "Enter value"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Please enter a value.")),
                  );
                  return;
                }
                inputWeight = double.tryParse(controller.text);
                Navigator.pop(context);
              },
              child: const Text("OK"),
            ),
          ],
        );
      },
    );
    if (inputWeight != null) {
      setState(() {
        _disposedWeight = (_disposedWeight ?? 0) + inputWeight!;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
            Text("Disposed Trash Weight updated to $_disposedWeight kg")),
      );
    }
  }

  Future<double?> _showFuelDialog(String title) async {
    TextEditingController controller = TextEditingController();
    double? result;
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            keyboardType:
            const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))
            ],
            decoration: const InputDecoration(hintText: "Enter value"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Please enter a value.")),
                  );
                  return;
                }
                result = double.tryParse(controller.text);
                Navigator.pop(context);
              },
              child: const Text("OK"),
            ),
          ],
        );
      },
    );
    return result;
  }

  /// New method to handle when the truck is full.
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

  /// New method to handle trash input at the landfill (for non-final stages).
  Future<void> _handleLandfillTrashInput() async {
    await _editDisposedWeight();
    if (_displayLocations.isNotEmpty) {
      // There are still destinations: reset full state and re-route.
      int nearestIndex =
      _getNearestDestinationIndex(currentLocation!, _displayLocations);
      Map<String, dynamic> newDest = _displayLocations[nearestIndex];
      LatLng newDestLatLng = LatLng(
        newDest['latitude'] as double,
        newDest['longitude'] as double,
      );
      setState(() {
        isTruckFull = false;
        isAtLandfill = false;
        _targetLocation = newDestLatLng;
        _targetLocationName = newDest["name"] ?? "Unknown Destination";
      });
      await _updateDynamicRoute(currentLocation!, newDestLatLng);
    } else {
      // All destinations completed: set final stage to "landfill".
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

  /// New method to handle the final trash input and then re-route to Motorpool.
  Future<void> _handleFinalTrashInputAndRouteToMotorpool() async {
    await _editDisposedWeight();
    // After trash input, re-route to Motorpool.
    setState(() {
      _targetLocation = motorpoolLatLng;
      _targetLocationName = "Motorpool";
    });
    await _updateDynamicRoute(currentLocation!, motorpoolLatLng);
    // Change final stage to "motorpool" so the check icon appears.
    setState(() {
      finalStage = "motorpool";
    });
  }

  /// New method to finalize travel.
  Future<void> _finishTravel() async {
    await _stopTravelAndSubmitReport();
  }

  /// Build a floating button based on the current state.
  Widget _buildFloatingButtons() {
    // When in final stage "landfill", show the trash icon to complete final trash input.
    if (finalStage == "landfill") {
      return FloatingActionButton(
        onPressed: () async {
          await _handleFinalTrashInputAndRouteToMotorpool();
        },
        child: const Icon(Icons.delete, color: Colors.white),
        backgroundColor: Colors.green,
        tooltip: "Enter Trash Weight at Landfill",
      );
    }
    // When in final stage "motorpool", show the check icon to finish travel.
    if (finalStage == "motorpool") {
      return FloatingActionButton(
        onPressed: _finishTravel,
        child: const Icon(Icons.check, color: Colors.white),
        backgroundColor: Colors.blue,
        tooltip: "Finish Travel and Submit Report",
      );
    }

    // When not in a final stage and travel is active with routing on.
    if (isTraveling && isRoutingStarted) {
      return FloatingActionButton(
        onPressed: () async {
          if (_showTrashInput) {
            // Trash icon is currently showing: input trash weight then revert back.
            await _handleLandfillTrashInput();
            setState(() {
              _showTrashInput = false;
            });
          } else {
            // Truck icon pressed: mark truck as full and toggle the icon.
            setState(() {
              _showTrashInput = true;
            });
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

    List<Marker> markers = _displayLocations.map<Marker>((location) {
      return Marker(
        point: LatLng(location['latitude'] as double,
            location['longitude'] as double),
        width: 40,
        height: 40,
        child: GestureDetector(
          onLongPress: () async {
            // First mark the destination as completed in Firebase.
            await _markDestinationAsCompleted(location);
            setState(() {
              _displayLocations.remove(location);
            });
            if (!isRoutingStarted && _displayLocations.length >= 2) {
              await _fetchRoute();
            }
            if (isRoutingStarted) {
              if (_displayLocations.isNotEmpty && currentLocation != null) {
                int nearestIndex =
                _getNearestDestinationIndex(currentLocation!, _displayLocations);
                Map<String, dynamic> newDest = _displayLocations[nearestIndex];
                LatLng newDestLatLng = LatLng(
                  newDest['latitude'] as double,
                  newDest['longitude'] as double,
                );
                setState(() {
                  _targetLocation = newDestLatLng;
                  _targetLocationName =
                      newDest["name"] ?? "Unknown Destination";
                });
                await _updateDynamicRoute(currentLocation!, newDestLatLng);
              } else {
                // Here we detect that all pins have been removed,
                // so we simulate the final stage activation.
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
          child: const Icon(
            Icons.location_pin,
            color: Colors.green,
            size: 40,
          ),
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
            const SnackBar(
                content: Text("Travel mode is active. Back button disabled.")),
          );
          return false;
        }
        Navigator.of(context).pop(true);
        return false;
      },
      child: Scaffold(
        floatingActionButton: Padding(
          padding: EdgeInsets.only(bottom: _bottomOverlayHeight + 10),
          child: _buildFloatingButtons(),
        ),
        floatingActionButtonLocation:
        FloatingActionButtonLocation.endFloat,
        body: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: currentLocation ??
                    (_displayLocations.isNotEmpty
                        ? LatLng(
                      _displayLocations[0]['latitude'] as double,
                      _displayLocations[0]['longitude'] as double,
                    )
                        : const LatLng(7.4413, 125.8043)),
                initialZoom: 14.0,
              ),
              children: [
                TileLayer(
                  urlTemplate:
                  'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                ),
                if (routePoints.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: routePoints,
                        strokeWidth: 4.0,
                        color: Colors.blue,
                      ),
                    ],
                  ),
                for (var altRoute in alternativeRoutes)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: altRoute,
                        strokeWidth: 4.0,
                        color: Colors.green.withOpacity(0.5),
                      ),
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
                padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                            const SnackBar(
                                content: Text(
                                    "Travel mode is active. Back button disabled.")),
                          );
                        } else {
                          Navigator.of(context).pop(true);
                        }
                      },
                    ),
                    Expanded(
                      child: Text(
                        _locationName,
                        style: const TextStyle(
                            color: Colors.green, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    IconButton(
                      icon:
                      const Icon(Icons.my_location, color: Colors.blue),
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
                    setState(() {
                      _bottomOverlayHeight = size.height;
                    });
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
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      if (_targetLocation != null)
                        SizedBox(height: screenHeight * 0.015),
                      Text(
                        'Collection Schedule: ${widget.day}',
                        style: TextStyle(
                          color: Colors.green,
                          fontSize: screenWidth * 0.035,
                          fontWeight: FontWeight.bold,
                        ),
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
                                      valueColor:
                                      AlwaysStoppedAnimation<Color>(
                                          Colors.green),
                                    ),
                                  )
                                      : Icon(
                                    isTracking
                                        ? Icons.gps_fixed
                                        : Icons.gps_not_fixed,
                                    color: Colors.green,
                                    size: 30,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "GPS",
                                    style: TextStyle(
                                        color: Colors.green,
                                        fontSize: screenWidth * 0.035),
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
                                      valueColor:
                                      AlwaysStoppedAnimation<Color>(
                                          Colors.green),
                                    ),
                                  )
                                      : Icon(
                                    isTraveling
                                        ? Icons.stop
                                        : Icons.play_arrow,
                                    color: Colors.green,
                                    size: 30,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    isTraveling
                                        ? _formatDuration(travelDuration)
                                        : "Start Travel",
                                    style: TextStyle(
                                        color: Colors.green,
                                        fontSize: screenWidth * 0.035),
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
                                      valueColor:
                                      AlwaysStoppedAnimation<Color>(
                                          Colors.green),
                                    ),
                                  )
                                      : const Icon(
                                    Icons.navigation,
                                    color: Colors.green,
                                    size: 30,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    isRoutingStarted ? "Stop Route" : "Start Route",
                                    style: TextStyle(
                                        color: Colors.green,
                                        fontSize: screenWidth * 0.035),
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