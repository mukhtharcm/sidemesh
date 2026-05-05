import 'package:flutter/foundation.dart';

import 'models.dart';

int compareReleaseVersions(String left, String right) {
  final parsedLeft = _ParsedReleaseVersion.parse(left);
  final parsedRight = _ParsedReleaseVersion.parse(right);

  for (var i = 0; i < parsedLeft.core.length || i < parsedRight.core.length; i++) {
    final leftPart = i < parsedLeft.core.length ? parsedLeft.core[i] : 0;
    final rightPart = i < parsedRight.core.length ? parsedRight.core[i] : 0;
    if (leftPart != rightPart) {
      return leftPart.compareTo(rightPart);
    }
  }

  final leftPre = parsedLeft.preRelease;
  final rightPre = parsedRight.preRelease;
  if (leftPre == null && rightPre != null) return 1;
  if (leftPre != null && rightPre == null) return -1;
  if (leftPre != null && rightPre != null) {
    final preCompare = _compareIdentifierLists(leftPre, rightPre);
    if (preCompare != 0) return preCompare;
  }

  final leftBuild = parsedLeft.build;
  final rightBuild = parsedRight.build;
  if (leftBuild == null && rightBuild != null) return -1;
  if (leftBuild != null && rightBuild == null) return 1;
  if (leftBuild != null && rightBuild != null) {
    return _compareIdentifierLists(leftBuild, rightBuild);
  }

  return 0;
}

int _compareIdentifierLists(List<String> left, List<String> right) {
  for (var i = 0; i < left.length || i < right.length; i++) {
    if (i >= left.length) return -1;
    if (i >= right.length) return 1;
    final leftPart = left[i];
    final rightPart = right[i];
    final leftNumber = int.tryParse(leftPart);
    final rightNumber = int.tryParse(rightPart);
    if (leftNumber != null && rightNumber != null) {
      if (leftNumber != rightNumber) {
        return leftNumber.compareTo(rightNumber);
      }
      continue;
    }
    if (leftNumber != null) return -1;
    if (rightNumber != null) return 1;
    final compare = leftPart.compareTo(rightPart);
    if (compare != 0) return compare;
  }
  return 0;
}

enum MobileClientCompatibilityLevel { none, recommended, required }

@immutable
class MobileClientCompatibility {
  const MobileClientCompatibility({
    required this.level,
    required this.targetVersion,
    this.recommendedVersion,
    this.minimumVersion,
  });

  static const none = MobileClientCompatibility(
    level: MobileClientCompatibilityLevel.none,
    targetVersion: '',
  );

  final MobileClientCompatibilityLevel level;
  final String targetVersion;
  final String? recommendedVersion;
  final String? minimumVersion;

  bool get needsAttention => level != MobileClientCompatibilityLevel.none;
}

MobileClientCompatibility evaluateMobileClientCompatibility({
  required String installedVersion,
  String? recommendedVersion,
  String? minimumVersion,
}) {
  final normalizedInstalled = installedVersion.trim();
  final normalizedRecommended = recommendedVersion?.trim();
  final normalizedMinimum = minimumVersion?.trim();

  if (normalizedInstalled.isEmpty) {
    return MobileClientCompatibility.none;
  }

  if (normalizedMinimum != null &&
      normalizedMinimum.isNotEmpty &&
      compareReleaseVersions(normalizedInstalled, normalizedMinimum) < 0) {
    return MobileClientCompatibility(
      level: MobileClientCompatibilityLevel.required,
      targetVersion: normalizedMinimum,
      recommendedVersion: normalizedRecommended,
      minimumVersion: normalizedMinimum,
    );
  }

  if (normalizedRecommended != null &&
      normalizedRecommended.isNotEmpty &&
      compareReleaseVersions(normalizedInstalled, normalizedRecommended) < 0) {
    return MobileClientCompatibility(
      level: MobileClientCompatibilityLevel.recommended,
      targetVersion: normalizedRecommended,
      recommendedVersion: normalizedRecommended,
      minimumVersion: normalizedMinimum,
    );
  }

  return MobileClientCompatibility.none;
}

@immutable
class MobileClientCompatibilityNotice {
  const MobileClientCompatibilityNotice({
    required this.level,
    required this.installedVersion,
    required this.targetVersion,
    required this.affectedHosts,
  });

