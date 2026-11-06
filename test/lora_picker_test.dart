// Adding a LoRA in the remix panel: only those made for the model's kind are
// offered, and added ones are marked and can be taken out. Kept apart from
// server_loras_test.dart, whose fake servers a widget binding would block.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/lora_edits.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/server_loras.dart';
import 'package:generativeview/src/ui/lora_picker.dart';
import 'package:generativeview/src/ui/remix_dialog.dart' show LoraSection;

void main() {
  group('picker', () {
    const loras = [
      ServerModel('SDXL/detail_xl.safetensors', 'sdxl'),
      ServerModel('styles/painted.safetensors', 'sdxl'),
      ServerModel('flux/realism.safetensors', 'flux'),
      ServerModel('mystery.safetensors'),
    ];

    Future<void> open(WidgetTester tester, {String? family, Set<String> have = const {}}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => pickLora(context, loras: Future.value(loras), family: family, model: 'juggernautXL_v9.safetensors', have: have),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('lists only those made for the model\'s kind', (tester) async {
      await open(tester, family: 'sdxl', have: {'painted'});
      expect(find.text('detail_xl'), findsOneWidget);
      expect(find.text('painted'), findsOneWidget);
      expect(find.text('realism'), findsNothing);
      expect(find.text('mystery'), findsNothing);
      expect(find.textContaining('2 made for SDXL, like juggernautXL_v9'), findsOneWidget);
      expect(find.textContaining('1 for other kinds hidden'), findsOneWidget);
      // The one already in the remix cannot be added twice.
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('lora-picker-painted'))).enabled, isFalse);
      // Those that cannot be checked are behind a switch.
      await tester.tap(find.byKey(const ValueKey('lora-picker-unknown')));
      await tester.pumpAndSettle();
      expect(find.text('mystery'), findsOneWidget);
      expect(find.text('realism'), findsNothing);
    });

    testWidgets('picking one closes the picker with it', (tester) async {
      ServerModel? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await pickLora(context, loras: Future.value(loras), family: 'sdxl', model: 'x', have: const {}),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('detail_xl'));
      await tester.pumpAndSettle();
      expect(picked?.name, 'SDXL/detail_xl.safetensors');
      expect(find.byType(LoraPicker), findsNothing);
    });

    testWidgets('a model of unknown kind lists every LoRA, and says so', (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('lora-picker-note')), findsOneWidget);
      expect(find.textContaining('Could not tell what kind of model'), findsOneWidget);
      for (final name in ['detail_xl', 'painted', 'realism', 'mystery']) {
        expect(find.text(name), findsOneWidget);
      }
    });
  });

  testWidgets('an added LoRA is marked, can be taken out, and the section offers Add', (tester) async {
    final loras = [
      LoraChoice(const LoraRef('fur_detail.safetensors', 0.8, null, '')),
      LoraChoice(const LoraRef('SDXL/detail_xl.safetensors', 1.0, null, '')),
    ];
    final addedKey = loras[1].key;
    var adds = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Center(
            child: SizedBox(
              width: 424,
              child: LoraSection(
                loras: loras,
                added: {for (final l in loras) if (l.key == addedKey) l.key},
                notes: {addedKey: 'Made for FLUX.1, not SDXL; the server will skip it'},
                onAddLora: () => adds++,
                onRemove: (i) => setState(() => loras.removeAt(i)),
              ),
            ),
          ),
        ),
      ),
    ));
    expect(tester.widget<Text>(find.byKey(const ValueKey('remix-loras-summary'))).data, '2 · 1 added');
    await tester.tap(find.byKey(const ValueKey('remix-loras')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remix-lora-added-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('remix-lora-added-0')), findsNothing);
    expect(find.byKey(const ValueKey('remix-lora-note-1')), findsOneWidget);
    // Only an added one can be taken out; the picture's own are switched off.
    expect(find.byKey(const ValueKey('remix-lora-remove-0')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('remix-lora-add')));
    expect(adds, 1);
    await tester.tap(find.byKey(const ValueKey('remix-lora-remove-1')));
    await tester.pumpAndSettle();
    expect(loras, hasLength(1));
    expect(find.text('detail_xl'), findsNothing);
  });
}
