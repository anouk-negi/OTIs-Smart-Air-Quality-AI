import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'chart_widget.dart'; 

// Top-level background message handler required by Firebase Cloud Messaging
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint("Handling a background notification alert: ${message.messageId}");
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = true;
  
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint("Failed to load .env file: $e");
  }

  // Register background notification handler before app launch
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  runApp(const OtiAirApp());
}

class OtiAirApp extends StatelessWidget {
  const OtiAirApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "OTI's Smart AI Air Quality",
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF030712),
        textTheme: GoogleFonts.plusJakartaSansTextTheme(ThemeData.dark().textTheme),
      ),
      home: const DashboardScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<void> _firebaseInitialization;
  DatabaseReference? _dbRef;

  String _geminiReport = "Press the 'Execute Engine Synthesis' button to analyze target environmental datasets.";
  bool _isAiLoading = false;
  Map<dynamic, dynamic> _cachedHistoryData = {};
  bool _isAlertWindowActive = false; // Prevents overlapping alert dialog spam
  
  String _currentWindowStartStr = "N/A";
  String _currentWindowEndStr = "N/A";
  int _currentParsedCount = 0;

  @override
  void initState() {
    super.initState();
    _firebaseInitialization = _initFirebase();
  }

  Future<void> _initFirebase() async {
    if (kIsWeb) {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: dotenv.env['FIREBASE_API_KEY'] ?? 'MISSING_FIREBASE_KEY',
          authDomain: "oti-s-smart-ai-air-quality.firebaseapp.com",
          databaseURL: "https://oti-s-smart-ai-air-quality-default-rtdb.europe-west1.firebasedatabase.app",
          projectId: "oti-s-smart-ai-air-quality",
          storageBucket: "oti-s-smart-ai-air-quality.firebasestorage.app",
          messagingSenderId: "1003092175737",
          appId: "1:1003092175737:web:d7fd3e54e1922471f51da8",
          measurementId: "G-RN4SF34CZD",
        ),
      );
    } else {
      await Firebase.initializeApp();
    }

    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (e) {
      debugPrint("Auth warning: $e");
    }
    
    _dbRef = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: "https://oti-s-smart-ai-air-quality-default-rtdb.europe-west1.firebasedatabase.app"
    ).ref();

    // Initialize Push Notification Services
    await _setupCloudMessaging();

    // Set up out-of-band live stream telemetry inspector to safely trigger alerts without interrupting builds
    _setupTelemetrySpikeListener();
  }

  Future<void> _setupCloudMessaging() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;

    // Request permissions for foreground notifications (Required for Web, iOS, and Android 13+)
    NotificationSettings settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      debugPrint('Cloud Messaging Authorized.');

      // FIX: Only subscribe to topics if NOT running on Web
      if (!kIsWeb) {
        debugPrint('Subscribing to mobile broadcast topic...');
        await messaging.subscribeToTopic('air_quality_alerts');
      } else {
        debugPrint('Topic subscription skipped: Not supported on Flutter Web.');
      }
    }

    // This listener works on Web to intercept messages while the tab is open
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      if (message.notification != null) {
        _showInAppSpikeDialog(
          message.notification!.title ?? "⚠️ CLOUD ENVIRONMENTAL ALERT",
          message.notification!.body ?? "Threshold limits exceeded.",
        );
      }
    });
  }

  void _setupTelemetrySpikeListener() {
    _dbRef?.child('live_data').onValue.listen((event) {
      final liveData = event.snapshot.value as Map<dynamic, dynamic>? ?? {};
      final int scdCo2 = int.tryParse(liveData['scd_co2']?.toString() ?? '') ?? 0;
      final int pm25 = int.tryParse(liveData['pm2_5']?.toString() ?? '') ?? 0;

      // Evaluate spikes locally from the RTDB Stream pipeline
      if ((scdCo2 > 1000 || pm25 > 35) && !_isAlertWindowActive) {
        _showInAppSpikeDialog(
          "⚠️ TOXIC SPIKE DETECTED",
          "Immediate intervention required! Live sensor node feeds show structural metrics spiking past nominal ranges.\n\n• Carbon Dioxide: $scdCo2 PPM\n• Particulate Matter (PM2.5): $pm25 µg/m³",
        );
      }
    });
  }

  void _showInAppSpikeDialog(String title, String body) {
    setState(() { _isAlertWindowActive = true; });
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.redAccent, width: 1.5)),
        title: Text(title, style: GoogleFonts.orbitron(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 14)),
        content: Text(body, style: GoogleFonts.plusJakartaSans(color: const Color(0xFFE2E8F0), fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() { _isAlertWindowActive = false; });
            },
            child: Text("DISMISS ALARM", style: GoogleFonts.orbitron(color: const Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  double _getMedianValue(List<double> values) {
    if (values.isEmpty) return 0.0;
    List<double> sortedValues = List.from(values)..sort();
    int middleIndex = sortedValues.length ~/ 2;
    if (sortedValues.length % 2 == 1) {
      return sortedValues[middleIndex];
    } else {
      return (sortedValues[middleIndex - 1] + sortedValues[middleIndex]) / 2.0;
    }
  }

  DateTime? _parseTimestamp(String ts) {
    try {
      return DateTime.parse(ts.replaceAll(' ', 'T'));
    } catch (_) {
      return null;
    }
  }

  String _formatTimestampForUi(String ts) {
    if (ts.isEmpty) return "N/A";
    try {
      final parts = ts.split(' ');
      if (parts.length == 2) {
        return "${parts} @ ${parts}";
      }
      return ts;
    } catch (_) {
      return ts;
    }
  }

  String _calculateTimeAgo(String rawTimestamp) {
    if (rawTimestamp == "Unknown" || rawTimestamp.isEmpty) return "Waiting for hardware pulse...";
    final DateTime? parsedTime = _parseTimestamp(rawTimestamp);
    if (parsedTime == null) return _formatTimestampForUi(rawTimestamp);

    final Duration difference = DateTime.now().difference(parsedTime);

    if (difference.inSeconds < 5) {
      return "Just now";
    } else if (difference.inSeconds < 60) {
      return "${difference.inSeconds} seconds ago";
    } else if (difference.inMinutes < 60) {
      return "${difference.inMinutes} minute(s) ago";
    } else {
      return "Last update: ${_formatTimestampForUi(rawTimestamp)}";
    }
  }

  Future<void> _compileAndAnalyzeMedianTelemetry() async {
    if (_cachedHistoryData.isEmpty) {
      setState(() { 
        _geminiReport = "⚠️ Core telemetry pipeline dry."; 
        _currentWindowStartStr = "N/A";
        _currentWindowEndStr = "N/A";
        _currentParsedCount = 0;
      });
      return;
    }

    setState(() { _isAiLoading = true; });

    try {
      List<Map<String, dynamic>> validHistoryRecords = [];
      _cachedHistoryData.forEach((key, value) {
        if (value is Map) {
          final String tsStr = value['timestamp']?.toString() ?? "";
          final DateTime? parsed = _parseTimestamp(tsStr);
          if (parsed != null) {
            validHistoryRecords.add(Map<String, dynamic>.from(value));
          }
        }
      });

      if (validHistoryRecords.isEmpty) {
        setState(() {
          _geminiReport = "⚠️ Timestamp parse failure.";
          _currentWindowStartStr = "N/A";
          _currentWindowEndStr = "N/A";
          _currentParsedCount = 0;
          _isAiLoading = false;
        });
        return;
      }

      validHistoryRecords.sort((a, b) {
        final DateTime timeA = _parseTimestamp(a['timestamp']?.toString() ?? "")!;
        final DateTime timeB = _parseTimestamp(b['timestamp']?.toString() ?? "")!;
        return timeA.compareTo(timeB);
      });

      final DateTime now = DateTime.now();
      final DateTime realTimeWindowStart = now.subtract(const Duration(seconds: 120));
      
      List<Map<String, dynamic>> recentRecords = validHistoryRecords.where((record) {
        final DateTime recordTime = _parseTimestamp(record['timestamp']?.toString() ?? "")!;
        return recordTime.isAfter(realTimeWindowStart);
      }).toList();

      if (recentRecords.isEmpty) {
        final DateTime latestEntryTime = _parseTimestamp(validHistoryRecords.last['timestamp']?.toString() ?? "")!;
        final DateTime dynamicWindowStart = latestEntryTime.subtract(const Duration(seconds: 120));
        recentRecords = validHistoryRecords.where((record) {
          final DateTime recordTime = _parseTimestamp(record['timestamp']?.toString() ?? "")!;
          return recordTime.isAfter(dynamicWindowStart);
        }).toList();
      }

      if (recentRecords.isEmpty) { recentRecords = [validHistoryRecords.last]; }

      final String windowStartRaw = recentRecords.first['timestamp']?.toString() ?? "N/A";
      final String windowEndRaw = recentRecords.last['timestamp']?.toString() ?? "N/A";

      final co2Logs = recentRecords.map((e) => double.tryParse(e['scd_co2']?.toString() ?? '') ?? 0.0).where((v) => v != -999).toList();
      final scdTempLogs = recentRecords.map((e) => double.tryParse(e['scd_temp_c']?.toString() ?? '') ?? 0.0).where((v) => v != -999).toList();
      final scdHumLogs = recentRecords.map((e) => double.tryParse(e['scd_humidity']?.toString() ?? '') ?? 0.0).where((v) => v != -999).toList();
      final vocLogs = recentRecords.map((e) => double.tryParse(e['bme_voc']?.toString() ?? '') ?? 0.0).where((v) => v != -999).toList();
      final bmeTempLogs = recentRecords.map((e) => double.tryParse(e['bme_temp_c']?.toString() ?? '') ?? 0.0).where((v) => v != -999).toList();
      final bmeHumLogs = recentRecords.map((e) => double.tryParse(e['bme_humidity']?.toString() ?? '') ?? 0.0).where((v) => v != -999).toList();
      final pressureLogs = recentRecords.map((e) => double.tryParse(e['bme_pressure']?.toString() ?? '') ?? 0.0).where((v) => v != -999).toList();
      final pm1Logs = recentRecords.map((e) => double.tryParse(e['pm1_0']?.toString() ?? '') ?? 0.0).where((v) => v != -999).toList();
      final pm25Logs = recentRecords.map((e) => double.tryParse(e['pm2_5']?.toString() ?? '') ?? 0.0).where((v) => v != -999).toList();
      final pm10Logs = recentRecords.map((e) => double.tryParse(e['pm10']?.toString() ?? '') ?? 0.0).where((v) => v != -999).toList();

      double medianCo2 = _getMedianValue(co2Logs);
      double medianScdTemp = _getMedianValue(scdTempLogs);
      double medianScdHum = _getMedianValue(scdHumLogs);
      double medianVoc = _getMedianValue(vocLogs);
      double medianBmeTemp = _getMedianValue(bmeTempLogs);
      double medianBmeHum = _getMedianValue(bmeHumLogs);
      double medianPressure = _getMedianValue(pressureLogs);
      double medianPm1 = _getMedianValue(pm1Logs);
      double medianPm25 = _getMedianValue(pm25Logs);
      double medianPm10 = _getMedianValue(pm10Logs);

      // Extract directly using standard developer pipeline keys
      final apiKey = dotenv.env['GOOGLE_AI_API_KEY'];
      if (apiKey == null || apiKey.isEmpty) {
        throw Exception("Missing GOOGLE_AI_API_KEY inside project environment setups.");
      }

      // Initialize utilizing standard direct production model engine configuration
      final modelInstance = GenerativeModel(
        model: 'gemini-2.5-flash', 
        apiKey: apiKey,
      );
      
      final analyticsPrompt = """
      You are an expert environmental engineer. Analyze this 2-minute MEDIAN dataset:
      - CO2 level: ${medianCo2.toStringAsFixed(0)} PPM
      - SCD40 Temperature: ${medianScdTemp.toStringAsFixed(1)}°C
      - SCD40 Humidity: ${medianScdHum.toStringAsFixed(1)}% RH
      - BME680 VOC Gas Resistance: ${medianVoc.toStringAsFixed(0)} Ohms
      - BME680 Ambient Temp: ${medianBmeTemp.toStringAsFixed(1)}°C
      - BME680 Ambient Humid: ${medianBmeHum.toStringAsFixed(1)}% RH
      - Atmospheric Pressure: ${medianPressure.toStringAsFixed(2)} hPa
      - PM1.0: ${medianPm1.toStringAsFixed(0)} ug/m³
      - PM2.5: ${medianPm25.toStringAsFixed(0)} ug/m³
      - PM10: ${medianPm10.toStringAsFixed(0)} ug/m³
      
      Provide a concise 2-3 sentence technical evaluation regarding air safety and environment trends based on the collected records (${recentRecords.length} records parsed).
      """;

      final modelOutputResponse = await modelInstance.generateContent([Content.text(analyticsPrompt)]);
      
      setState(() {
        _geminiReport = modelOutputResponse.text ?? "Error: Empty data output matrix.";
        _currentWindowStartStr = windowStartRaw;
        _currentWindowEndStr = windowEndRaw;
        _currentParsedCount = recentRecords.length;
        _isAiLoading = false;
      });
    } catch (error) {
      setState(() {
        _geminiReport = "Engine Runtime Abort: $error";
        _currentWindowStartStr = "N/A";
        _currentWindowEndStr = "N/A";
        _currentParsedCount = 0;
        _isAiLoading = false;
      });
    }
  }

  Widget _buildHardwareCommandCenter(Map<dynamic, dynamic> deviceCommands) {
    bool isBmeActive = deviceCommands['bme_active'] as bool? ?? true;
    bool isScdActive = deviceCommands['scd_active'] as bool? ?? true;
    bool isPmsActive = deviceCommands['pms_active'] as bool? ?? true;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0B1329),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: Color(0xFF111C44),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
            ),
            child: Row(
              children: [
                const Icon(Icons.settings_input_component, size: 16, color: Color(0xFF10B981)),
                const SizedBox(width: 8),
                Text(
                  "HARDWARE COMMAND CENTER (SECTION D)", 
                  style: GoogleFonts.orbitron(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8, color: const Color(0xFF94A3B8))
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                _buildDeviceToggle("BME680 SENSOR", "VOC, Temp & Humidity node", isBmeActive, 'bme_active'),
                const Divider(color: Color(0xFF1E293B), height: 24),
                _buildDeviceToggle("SCD40 SENSOR", "CO₂ core optical node", isScdActive, 'scd_active'),
                const Divider(color: Color(0xFF1E293B), height: 24),
                _buildDeviceToggle("PMS5003 SENSOR", "Particulate Matter laser/fan", isPmsActive, 'pms_active'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceToggle(String title, String subtitle, bool currentValue, String firebaseKey) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: GoogleFonts.orbitron(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(subtitle, style: GoogleFonts.plusJakartaSans(fontSize: 10, color: const Color(0xFF64748B))),
            ],
          ),
        ),
        Switch(
          value: currentValue,
          activeColor: const Color(0xFF10B981),
          onChanged: (bool newValue) async {
            try {
              await _dbRef?.child('device_commands').update({firebaseKey: newValue});
            } catch (e) {
              debugPrint("Command dispatch failed: $e");
            }
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final double systemWidth = MediaQuery.of(context).size.width;
    final bool isDesktop = systemWidth > 900;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: const Icon(Icons.analytics_outlined, size: 16, color: Color(0xFF38BDF8)),
            ),
            const SizedBox(width: 12),
            Text(
              "OTI'S SMART AI AIR QUALITY DASHBOARD",
              style: GoogleFonts.orbitron(fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 1.2, color: Colors.white)
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF065F46).withOpacity(0.3),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF059669), width: 0.8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text("LIVE STREAM", style: GoogleFonts.orbitron(fontSize: 9, fontWeight: FontWeight.bold, color: const Color(0xFF34D399))),
              ],
            ),
          )
        ],
        backgroundColor: const Color(0xFF0B1329),
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: Color(0xFF1E293B), width: 1)),
      ),
      body: FutureBuilder(
        future: _firebaseInitialization,
        builder: (context, initSnapshot) {
          if (initSnapshot.hasError) {
            return Center(child: Text("MATRIX CRITICAL ERROR: ${initSnapshot.error}", style: const TextStyle(color: Colors.redAccent)));
          }
          if (initSnapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFF38BDF8)));
          }

          return StreamBuilder(
            stream: _dbRef?.onValue,
            builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
              if (snapshot.hasError) return Center(child: Text("Telemetry Disruption: ${snapshot.error}"));
              if (!snapshot.hasData || snapshot.data?.snapshot.value == null) {
                return const Center(child: CircularProgressIndicator(color: Color(0xFF22D3EE)));
              }

              final rootData = snapshot.data!.snapshot.value as Map<dynamic, dynamic>? ?? {};
              final liveData = rootData['live_data'] as Map<dynamic, dynamic>? ?? {};
              final deviceCommands = rootData['device_commands'] as Map<dynamic, dynamic>? ?? {}; 
              _cachedHistoryData = rootData['history_data'] as Map<dynamic, dynamic>? ?? {};

              final int scdCo2 = int.tryParse(liveData['scd_co2']?.toString() ?? '') ?? 0;
              final double bmeTemp = double.tryParse(liveData['bme_temp_c']?.toString() ?? '') ?? 0.0;
              final int bmeVoc = int.tryParse(liveData['bme_voc']?.toString() ?? '') ?? 0;
              final int pm25 = int.tryParse(liveData['pm2_5']?.toString() ?? '') ?? 0;
              final int pm1 = int.tryParse(liveData['pm1_0']?.toString() ?? '') ?? 0;
              final int pm10 = int.tryParse(liveData['pm10']?.toString() ?? '') ?? 0;
              final double bmeHum = double.tryParse(liveData['bme_humidity']?.toString() ?? '') ?? 0.0;
              final double bmePress = double.tryParse(liveData['bme_pressure']?.toString() ?? '') ?? 0.0;
              final String lastPulseTime = liveData['timestamp']?.toString() ?? "Unknown";

              int crossAxisCountSetting = isDesktop ? 4 : 2;
              double gridRatioSetting = isDesktop ? 1.4 : 1.2;

              return SingleChildScrollView(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GridView.count(
                      crossAxisCount: crossAxisCountSetting,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                      childAspectRatio: gridRatioSetting,
                      children: [
                        _buildRefactoredMetricCard("CARBON DIOXIDE", "$scdCo2", "PPM", Icons.blur_on, const Color(0xFFF97316), scdCo2 > 1000),
                        _buildRefactoredMetricCard("VOC INDEX", "$bmeVoc", "ppb", Icons.waves, const Color(0xFFA855F7), bmeVoc > 250),
                        _buildRefactoredMetricCard("CORE THERMAL", bmeTemp.toStringAsFixed(1), "°C", Icons.thermostat, const Color(0xFFEF4444), bmeTemp > 35 || bmeTemp < 15),
                        _buildRefactoredMetricCard("PARTICULATE 2.5", "$pm25", "µg/m³", Icons.blur_linear, const Color(0xFF10B981), pm25 > 35),
                        _buildRefactoredMetricCard("PARTICULATE 1.0", "$pm1", "µg/m³", Icons.grain, const Color(0xFF06B6D4), pm1 > 20),
                        _buildRefactoredMetricCard("PARTICULATE 10", "$pm10", "µg/m³", Icons.scatter_plot, const Color(0xFF14B8A6), pm10 > 50),
                        _buildRefactoredMetricCard("HUMIDITY (BME)", bmeHum.toStringAsFixed(1), "% RH", Icons.water_drop_outlined, const Color(0xFF3B82F6), bmeHum > 70 || bmeHum < 20),
                        _buildRefactoredMetricCard("ATM PRESSURE", bmePress.toStringAsFixed(1), "hPa", Icons.speed, const Color(0xFFEAB308), bmePress < 900),
                      ],
                    ),
                    const SizedBox(height: 20),

                    _buildTelemetryTimeCard(lastPulseTime),
                    const SizedBox(height: 20),

                    _buildHardwareCommandCenter(deviceCommands),
                    const SizedBox(height: 20),

                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0B1329),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF1E293B)),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 10))
                        ]
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              color: const Color(0xFF111C44),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.auto_awesome, size: 15, color: Color(0xFF38BDF8)),
                                      const SizedBox(width: 8),
                                      Text(
                                        "FIREBASE COGNITIVE ARTIFICIAL INTELLIGENCE LAYER", 
                                        style: GoogleFonts.orbitron(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8, color: const Color(0xFF94A3B8))
                                      ),
                                    ],
                                  ),
                                  Text("MODEL: GEMINI-2.5-FLASH", style: GoogleFonts.orbitron(fontSize: 8, color: Colors.white30))
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _isAiLoading 
                                    ? const Center(
                                        child: Padding(
                                          padding: EdgeInsets.all(24),
                                          child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
                                        ),
                                      )
                                    : Text(
                                        _geminiReport, 
                                        style: GoogleFonts.plusJakartaSans(fontSize: 14, color: const Color(0xFFE2E8F0), height: 1.6, fontWeight: FontWeight.w400)
                                      ),
                                  const SizedBox(height: 20),
                                  SizedBox(
                                    width: double.infinity,
                                    height: 44,
                                    child: OutlinedButton.icon(
                                      onPressed: _isAiLoading ? null : _compileAndAnalyzeMedianTelemetry,
                                      icon: _isAiLoading 
                                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54))
                                        : const Icon(Icons.bolt, size: 16),
                                      label: Text(
                                        "EXECUTE ENGINE SYNTHESIS (2-MIN MEDIANS)",
                                        style: GoogleFonts.orbitron(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFF38BDF8),
                                        side: const BorderSide(color: Color(0xFF0284C7)),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                        backgroundColor: const Color(0xFF0284C7).withOpacity(0.05),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    
                    Text(
                      "HISTORICAL CO₂ DRIFT MATRIX (PAST ENTRIES)", 
                      style: GoogleFonts.orbitron(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8, color: const Color(0xFF64748B))
                    ),
                    const SizedBox(height: 10),
                    
                    HistoricalTelemetryChart(historyData: _cachedHistoryData),
                    
                    const SizedBox(height: 24),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildTelemetryTimeCard(String livePulseTime) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0B1329),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_toggle_off_rounded, size: 14, color: Color(0xFF10B981)),
              const SizedBox(width: 8),
              Text(
                "LAST TELEMETRY UPDATE NODE",
                style: GoogleFonts.orbitron(fontSize: 10, color: const Color(0xFF64748B), fontWeight: FontWeight.bold, letterSpacing: 0.5),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8.0),
            child: Divider(color: Color(0xFF1E293B), height: 1),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "ELAPSED TIME SINCE COMMIT",
                    style: GoogleFonts.orbitron(fontSize: 8, color: const Color(0xFF475569), fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _calculateTimeAgo(livePulseTime),
                        style: GoogleFonts.plusJakartaSans(fontSize: 14, color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRefactoredMetricCard(String title, String value, String unit, IconData icon, Color markerColor, bool criticalWarningTrigger) {
    bool isFaultyNode = value.contains("-999") || value == "0" || value == "0.0";
    Color borderAccentColor = isFaultyNode 
        ? const Color(0xFF334155) 
        : (criticalWarningTrigger ? const Color(0xFFEF4444) : const Color(0xFF1E293B));
        
    Color surfaceFillColor = criticalWarningTrigger 
        ? const Color(0xFF7F1D1D).withOpacity(0.15) 
        : const Color(0xFF0B1329);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surfaceFillColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderAccentColor, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: GoogleFonts.orbitron(fontSize: 10, color: const Color(0xFF64748B), fontWeight: FontWeight.bold, letterSpacing: 0.5),
              ),
              Icon(
                criticalWarningTrigger ? Icons.warning_amber_rounded : icon, 
                color: isFaultyNode ? Colors.white10 : (criticalWarningTrigger ? const Color(0xFFF87171) : markerColor), 
                size: 14
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                isFaultyNode ? "OFFLINE" : value,
                style: GoogleFonts.orbitron(
                  fontSize: isFaultyNode ? 18 : 28, 
                  fontWeight: FontWeight.w800, 
                  color: isFaultyNode ? const Color(0xFF475569) : (criticalWarningTrigger ? const Color(0xFFF87171) : Colors.white)
                ),
              ),
              const SizedBox(width: 4),
              if (!isFaultyNode)
                Text(
                  unit,
                  style: GoogleFonts.plusJakartaSans(fontSize: 11, color: const Color(0xFF475569), fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ],
      ),
    );
  }
}