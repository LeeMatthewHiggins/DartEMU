import 'dart:math' as math;

import 'package:dart_emu/dart_emu.dart';
import 'package:flutter/material.dart';

class _Layout {
  static const padding = 16.0;
  static const spacing = 8.0;
  static const borderRadius = 12.0;
}

/// Displays a summary of a parsed [MachineConfig].
class ConfigSummaryCard extends StatelessWidget {
  /// Creates a card showing key fields from [config].
  const ConfigSummaryCard({required this.config, super.key});

  /// The parsed machine configuration to display.
  final MachineConfig config;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Card(
      color: Colors.grey.shade900,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_Layout.borderRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(_Layout.padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              config.machineType.toUpperCase(),
              style: textTheme.titleMedium?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: _Layout.spacing),
            _DetailRow(label: 'Memory', value: '${config.memorySizeMb} MB'),
            _DetailRow(label: 'Drives', value: _driveCount.toString()),
            _DetailRow(label: 'Network', value: _networkSummary),
          ],
        ),
      ),
    );
  }

  int get _driveCount =>
      math.max(config.blockDevices.length, config.driveConfigs.length);

  String get _networkSummary {
    final total = math.max(
      config.ethDevices.length,
      config.ethernetConfigs.length,
    );
    if (total == 0) return 'None';
    return '$total interface${total > 1 ? 's' : ''}';
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
            ),
          ),
          Text(
            value,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
