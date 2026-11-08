import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:curlymax_dashboard/youtube_workspace.dart';

void main() {
  testWidgets(
    'mobile YouTube configuration requires channel and section; defaults future publishing on',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: YoutubeSettingsForm(
              channel: {'id': 'channel', 'name': 'CURLYmax'},
              current: {},
              sections: [
                {'id': 'section', 'name': 'Uploads'},
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final switches = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList();
      expect(switches[0].value, isFalse);
      expect(switches[1].value, isTrue);
      await tester.enterText(
        find.byType(TextFormField).first,
        'invalid-channel',
      );
      await tester.tap(find.text('Save settings'));
      await tester.pump();
      expect(find.text('Enter a valid YouTube channel ID'), findsOneWidget);
      expect(find.text('Choose a section'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
