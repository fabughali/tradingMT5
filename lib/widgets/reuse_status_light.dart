import 'package:flutter/material.dart';

/// Small colored dot + label for at-a-glance connection/running state.
class ReuseStatusLight extends StatelessWidget {
  const ReuseStatusLight({super.key, required this.on, required this.label});

  final bool on;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = on ? Colors.green : Colors.grey;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }
}
