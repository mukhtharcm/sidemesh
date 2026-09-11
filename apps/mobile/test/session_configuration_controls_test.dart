import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/session_turn_config_store.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/widgets/app_menu.dart';
import 'package:sidemesh_mobile/src/widgets/session_configuration_controls.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await SessionTurnConfigStore.instance.ensureLoaded();
  });

  for (final dark in [false, true]) {
    testWidgets('provider settings preserve failed changes and apply exact values ($dark)', (tester) async {
      const host = HostProfile(id: 'config-host', label: 'Host', baseUrl: 'http://localhost', token: 'test');
      final session = SessionSummary.fromJson({'id': 'work:c2Vzc2lvbg', 'providerId': 'work'});
      final api = _ConfigApi();
      var closed = false;
      await SessionTurnConfigStore.instance.setConfig(host, session.id, const SessionTurnConfig(model: 'old-model'));
      await tester.pumpWidget(MaterialApp(theme: dark ? buildDarkTheme(ThemeVariant.codexAmber.dark) : buildLightTheme(ThemeVariant.codexAmber.light),
        home: Scaffold(body: SessionConfigurationControls(api: api, host: host, session: session,
          onClose: () { closed = true; }))));
      await tester.pumpAndSettle();
      expect(find.text('Enable detail'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.tap(find.byType(AppSelect<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Team / Large model').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();
      expect(closed, isFalse);
      expect(find.textContaining('Setting rejected'), findsOneWidget);
      expect(api.calls, [('detail', true)]);
      api.fail = false;
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(api.calls, [('detail', true), ('detail', true), ('model-choice', 'large')]);
      expect(api.sessionIds.toSet(), {session.id});
      expect(SessionTurnConfigStore.instance.configFor(host, session.id).model, isNull);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.macOS}));
  }

  test('runtime caches retain configuration groups and commands and reject malformed choices', () {
    final runtime = SessionRuntimeSummary.fromJson({
      'configurationOptions': [
        {'id': 'detail', 'label': 'Detail', 'value': false},
        {'id': 'model', 'label': 'Model', 'value': 'small', 'options': [
          {'value': 'small', 'label': 'Small', 'group': 'Team'}, {'value': 1},
        ]},
        {'id': 'bad', 'label': 'Bad', 'value': 4},
      ],
      'commands': [{'name': 'review', 'description': 'Review changes', 'inputHint': 'File name'}],
    });
    final restored = SessionRuntimeSummary.fromJson(runtime.copyWith(model: 'small').toJson());
    expect(restored.configurationOptions, hasLength(2));
    expect(restored.configurationOptions.last.options.single.group, 'Team');
    expect(restored.commands.single.inputHint, 'File name');
  });
}

class _ConfigApi extends ApiClient {
  bool fail = true;
  final calls = <(String, Object)>[];
  final sessionIds = <String>[];
  bool detail = false;
  String model = 'small';

  SessionRuntimeSummary get runtime => SessionRuntimeSummary(configurationOptions: [
    SessionConfigurationOption(id: 'detail', label: 'Enable detail', value: detail),
    SessionConfigurationOption(id: 'model-choice', label: 'Model', category: 'model', value: model,
      options: const [SessionConfigurationChoice(value: 'small', label: 'Small model'),
        SessionConfigurationChoice(value: 'large', label: 'Large model', group: 'Team')]),
  ]);

  @override
  Future<SessionRuntimeSummary> fetchSessionConfiguration(HostProfile host, String sessionId) async => runtime;

  @override
  Future<SessionRuntimeSummary> setSessionConfiguration(HostProfile host, String sessionId, String optionId, Object value) async {
    calls.add((optionId, value));
    sessionIds.add(sessionId);
    if (fail) throw StateError('Setting rejected');
    if (optionId == 'detail') detail = value as bool;
    if (optionId == 'model-choice') model = value as String;
    return runtime;
  }
}
