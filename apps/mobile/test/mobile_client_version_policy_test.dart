import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/mobile_client_version_policy.dart';
import 'package:sidemesh_mobile/src/models.dart';

void main() {
  test('mobileClientVersionLabel avoids duplicate v prefixes', () {
    expect(mobileClientVersionLabel('1.2.0'), 'v1.2.0');
    expect(mobileClientVersionLabel('v1.2.0'), 'v1.2.0');
    expect(mobileClientVersionLabel('V1.2.0'), 'V1.2.0');
    expect(mobileClientVersionLabel(''), 'unknown version');
  });

  test('compareReleaseVersions handles dotted releases and prereleases', () {
    expect(compareReleaseVersions('1.2.0', '1.2.0'), 0);
    expect(compareReleaseVersions('1.2.1', '1.2.0'), greaterThan(0));
    expect(compareReleaseVersions('1.2.0', '1.2.1'), lessThan(0));
    expect(compareReleaseVersions('1.2', '1.2.0'), 0);
    expect(compareReleaseVersions('1.2.0-beta.1', '1.2.0'), lessThan(0));
    expect(compareReleaseVersions('1.2.0', '1.2.0-beta.1'), greaterThan(0));
    expect(compareReleaseVersions('v1.2.0', '1.2.0'), 0);
    expect(compareReleaseVersions('1.2.0+2', '1.2.0+3'), lessThan(0));
    expect(compareReleaseVersions('1.2.0+10', '1.2.0+3'), greaterThan(0));
    expect(compareReleaseVersions('1.2.0+2', '1.2.0'), greaterThan(0));
    expect(compareReleaseVersions('1.2.0', '1.2.0+2'), lessThan(0));
  });

  test('evaluateMobileClientCompatibility prefers minimum over recommended', () {
    final required = evaluateMobileClientCompatibility(
      installedVersion: '1.0.0',
      recommendedVersion: '1.2.0',
      minimumVersion: '1.1.0',
    );
    expect(required.level, MobileClientCompatibilityLevel.required);
    expect(required.targetVersion, '1.1.0');

    final recommended = evaluateMobileClientCompatibility(
      installedVersion: '1.1.0',
      recommendedVersion: '1.2.0',
      minimumVersion: '1.0.0',
    );
    expect(recommended.level, MobileClientCompatibilityLevel.recommended);
    expect(recommended.targetVersion, '1.2.0');

    final none = evaluateMobileClientCompatibility(
      installedVersion: '1.2.0',
      recommendedVersion: '1.2.0',
      minimumVersion: '1.0.0',
    );
    expect(none.level, MobileClientCompatibilityLevel.none);

    final buildRecommended = evaluateMobileClientCompatibility(
      installedVersion: '1.2.0+2',
      recommendedVersion: '1.2.0+3',
      minimumVersion: null,
    );
    expect(buildRecommended.level, MobileClientCompatibilityLevel.recommended);
    expect(buildRecommended.targetVersion, '1.2.0+3');
  });

  test('summarizeMobileClientCompatibility aggregates across hosts', () {
    final hosts = [
      const HostProfile(
        id: 'alpha',
        label: 'Alpha',
        baseUrl: 'https://alpha.example',
        token: 'a',
      ),
      const HostProfile(
        id: 'beta',
        label: 'Beta',
        baseUrl: 'https://beta.example',
        token: 'b',
      ),
    ];
    final nodes = {
      'alpha': _node(
        recommendedMobileClientVersion: '1.3.0',
        minimumMobileClientVersion: '1.1.0',
      ),
      'beta': _node(
        recommendedMobileClientVersion: '1.2.0',
        minimumMobileClientVersion: '1.0.0',
      ),
    };

    final recommended = summarizeMobileClientCompatibility(
      installedVersion: '1.1.0',
      hosts: hosts,
      hostNodes: nodes,
    );
    expect(recommended, isNotNull);
    expect(recommended!.level, MobileClientCompatibilityLevel.recommended);
    expect(recommended.targetVersion, '1.3.0');
    expect(recommended.affectedHostCount, 2);

    final required = summarizeMobileClientCompatibility(
      installedVersion: '1.0.0',
      hosts: hosts,
      hostNodes: nodes,
    );
    expect(required, isNotNull);
    expect(required!.level, MobileClientCompatibilityLevel.required);
    expect(required.targetVersion, '1.1.0');
    expect(required.affectedHostCount, 1);
    expect(required.primaryHost.id, 'alpha');
  });

  test('recommended notices stay dismissed until a newer target appears', () {
    final host = const HostProfile(
      id: 'alpha',
      label: 'Alpha',
      baseUrl: 'https://alpha.example',
      token: 'a',
    );
    final nodes = {
      'alpha': _node(recommendedMobileClientVersion: '1.2.0'),
    };

    final hidden = summarizeMobileClientCompatibility(
      installedVersion: '1.1.0',
      hosts: [host],
      hostNodes: nodes,
      dismissedRecommendedVersion: '1.2.0',
    );
    expect(hidden, isNull);

    final visible = summarizeMobileClientCompatibility(
      installedVersion: '1.1.0',
      hosts: [host],
      hostNodes: {
        'alpha': _node(recommendedMobileClientVersion: '1.3.0'),
      },
      dismissedRecommendedVersion: '1.2.0',
    );
    expect(visible, isNotNull);
    expect(visible!.targetVersion, '1.3.0');
  });
}

NodeInfo _node({
  String? recommendedMobileClientVersion,
  String? minimumMobileClientVersion,
}) {
  return NodeInfo.fromJson({
    'label': 'host',
    'hostname': 'host.local',
    'platform': 'darwin',
    'codexVersion': 'codex-cli 0.125.0',
    'recommendedMobileClientVersion': recommendedMobileClientVersion,
    'minimumMobileClientVersion': minimumMobileClientVersion,
  });
}
