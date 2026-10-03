String runtimeValue(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Unknown';
  }
  return value;
}

String runtimeNetworkValue(bool? value) {
  if (value == null) {
    return 'Unknown';
  }
  return value ? 'Enabled' : 'Blocked';
}

String runtimeServiceTierValue(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Unknown';
  }
  return switch (value) {
    'fast' => 'Fast',
    _ => value,
  };
}
