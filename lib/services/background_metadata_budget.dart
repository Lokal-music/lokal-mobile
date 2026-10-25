/// Automatic metadata work must leave time for rendering and playback even
/// when a storage/codec probe is expensive. Explicit repairs/scans use their
/// own foreground scheduling instead.
Duration backgroundMetadataDelay(Duration work, {bool ultra = false}) {
  final rest = work.inMicroseconds * (ultra ? 9 : 4);
  final minimum = ultra ? 300000 : 200000;
  return Duration(microseconds: rest > minimum ? rest : minimum);
}
