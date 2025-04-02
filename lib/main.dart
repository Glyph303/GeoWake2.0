import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(GeoWakeApp());
}

class GeoWakeApp extends StatefulWidget {
  @override
  _GeoWakeAppState createState() => _GeoWakeAppState();
}

class _GeoWakeAppState extends State<GeoWakeApp> {
  bool isDarkMode = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: isDarkMode ? ThemeData.dark() : ThemeData.light(),
      home: GeoWakeScreen(
        toggleTheme: () {
          setState(() {
            isDarkMode = !isDarkMode;
          });
        },
        isDarkMode: isDarkMode,
      ),
    );
  }
}

class GeoWakeScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  final bool isDarkMode;
  GeoWakeScreen({required this.toggleTheme, required this.isDarkMode});

  @override
  _GeoWakeScreenState createState() => _GeoWakeScreenState();
}

class _GeoWakeScreenState extends State<GeoWakeScreen> {
  static const String graphHopperApiKey = "b7c8b48f-3be5-45e0-8b5b-0b258aba3f7c";

  double wakeDistance = 2.0;
  double distanceToDest = 0.0;
  bool alarmWasTriggered = false;
  bool alarmActive = false;
  GoogleMapController? mapController;
  Position? currentPosition;
  final AudioPlayer audioPlayer = AudioPlayer();
  LatLng? destLatLng;
  LatLng? simulatedPosition;
  bool isMockGPS = false;
  Timer? mockGPSTimer;
  final TextEditingController destinationController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initializeAudioPlayer();
    _getCurrentLocation();
  }

  void _initializeAudioPlayer() {
    audioPlayer.onPlayerStateChanged.listen((PlayerState state) {
      setState(() {
        alarmActive = state == PlayerState.playing;
      });
    });
  }

  @override
  void dispose() {
    mockGPSTimer?.cancel();
    audioPlayer.stop();
    audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      print("Location services are disabled.");
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.deniedForever) {
        print("Location permissions are permanently denied.");
        return;
      }
    }

    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() {
        currentPosition = position;
        isMockGPS = false;
        mockGPSTimer?.cancel();
        simulatedPosition = null;
        alarmWasTriggered = false;
        alarmActive = false;
      });
      _updateDistance();
      _moveCameraToCurrent();
    } catch (e) {
      print("Error getting location: $e");
    }
  }

  void _startMockGPS() {
    if (currentPosition == null) {
      print("Current position not available for mock GPS");
      return;
    }

    setState(() {
      isMockGPS = true;
      simulatedPosition = LatLng(currentPosition!.latitude, currentPosition!.longitude);
      alarmWasTriggered = false;
      alarmActive = false;
    });

    mockGPSTimer?.cancel();
    mockGPSTimer = Timer.periodic(Duration(seconds: 2), (timer) {
      if (simulatedPosition != null && destLatLng != null) {
        double step = 0.001;
        double latDiff = destLatLng!.latitude - simulatedPosition!.latitude;
        double lngDiff = destLatLng!.longitude - simulatedPosition!.longitude;
        double newLat = simulatedPosition!.latitude + (latDiff.sign * step);
        double newLng = simulatedPosition!.longitude + (lngDiff.sign * step);

        setState(() {
          simulatedPosition = LatLng(newLat, newLng);
          _updateDistance();
        });

        _moveCameraToMock();
        
        if (distanceToDest < wakeDistance && !alarmWasTriggered) {
          _triggerAlarm();
        }

        if (distanceToDest < 0.05) {
          timer.cancel();
        }
      }
    });
  }

  void _updateDistance() {
    if (destLatLng == null) return;
    
    final currentLatLng = isMockGPS && simulatedPosition != null 
        ? simulatedPosition!
        : currentPosition != null 
            ? LatLng(currentPosition!.latitude, currentPosition!.longitude)
            : null;

    if (currentLatLng != null) {
      setState(() {
        distanceToDest = calculateDistance(
          currentLatLng.latitude,
          currentLatLng.longitude,
          destLatLng!.latitude,
          destLatLng!.longitude,
        );
      });
    }
  }

  Future<void> _triggerAlarm() async {
    if (alarmWasTriggered) return;
    
    setState(() {
      alarmWasTriggered = true;
    });
    
    try {
      await audioPlayer.stop();
      await audioPlayer.play(AssetSource('alarm.mp3'));
    } catch (e) {
      print("Error playing alarm: $e");
    }
  }

  Future<void> _stopAlarm() async {
    try {
      await audioPlayer.stop();
      setState(() {
        alarmActive = false;
      });
    } catch (e) {
      print("Error stopping alarm: $e");
    }
  }

  Future<void> _searchDestination() async {
    String query = destinationController.text.trim();
    if (query.isEmpty) return;

    try {
      String url = "https://graphhopper.com/api/1/geocode?q=$query&limit=1&key=$graphHopperApiKey";
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data["hits"].isNotEmpty) {
          double lat = data["hits"][0]["point"]["lat"];
          double lon = data["hits"][0]["point"]["lng"];
          LatLng newDest = LatLng(lat, lon);

          setState(() {
            destLatLng = newDest;
            _updateDistance();
          });

          _moveCameraToDestination();
        }
      }
    } catch (e) {
      print("Error in geocoding: $e");
    }
  }

  void _moveCameraToCurrent() {
    if (currentPosition != null) {
      mapController?.animateCamera(
        CameraUpdate.newLatLng(
          LatLng(currentPosition!.latitude, currentPosition!.longitude),
        ),
      );
    }
  }

  void _moveCameraToDestination() {
    if (destLatLng != null) {
      mapController?.animateCamera(
        CameraUpdate.newLatLng(destLatLng!),
      );
    }
  }

  void _moveCameraToMock() {
    if (simulatedPosition != null) {
      mapController?.animateCamera(
        CameraUpdate.newLatLng(simulatedPosition!),
      );
    }
  }

  double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const double R = 6371;
    double dLat = (lat2 - lat1) * pi / 180;
    double dLon = (lon2 - lon1) * pi / 180;
    double a = sin(dLat / 2) * sin(dLat / 2) + 
               cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * 
               sin(dLon / 2) * sin(dLon / 2);
    double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('GeoWake'),
        backgroundColor: Colors.blueAccent,
        actions: [
          IconButton(
            icon: Icon(Icons.brightness_6),
            onPressed: widget.toggleTheme,
          ),
          if (alarmActive)
            IconButton(
              icon: Icon(Icons.alarm_off),
              onPressed: _stopAlarm,
              color: Colors.red,
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(16.0),
            child: Column(
              children: [
                TextField(
                  controller: destinationController,
                  decoration: InputDecoration(
                    labelText: "Enter Destination",
                    border: OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(Icons.search),
                      onPressed: _searchDestination,
                    ),
                  ),
                ),
                SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "Wake-up Distance: ${wakeDistance.toStringAsFixed(1)} km",
                      style: TextStyle(fontSize: 16),
                    ),
                    Switch(
                      value: widget.isDarkMode,
                      onChanged: (value) {
                        widget.toggleTheme();
                      },
                    ),
                  ],
                ),
                Slider(
                  min: 0.5,
                  max: 10.0,
                  value: wakeDistance,
                  divisions: 19,
                  label: "${wakeDistance.toStringAsFixed(1)} km",
                  onChanged: (value) {
                    setState(() {
                      wakeDistance = value;
                    });
                  },
                ),
                SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: _getCurrentLocation,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.indigo,
                        foregroundColor: Colors.white,
                      ),
                      child: Text("Real GPS"),
                    ),
                    ElevatedButton(
                      onPressed: _startMockGPS,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.pinkAccent,
                      ),
                      child: Text("Mock GPS"),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                Text(
                  "Distance to destination: ${distanceToDest.toStringAsFixed(2)} km",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: distanceToDest < wakeDistance ? Colors.red : Colors.green,
                  ),
                ),
                if (alarmActive)
                  Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: ElevatedButton(
                      onPressed: _stopAlarm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      child: Text("Stop Alarm"),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: LatLng(20.5937, 78.9629),
                zoom: 5,
              ),
              markers: {
                if (currentPosition != null && !isMockGPS)
                  Marker(
                    markerId: MarkerId('current'),
                    position: LatLng(currentPosition!.latitude, currentPosition!.longitude),
                    infoWindow: InfoWindow(title: "Your Location"),
                  ),
                if (isMockGPS && simulatedPosition != null)
                  Marker(
                    markerId: MarkerId('mock'),
                    position: simulatedPosition!,
                    infoWindow: InfoWindow(title: "Mock Location"),
                    icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
                  ),
                if (destLatLng != null)
                  Marker(
                    markerId: MarkerId('destination'),
                    position: destLatLng!,
                    infoWindow: InfoWindow(title: "Destination"),
                    icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
                  ),
              },
              onMapCreated: (GoogleMapController controller) {
                mapController = controller;
              },
            ),
          ),
        ],
      ),
    );
  }
}
