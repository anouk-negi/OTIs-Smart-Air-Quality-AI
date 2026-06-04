import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = true;
  
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint("Failed to load .env file: $e");
  }

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
        scaffoldBackgroundColor: const Color(0xFF020617),
        textTheme: GoogleFonts.spaceGroteskTextTheme(ThemeData.dark().textTheme),
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
  // ========================================================
  // YOUR GEMINI API KEY RETAINED
  // ========================================================
  String get _geminiApiKey => dotenv.env['GEMINI_API_KEY'] ?? '';
  late Future<void> _firebaseInitialization;
  DatabaseReference? _dbRef;

  String _geminiReport = "Press the 'Refresh Prompt' button below to compile an AI report based on the past 2 minutes of sensor data.";
  bool _isAiLoading = false;
  Map<dynamic, dynamic> _cachedHistoryData = {};

  @override
  void initState() {
    super.initState();
    _firebaseInitialization = _initFirebase();
  }

  Future<void> _initFirebase() async {
    if (kIsWeb) {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey:  dotenv.env['FIREBASE_API_KEY'] ?? 'MISSING_FIREBASE_KEY',
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

    // Attempt anonymous auth sign-in
    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (e) {
      debugPrint("Auth warning: $e. Ensure Anonymous Auth is enabled in the Firebase Console.");
    }
    
    _dbRef = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: "https://oti-s-smart-ai-air-quality-default-rtdb.europe-west1.firebasedatabase.app"
    ).ref();
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

  Future<void> _compileAndAnalyzeMedianTelemetry() async {
    if (_geminiApiKey.isEmpty) {
      setState(() {
        _geminiReport = "⚠️ Configuration Missing: Please update your real Gemini API key.";
      });
      return;
    }

    if (_cachedHistoryData.isEmpty) {
      setState(() {
        _geminiReport = "⚠️ No Historical Data available yet.";
      });
      return;
    }

    setState(() {
      _isAiLoading = true;
    });

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
          _geminiReport = "⚠️ Data Format Error parsing timestamps.";
          _isAiLoading = false;
        });
        return;
      }

      // Sort records sequentially by time
      validHistoryRecords.sort((a, b) {
        final DateTime timeA = _parseTimestamp(a['timestamp']?.toString() ?? "")!;
        final DateTime timeB = _parseTimestamp(b['timestamp']?.toString() ?? "")!;
        return timeA.compareTo(timeB);
      });

      // Strategy 1: Look for records within the past 2 minutes from NOW
      final DateTime now = DateTime.now();
      final DateTime realTimeWindowStart = now.subtract(const Duration(seconds: 120));
      
      List<Map<String, dynamic>> recentRecords = validHistoryRecords.where((record) {
        final DateTime recordTime = _parseTimestamp(record['timestamp']?.toString() ?? "")!;
        return recordTime.isAfter(realTimeWindowStart);
      }).toList();

      // Strategy 2 (Fallback - Less data is available/Delayed): 
      // If no records in the absolute past 2 minutes from real clock, look back 2 minutes from the latest entry
      if (recentRecords.isEmpty) {
        final DateTime latestEntryTime = _parseTimestamp(validHistoryRecords.last['timestamp']?.toString() ?? "")!;
        final DateTime dynamicWindowStart = latestEntryTime.subtract(const Duration(seconds: 120));
        
        recentRecords = validHistoryRecords.where((record) {
          final DateTime recordTime = _parseTimestamp(record['timestamp']?.toString() ?? "")!;
          return recordTime.isAfter(dynamicWindowStart);
        }).toList();
      }

      // Strategy 3 (Absolute Safeguard): If still empty, collect whatever is left in history
      if (recentRecords.isEmpty) {
        recentRecords = [validHistoryRecords.last];
      }

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

      final modelInstance = GenerativeModel(model: 'gemini-1.5-flash', apiKey: _geminiApiKey);
      
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
        _geminiReport = modelOutputResponse.text ?? "Error: Empty response received from model backend.";
        _isAiLoading = false;
      });
    } catch (error) {
      setState(() {
        _geminiReport = "Generative AI Node Error: $error";
        _isAiLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          "OTI's SMART AIR QUALITY AI",
          style: GoogleFonts.orbitron(fontWeight: FontWeight.w800, fontSize: 14, letterSpacing: 1.5, color: const Color(0xFF38BDF8))
        ),
        backgroundColor: const Color(0xFF0F172A).withOpacity(0.5),
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: Color(0xFF1E293B), width: 1)),
      ),
      body: FutureBuilder(
        future: _firebaseInitialization,
        builder: (context, initSnapshot) {
          if (initSnapshot.hasError) {
            return Center(child: Text("Firebase Init Failed: ${initSnapshot.error}"));
          }
          if (initSnapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFF38BDF8)));
          }

          return StreamBuilder(
            stream: _dbRef?.onValue,
            builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text("Database Error: ${snapshot.error}"));
              }
              if (!snapshot.hasData || snapshot.data?.snapshot.value == null) {
                return const Center(child: CircularProgressIndicator(color: Color(0xFF22D3EE)));
              }

              final rootData = snapshot.data!.snapshot.value as Map<dynamic, dynamic>? ?? {};
              final liveData = rootData['live_data'] as Map<dynamic, dynamic>? ?? {};
              _cachedHistoryData = rootData['history_data'] as Map<dynamic, dynamic>? ?? {};

              final int scdCo2 = int.tryParse(liveData['scd_co2']?.toString() ?? '') ?? 0;
              final double bmeTemp = double.tryParse(liveData['bme_temp_c']?.toString() ?? '') ?? 0.0;
              final int bmeVoc = int.tryParse(liveData['bme_voc']?.toString() ?? '') ?? 0;
              final int pm25 = int.tryParse(liveData['pm2_5']?.toString() ?? '') ?? 0;

              return SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // --- DEDICATED AI COGNITIVE INTEL LAYER ---
                    Text(
                      "COGNITIVE INTERACTION LAYER", 
                      style: GoogleFonts.orbitron(fontSize: 11, fontWeight: FontWeight.bold, color: const Color(0xFF38BDF8))
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF090D16),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF1E293B)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.auto_awesome, size: 16, color: Color(0xFF38BDF8)),
                              const SizedBox(width: 8),
                              Text("GEMINI_GEN_AI_INSIGHTS", style: GoogleFonts.orbitron(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white70)),
                            ],
                          ),
                          const Divider(color: Color(0xFF1E293B), height: 20),
                          _isAiLoading 
                            ? const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(color: Color(0xFF38BDF8))))
                            : Text(_geminiReport, style: const TextStyle(fontSize: 13, color: Color(0xFFE2E8F0), height: 1.5)),
                          const SizedBox(height: 14),
                          
                          ElevatedButton.icon(
                            onPressed: _isAiLoading ? null : _compileAndAnalyzeMedianTelemetry,
                            icon: _isAiLoading 
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))
                              : const Icon(Icons.refresh, size: 16),
                            label: Text(
                              "Refresh Prompt (Past 2 Mins Data)",
                              style: GoogleFonts.orbitron(fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0284C7),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: Colors.white10,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // GRID METRICS
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: 1.25,
                      children: [
                        _buildMetricCard("CO₂ GAS LEVEL", "$scdCo2", "PPM", Icons.blur_on, const Color(0xFFF97316)),
                        _buildMetricCard("VOC INDEX", "$bmeVoc", "ppb", Icons.waves, const Color(0xFFA855F7)),
                        _buildMetricCard("THERMAL NODE", "${bmeTemp.toStringAsFixed(2)}", "°C", Icons.thermostat, const Color(0xFFEF4444)),
                        _buildMetricCard("PM2.5 (PMS5003)", "$pm25", "ug/m³", Icons.blur_linear, const Color(0xFF10B981)),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildMetricCard(String title, String value, String unit, IconData icon, Color accentColor) {
    bool isInvalid = value.contains("-999") || value == "0" || value == "0.0" || value == "0.00";
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B)),
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
                style: GoogleFonts.spaceGrotesk(fontSize: 11, color: const Color(0xFF94A3B8), fontWeight: FontWeight.w500),
              ),
              Icon(icon, color: isInvalid ? Colors.white24 : accentColor, size: 16),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                isInvalid ? "0" : value,
                style: GoogleFonts.spaceGrotesk(fontSize: 32, fontWeight: FontWeight.bold, color: isInvalid ? Colors.white24 : Colors.white),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: GoogleFonts.spaceGrotesk(fontSize: 12, color: const Color(0xFF64748B)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}