// Comparing pictures: which settings differ, and how one prompt differs
// from another word by word.
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/compare.dart';
import 'package:generativeview/src/core/models.dart';

GenInfo picture({
  String prompt = 'a red fox, snow',
  String seed = '7',
  String cfg = '7',
  String sampler = 'Euler',
  List<Map<String, Object?>> loras = const [],
  String? extra,
}) =>
    GenInfo.fromJson({
      'source': 'comfyui',
      'prompt': prompt,
      'negative': 'blurry',
      'seed': seed,
      'model': 'flux1-dev.safetensors',
      'loras': loras,
      'params': [
        ['Steps', '20'],
        ['CFG scale', cfg],
        ['Sampler', sampler],
        ['Seed', seed],
        if (extra != null) ['Denoise', extra],
      ],
      'width': 1024,
      'height': 1024,
    });

void main() {
  test('rows say what each picture has, and which differ', () {
    final rows = compareRows([
      picture(),
      picture(seed: '8', cfg: '5.5', sampler: 'euler', extra: '0.6', loras: [
        {'name': 'loras/style/inkwash.safetensors', 'weight': 0.75},
      ]),
    ]);
    CompareRow row(String label) => rows.singleWhere((r) => r.label == label);

    expect(rows.first.label, 'Prompt');
    expect(row('Prompt').differs, isFalse);
    expect(row('Model').differs, isFalse);
    expect(row('Seed').values, ['7', '8']);
    expect(row('Seed').differs, isTrue);
    expect(row('CFG scale').differs, isTrue);
    expect(row('Steps').differs, isFalse);
    expect(row('Sampler').differs, isFalse, reason: 'case aside');
    expect(row('LoRAs').values, ['', 'inkwash 0.75']);
    expect(row('Denoise').values, ['', '0.6'], reason: 'a setting only one has still shows');
    expect(rows.where((r) => r.label == 'Seed'), hasLength(1), reason: 'seed is not listed twice');
    expect(rows.any((r) => r.label == 'Size'), isTrue);
  });

  test('rows nobody has anything for are left out', () {
    final rows = compareRows([picture(), picture()]);
    expect(rows.any((r) => r.label == 'LoRAs'), isFalse);
    expect(rows.where((r) => r.differs), isEmpty);
  });

  test('a prompt is compared word by word', () {
    final pieces = wordDiff('a red fox, snow', 'a blue fox, snow, night');
    expect(pieces, const [
      DiffPiece('a ', Change.same),
      DiffPiece('blue', Change.added),
      DiffPiece(' red', Change.removed),
      DiffPiece(' fox, snow, ', Change.same),
      DiffPiece('night', Change.added),
    ]);
    // What is kept and added reads as the new prompt, exactly.
    expect(
      pieces.where((p) => p.change != Change.removed).map((p) => p.text).join(),
      'a blue fox, snow, night',
    );
  });

  test('the same prompt is all the same, case aside', () {
    final pieces = wordDiff('A Red fox', 'a red fox');
    expect(pieces, const [DiffPiece('a red fox', Change.same)]);
  });

  test('words dropped from the start and the end are shown where they were', () {
    final pieces = wordDiff('masterpiece, a fox, night', 'a fox');
    expect(pieces.first, const DiffPiece('masterpiece ', Change.removed));
    expect(pieces.last.change, Change.removed);
    expect(pieces.last.text.trim(), 'night');
    expect(
      pieces.where((p) => p.change == Change.same).map((p) => p.text).join(),
      'a fox',
    );
  });
}