  final MobileClientCompatibilityLevel level;
  final String installedVersion;
  final String targetVersion;
  final List<HostProfile> affectedHosts;

  int get affectedHostCount => affectedHosts.length;

  HostProfile get primaryHost => affectedHosts.first;
}

MobileClientCompatibilityNotice? summarizeMobileClientCompatibility({
  required String installedVersion,
  required Iterable<HostProfile> hosts,
  required Map<String, NodeInfo> hostNodes,
  String? dismissedRecommendedVersion,
}) {
  final normalizedInstalled = installedVersion.trim();
  if (normalizedInstalled.isEmpty) return null;

  final requiredHosts = <HostProfile>[];
  final recommendedHosts = <HostProfile>[];
  String? requiredTargetVersion;
  String? recommendedTargetVersion;

  for (final host in hosts) {
    final node = hostNodes[host.id];
    if (node == null || !host.enabled) continue;
    final compatibility = evaluateMobileClientCompatibility(
      installedVersion: normalizedInstalled,
      recommendedVersion: node.recommendedMobileClientVersion,
      minimumVersion: node.minimumMobileClientVersion,
    );
    switch (compatibility.level) {
      case MobileClientCompatibilityLevel.required:
        requiredHosts.add(host);
        requiredTargetVersion = _maxVersion(
          requiredTargetVersion,
          compatibility.targetVersion,
        );
        break;
      case MobileClientCompatibilityLevel.recommended:
        recommendedHosts.add(host);
        recommendedTargetVersion = _maxVersion(
          recommendedTargetVersion,
          compatibility.targetVersion,
        );
        break;
      case MobileClientCompatibilityLevel.none:
        break;
    }
  }

  if (requiredHosts.isNotEmpty && requiredTargetVersion != null) {
    return MobileClientCompatibilityNotice(
      level: MobileClientCompatibilityLevel.required,
      installedVersion: normalizedInstalled,
      targetVersion: requiredTargetVersion,
      affectedHosts: requiredHosts,
    );
  }

  if (recommendedHosts.isEmpty || recommendedTargetVersion == null) {
    return null;
  }

  final dismissed = dismissedRecommendedVersion?.trim();
  if (dismissed != null &&
      dismissed.isNotEmpty &&
      compareReleaseVersions(dismissed, recommendedTargetVersion) >= 0) {
    return null;
  }

  return MobileClientCompatibilityNotice(
    level: MobileClientCompatibilityLevel.recommended,
    installedVersion: normalizedInstalled,
    targetVersion: recommendedTargetVersion,
    affectedHosts: recommendedHosts,
  );
}

String _maxVersion(String? current, String candidate) {
  if (current == null || current.isEmpty) return candidate;
  return compareReleaseVersions(candidate, current) > 0 ? candidate : current;
}

class _ParsedReleaseVersion {
  const _ParsedReleaseVersion({
    required this.core,
    required this.preRelease,
    required this.build,
  });

  final List<int> core;
  final List<String>? preRelease;
  final List<String>? build;

  factory _ParsedReleaseVersion.parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const _ParsedReleaseVersion(
        core: <int>[0],
        preRelease: null,
        build: null,
      );
    }

    final withoutPrefix = trimmed.startsWith(RegExp('[vV]'))
        ? trimmed.substring(1)
        : trimmed;
    final buildSeparator = withoutPrefix.indexOf('+');
    final releasePart = buildSeparator == -1
        ? withoutPrefix
        : withoutPrefix.substring(0, buildSeparator);
    final build = buildSeparator == -1
        ? null
        : withoutPrefix
              .substring(buildSeparator + 1)
              .split('.')
              .where((part) => part.isNotEmpty)
              .toList(growable: false);
    final preReleaseSeparator = releasePart.indexOf('-');
    final corePart = preReleaseSeparator == -1
        ? releasePart
        : releasePart.substring(0, preReleaseSeparator);
    final preRelease = preReleaseSeparator == -1
        ? null
        : releasePart
              .substring(preReleaseSeparator + 1)
              .split('.')
              .where((part) => part.isNotEmpty)
              .toList(growable: false);
    final core = corePart
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
    return _ParsedReleaseVersion(
      core: core.isEmpty ? const <int>[0] : core,
      preRelease: preRelease,
      build: build,
    );
  }
}
