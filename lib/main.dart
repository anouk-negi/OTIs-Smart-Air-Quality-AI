import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
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

  // Dynamically streams recommendations calculated directly by the Raspberry Pi gateway
  String _geminiReport = "Awaiting structural data packets from Raspberry Pi gateway...";
  bool _isAiLoading = false;
  Map<dynamic, dynamic> _cachedHistoryData = {};
  
  // Notification Management Ecosystem
  bool _isAlertWindowActive = false;     // Prevents overlapping alert dialog spam
  bool _wasEnvironmentToxic = false;      // State tracking mechanism for Edge-Triggering
  DateTime? _lastAlertNotificationTime;  // Frequency tracking checkpoint for Cooldown Throttling
  
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

    // Set up out-of-band live stream telemetry inspector
    _setupTelemetrySpikeListener();

    // Out-of-band live stream listener for automated Pi-side AI predictions
    _setupAiInsightsListener();
  }

  // Real-time hook pulling fresh Gemini analysis blocks directly from your backend processing script
  void _setupAiInsightsListener() {
    _dbRef?.child('ai_insights').onValue.listen((event) {
      final aiData = event.snapshot.value as Map<dynamic, dynamic>?;
      if (aiData != null && mounted) {
        setState(() {
          _geminiReport = aiData['message']?.toString() ?? "No environmental report generated yet.";
          final String ts = aiData['timestamp']?.toString() ?? "";
          if (ts.isNotEmpty) {
            _currentWindowStartStr = ts;
          }
        });
      }
    });
  }

  Future<void> _setupCloudMessaging() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;

    NotificationSettings settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      debugPrint('Cloud Messaging Authorized.');

      if (!kIsWeb) {
        debugPrint('Subscribing to mobile broadcast topic...');
        await messaging.subscribeToTopic('air_quality_alerts');
      } else {
        debugPrint('Topic subscription skipped: Not supported on Flutter Web.');
      }
    }

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

      final bool isCurrentlyToxic = (scdCo2 > 1000 || pm25 > 35);
      final DateTime now = DateTime.now();
      
      final bool isCooldownOver = _lastAlertNotificationTime == null || 
          now.difference(_lastAlertNotificationTime!) > const Duration(minutes: 10);

      if (isCurrentlyToxic) {
        if (!_isAlertWindowActive && (!_wasEnvironmentToxic || isCooldownOver)) {
          _lastAlertNotificationTime = now;
          _wasEnvironmentToxic = true; 

          _showInAppSpikeDialog(
            "⚠️ TOXIC SPIKE DETECTED",
            "Immediate intervention required! Live sensor node feeds show structural metrics spiking past nominal ranges.\n\n• Carbon Dioxide: $scdCo2 PPM\n• Particulate Matter (PM2.5): $pm25 µg/m³",
          );
        }
      } else {
        _wasEnvironmentToxic = false;
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

  // Refactored to act as a manual dashboard sync verification trigger
  Future<void> _compileAndAnalyzeMedianTelemetry() async {
    setState(() { _isAiLoading = true; });
    await Future.delayed(const Duration(milliseconds: 400));
    setState(() { _isAiLoading = false; });
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF0F172A),
          content: Text(
            "Telemetry Stream Synchronized with Firebase Cognitive Layer Node.",
            style: GoogleFonts.plusJakartaSans(color: const Color(0xFF34D399), fontSize: 12),
          ),
        ),
      );
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
                                        "LOCALIZED AI ANALYTICS ENGINE", 
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
                                        : const Icon(Icons.sync_alt_rounded, size: 16),
                                      label: Text(
                                        "FORCE RE-SYNC DASHBOARD PIPELINE",
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