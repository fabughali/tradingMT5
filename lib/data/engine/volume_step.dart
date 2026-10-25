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

/// The exact volume [EngineService._openPosition] sends right now for one
/// pair/category (2026-10-25, extracted so a resting, not-yet-triggered
/// order can be compared against it - per the user: "whenever the user
/// changes the volume setting before the trade is filled ... new volume
/// setting should take place not the old volume settings").
///
/// [desired] is the Dashboard card volume (null = never set, use the
/// broker minimum), scaled by [marginScale] when below 1; [attempt] is a
/// persisted step-down after a 10014/10019 rejection (never above the
/// desired size); [lastApplied] is the floor - the last size that really
/// filled - which wins over both. Every intermediate is snapped onto the
/// broker grid, same as the send path always did.
double plannedSendVolume({
  required double? desired,
  required double marginScale,
  required double? attempt,
  required double? lastApplied,
  required double volumeMin,
  required double volumeStep,
}) {
  final desiredRaw = desired ?? volumeMin;
  final desiredVolume = snapVolumeToStep(
    marginScale >= 1.0 ? desiredRaw : desiredRaw * marginScale,
    volumeMin: volumeMin,
    volumeStep: volumeStep,
  );
  final floorVolume = lastApplied ?? volumeMin;
  var tryVolume = attempt ?? desiredVolume;
  if (tryVolume > desiredVolume) tryVolume = desiredVolume;
  if (tryVolume < floorVolume) tryVolume = floorVolume;
  return snapVolumeToStep(tryVolume, volumeMin: volumeMin, volumeStep: volumeStep);
}

/// What the next order will send and, when that differs from the card
/// volume, why (2026-10-25, per the user: ADA's card said 400 but the order
/// went out at 200 with nothing on screen saying so). [marginScale] is
/// ignored for an [ignited] pair - it sends the full card volume.
({double volume, String? why}) explainPlannedSend({
  required double? desired,
  required double marginScale,
  required double? marginLevel,
  required bool ignited,
  required double? attempt,
  required double? lastApplied,
  required double volumeMin,
  required double volumeStep,
}) {
  final scale = ignited ? 1.0 : marginScale;
  final volume = plannedSendVolume(
    desired: desired,
    marginScale: scale,
    attempt: attempt,
    lastApplied: lastApplied,
    volumeMin: volumeMin,
    volumeStep: volumeStep,
  );
  final card = snapVolumeToStep(desired ?? volumeMin, volumeMin: volumeMin, volumeStep: volumeStep);
  if ((volume - card).abs() < 1e-9) return (volume: volume, why: null);
  String fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';
  final reasons = <String>[];
  final scaled = plannedSendVolume(
    desired: desired,
    marginScale: scale,
    attempt: null,
    lastApplied: null,
    volumeMin: volumeMin,
    volumeStep: volumeStep,
  );
  if (scale < 1.0) {
    reasons.add('${(scale * 100).round()}% at ${marginLevel?.toStringAsFixed(0) ?? '?'}% margin');
  }
  if (attempt != null && attempt < scaled - 1e-9) reasons.add('stepped down after a broker rejection');
  if (lastApplied != null && (volume - lastApplied).abs() < 1e-9 && lastApplied > scaled + 1e-9) {
    reasons.add('min = last fill ${fmt(lastApplied)}');
  }
  return (volume: volume, why: reasons.isEmpty ? null : reasons.join(', '));
}
