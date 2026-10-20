/// Snaps [volume] DOWN onto the broker's legal volume grid:
/// `volumeMin + k * volumeStep` for whole k >= 0 (2026-10-20, per the
/// user: "snap desiredVolume/tryVolume to the broker's volume_step grid
/// (floor to nearest multiple from volume_min) before the first send
/// attempt ... not only reactively after a 10014 rejection").
///
/// Why: [EngineService._openPosition] multiplies the desired volume by
/// [RiskGate.marginSizeScaleFor] (2026-10-15) and its step-down retry
/// subtracts one [volumeStep] in raw floating point - both can produce an
/// off-grid size (e.g. 0.3 * 0.66 = 0.198 with step 0.1, or
/// 0.30000000000000004 - 0.1) that MT5 rejects with retcode 10014
/// (INVALID_VOLUME) before the order ever reaches the market.
///
/// Always floors, never rounds up - a snapped size must never exceed what
/// the caller asked for (the margin-scaling and step-down rules only ever
/// shrink exposure). Anything below [volumeMin] snaps up to [volumeMin],
/// the smallest legal size. A tiny epsilon absorbs float noise so a value
/// that is already on the grid (0.30000000000000004) stays where it is
/// instead of dropping a whole step. The result is rounded to the step's
/// own decimal places so it's sent as a clean number.
double snapVolumeToStep(double volume, {required double volumeMin, required double volumeStep}) {
  if (volumeStep <= 0) return volume < volumeMin ? volumeMin : volume;
  if (volume <= volumeMin) return volumeMin;
  const epsilon = 1e-9;
  final steps = ((volume - volumeMin) / volumeStep + epsilon).floorToDouble();
  final snapped = volumeMin + steps * volumeStep;
  final decimals = _decimalPlaces(volumeStep) > _decimalPlaces(volumeMin)
      ? _decimalPlaces(volumeStep)
      : _decimalPlaces(volumeMin);
  return double.parse(snapped.toStringAsFixed(decimals));
}

/// Decimal places needed to represent [v] exactly enough for a volume grid
/// (capped at 8 - no broker volume step is finer than that).
int _decimalPlaces(double v) {
  for (var d = 0; d <= 8; d++) {
    final scaled = v * _pow10(d);
    if ((scaled - scaled.roundToDouble()).abs() < 1e-6) return d;
  }
  return 8;
}

double _pow10(int d) {
  var r = 1.0;
  for (var i = 0; i < d; i++) {
    r *= 10;
  }
  return r;
}
