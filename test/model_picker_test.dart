// Models told apart by kind: every model of a server grouped under its
// kind (Krea 2, SDXL…), kinds set by hand for files that do not say, and
// the picker that lists them so. No server here: see new_picture_test.dart
// for the panel, and server_loras_test.dart for what the servers say.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/app_state.dart';
import 'package:generativeview/src/core/server_loras.dart';
import 'package:generativeview/src/ui/lora_picker.dart';
import 'package:generativeview/src/ui/model_picker.dart';

const models = [
  ServerModel('SDXL/juggernautXL_v9.safetensors', 'sdxl'),
  ServerModel('Krea-2-Turbo', 'krea-2'),
  ServerModel('sd15/dreamshaper_8.safetensors', 'sd-1'),
  ServerModel('Krea-2-Raw', 'krea-2'),
  ServerModel('SDXL/animagine.safetensors', 'sdxl'),
  ServerModel('mystery_mix_v3.safetensors'),
  ServerModel('flux1-dev.safetensors', 'flux'),
];

void main() {
  group('kinds', () {
    test('models are grouped by kind, known kinds first, each by name', () {
      final groups = groupByFamily(models);
      expect([for (final g in groups) g.family], ['sd-1', 'sdxl', 'flux', 'krea-2', null]);
      expect([for (final m in groups[1].models) m.key], ['animagine', 'juggernautxl_v9']);
      expect([for (final m in groups[3].models) m.name], ['Krea-2-Raw', 'Krea-2-Turbo']);
      expect(groups.last.models.single.key, 'mystery_mix_v3');
    });

    test('a kind a server names that the app has no name for is still a group', () {
      final groups = groupByFamily(const [ServerModel('a', 'sdxl'), ServerModel('b', 'wonder-9'), ServerModel('c')]);
      expect([for (final g in groups) g.family], ['sdxl', 'wonder-9', null]);
      expect(familyLabel('wonder-9'), 'wonder-9');
    });

    test('a kind set by hand stands in for what could not be told', () {
      final set = withModelTypes(models, const {'mystery_mix_v3': 'sdxl'});
      expect(set.firstWhere((m) => m.key == 'mystery_mix_v3').family, 'sdxl');
      expect(groupByFamily(set).any((g) => g.family == null), isFalse);
      // The LoRAs offered for an SDXL model then include one set so.
      final loras = withModelTypes(const [ServerModel('a.safetensors', 'sdxl'), ServerModel('b.safetensors')], const {'b': 'sdxl'});
      expect(sortLoras(loras, 'sdxl').fitting.length, 2);
    });

    test('a server that only says it does not know says nothing', () {
      expect(cleanFamily('any'), isNull);
      expect(cleanFamily('unknown'), isNull);
      expect(cleanFamily(''), isNull);
      expect(cleanFamily('sdxl'), 'sdxl');
    });

    test('more kinds are read from names', () {
      expect(familyFromName('hunyuan_dit_1.2.safetensors'), 'hunyuan');
      expect(familyFromName('PixArt-Sigma-XL-2-1024.safetensors'), 'pixart');
      expect(familyFromName('kolors/kolors.safetensors'), 'kolors');
      expect(familyFromName('sd15/dreamshaper_8.safetensors'), 'sd-1');
    });

    test('a new picture is named for its prompt', () {
      expect(AppState.newPictureStem('A red fox, in the (snow:1.2), golden hour <lora:detail:0.8>'), 'a-red-fox-in-the');
      expect(AppState.newPictureStem('  '), 'picture');
      expect(AppState.newPictureStem('{red|blue} fox __lighting__'), 'red-blue-fox-lighting');
    });
  });

  group('picker', () {
    Future<void> open(
      WidgetTester tester, {
      ValueChanged<ModelPick?>? onPicked,
      String? current,
      String? own,
      void Function(String, String?)? onSetType,
      Map<String, String> types = const {},
    }) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final picked = await pickModel(context, models: models, current: current, own: own, types: types, onSetType: onSetType);
                onPicked?.call(picked);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('lists every model under its kind, with how many of each', (tester) async {
      await open(tester);
      for (final kind in ['sd-1', 'sdxl', 'flux', 'krea-2', 'unknown']) {
        expect(find.byKey(ValueKey('model-group-$kind')), findsOneWidget, reason: kind);
        expect(find.byKey(ValueKey('model-kind-$kind')), findsOneWidget, reason: kind);
      }
      expect(find.text('KREA 2'), findsOneWidget);
      expect(find.text('TYPE NOT KNOWN'), findsOneWidget);
      expect(find.textContaining('7 models of 4 kinds'), findsOneWidget);
      expect(find.textContaining('1 whose kind'), findsOneWidget);
      for (final name in ['juggernautXL_v9', 'animagine', 'Krea-2-Turbo', 'Krea-2-Raw', 'dreamshaper_8', 'mystery_mix_v3', 'flux1-dev']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
    });

    testWidgets('a kind\'s chip shows that kind alone', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('model-kind-krea-2')));
      await tester.pumpAndSettle();
      expect(find.text('Krea-2-Turbo'), findsOneWidget);
      expect(find.text('Krea-2-Raw'), findsOneWidget);
      expect(find.text('juggernautXL_v9'), findsNothing);
      expect(find.text('mystery_mix_v3'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('model-kind-all')));
      await tester.pumpAndSettle();
      expect(find.text('juggernautXL_v9'), findsOneWidget);
    });

    testWidgets('searching narrows every group', (tester) async {
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('model-picker-search')), 'krea turbo');
      await tester.pumpAndSettle();
      expect(find.text('Krea-2-Turbo'), findsOneWidget);
      expect(find.text('Krea-2-Raw'), findsNothing);
      expect(find.byKey(const ValueKey('model-group-sdxl')), findsNothing);
    });

    testWidgets('picking one closes the picker with it', (tester) async {
      ModelPick? picked;
      await open(tester, onPicked: (p) => picked = p);
      await tester.tap(find.text('Krea-2-Turbo'));
      await tester.pumpAndSettle();
      expect(picked?.model?.name, 'Krea-2-Turbo');
      expect(picked?.model?.family, 'krea-2');
      expect(find.byType(ModelPicker), findsNothing);
    });

    testWidgets('the picture\'s own model is a row of its own', (tester) async {
      ModelPick? picked = const ModelPick(ServerModel('x'));
      await open(tester, onPicked: (p) => picked = p, own: 'krea2_turbo_fp8', current: 'Krea-2-Raw');
      expect(find.text('The picture\'s: krea2_turbo_fp8'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('model-picker-own')));
      await tester.pumpAndSettle();
      expect(picked, isNotNull);
      expect(picked!.model, isNull);
    });

    testWidgets('a model whose kind is not known can be given one, and moves to its group', (tester) async {
      final set = <String, String?>{};
      await open(tester, onSetType: (key, family) => set[key] = family);
      // Only the one that does not say can be set.
      expect(find.byType(SetTypeButton), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('model-type-mystery_mix_v3')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SDXL').last);
      await tester.pumpAndSettle();
      expect(set, {'mystery_mix_v3': 'sdxl'});
      expect(find.byKey(const ValueKey('model-group-unknown')), findsNothing);
      expect(find.textContaining('type set by you'), findsOneWidget);
      expect(find.textContaining('7 models of 4 kinds'), findsOneWidget);
      expect(find.textContaining('whose kind'), findsNothing);
      // And taken back.
      await tester.tap(find.byKey(const ValueKey('model-type-mystery_mix_v3')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not set'));
      await tester.pumpAndSettle();
      expect(set, {'mystery_mix_v3': null});
      expect(find.byKey(const ValueKey('model-group-unknown')), findsOneWidget);
    });
  });

  group('LoRAs', () {
    const loras = [
      ServerModel('SDXL/detail_xl.safetensors', 'sdxl'),
      ServerModel('flux/realism.safetensors', 'flux'),
      ServerModel('mystery.safetensors'),
    ];

    testWidgets('one whose kind is set by hand is offered with those that fit', (tester) async {
      final set = <String, String?>{};
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => pickLora(
                context,
                loras: Future.value(loras),
                family: 'sdxl',
                model: 'juggernautXL_v9.safetensors',
                have: const {},
                onSetType: (key, family) => set[key] = family,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('mystery'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('lora-picker-unknown')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('lora-type-mystery')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SDXL').last);
      await tester.pumpAndSettle();
      expect(set, {'mystery': 'sdxl'});
      expect(find.text('mystery'), findsOneWidget);
      expect(find.textContaining('2 made for SDXL'), findsOneWidget);
      // Nothing is left that cannot be checked.
      expect(find.byKey(const ValueKey('lora-picker-unknown')), findsNothing);
    });
  });
}
