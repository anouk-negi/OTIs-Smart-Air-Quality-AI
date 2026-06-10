// lib/chart_widget.dart
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:google_fonts/google_fonts.dart';

class HistoricalTelemetryChart extends StatefulWidget {
  final Map<dynamic, dynamic> historyData;

  const HistoricalTelemetryChart({super.key, required this.historyData});

  @override
  State<HistoricalTelemetryChart> createState() => _HistoricalTelemetryChartState();
}

class _HistoricalTelemetryChartState extends State<HistoricalTelemetryChart> {
  // Default selected parameter when the chart loads
  String _selectedParamKey = 'scd_co2';

  // Mapping the JSON keys to their display names and distinct cyberpunk colors
  final Map<String, Map<String, dynamic>> _chartParams = {
    'scd_co2': {'name': 'CO₂', 'color': const Color(0xFFF97316)},
    'bme_voc': {'name': 'VOC', 'color': const Color(0xFFA855F7)},
    'pm1_0': {'name': 'PM 1.0', 'color': const Color(0xFF06B6D4)},
    'pm2_5': {'name': 'PM 2.5', 'color': const Color(0xFF10B981)},
    'pm10': {'name': 'PM 10', 'color': const Color(0xFF14B8A6)},
    'bme_temp_c': {'name': 'TEMP', 'color': const Color(0xFFEF4444)},
    'bme_humidity': {'name': 'HUMIDITY', 'color': const Color(0xFF3B82F6)},
    'bme_pressure': {'name': 'PRESSURE', 'color': const Color(0xFFEAB308)},
  };

  @override
  Widget build(BuildContext context) {
    if (widget.historyData.isEmpty) {
      return Container(
        height: 240,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF0B1329),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF1E293B)),
        ),
        child: Text(
          "INITIALIZING TELEMETRY CHART NODE...",
          style: GoogleFonts.orbitron(fontSize: 10, color: Colors.white30),
        ),
      );
    }

    var sortedKeys = widget.historyData.keys.toList()..sort();
    List<FlSpot> metricSpots = [];

    // Map the currently selected parameter
    for (int i = 0; i < sortedKeys.length; i++) {
      final entry = widget.historyData[sortedKeys[i]] as Map<dynamic, dynamic>? ?? {};
      
      // Dynamically fetch the selected metric from your JSON using the state key
      double value = double.tryParse(entry[_selectedParamKey]?.toString() ?? '-999') ?? -999;

      if (value != -999) {
        metricSpots.add(FlSpot(i.toDouble(), value));
      }
    }

    // Isolate chart view to the last 40 logs to keep the line from getting crushed
    if (metricSpots.length > 40) {
      metricSpots = metricSpots.sublist(metricSpots.length - 40);
    }

    Color activeColor = _chartParams[_selectedParamKey]!['color'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ──> INTERACTIVE PARAMETER SELECTOR CHIPS <──
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: _chartParams.entries.map((entry) {
              bool isSelected = _selectedParamKey == entry.key;
              return GestureDetector(
                onTap: () {
                  setState(() {
                    _selectedParamKey = entry.key;
                  });
                },
                child: Container(
                  margin: const EdgeInsets.only(right: 8, bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? entry.value['color'].withOpacity(0.15) : const Color(0xFF0B1329),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected ? entry.value['color'] : const Color(0xFF1E293B),
                    ),
                  ),
                  child: Text(
                    entry.value['name'],
                    style: GoogleFonts.orbitron(
                      fontSize: 10,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? entry.value['color'] : const Color(0xFF64748B),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),

        // ──> DYNAMIC GRAPH CANVAS <──
        Container(
          height: 180,
          padding: const EdgeInsets.only(right: 20, left: 10, top: 18, bottom: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF0B1329),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF1E293B)),
          ),
          child: LineChart(
            LineChartData(
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (value) => const FlLine(color: Color(0xFF1E293B), strokeWidth: 0.6),
              ),
              titlesData: FlTitlesData(
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 22,
                    interval: (sortedKeys.length / 4).clamp(1, double.infinity),
                    getTitlesWidget: (value, meta) {
                      int idx = value.toInt();
                      if (idx >= 0 && idx < sortedKeys.length) {
                        final entry = widget.historyData[sortedKeys[idx]] as Map<dynamic, dynamic>? ?? {};
                        String fullTimestamp = entry['timestamp']?.toString() ?? '';
                        if (fullTimestamp.length >= 16) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: Text(
                              fullTimestamp.substring(11, 16),
                              style: GoogleFonts.orbitron(fontSize: 8, color: const Color(0xFF475569)),
                            ),
                          );
                        }
                      }
                      return const Text('');
                    },
                  ),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 32,
                    getTitlesWidget: (value, meta) {
                      // Abbreviate large numbers for the Y-axis (e.g., 50000 -> 50k)
                      String label = value >= 1000 ? '${(value / 1000).toStringAsFixed(1)}k' : value.toInt().toString();
                      return Text(
                        label,
                        style: GoogleFonts.orbitron(fontSize: 8, color: const Color(0xFF475569)),
                      );
                    },
                  ),
                ),
              ),
              borderData: FlBorderData(show: false),
              lineBarsData: [
                LineChartBarData(
                  spots: metricSpots,
                  isCurved: true,
                  color: activeColor, // Uses the color of the selected parameter
                  barWidth: 2,
                  isStrokeCapRound: true,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    color: activeColor.withOpacity(0.05),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}