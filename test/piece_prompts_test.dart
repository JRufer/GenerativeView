import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/detail_pass.dart';
import 'package:generativeview/src/core/piece_prompts.dart';

void main() {
  const phrases = [
    PiecePhrase('masterpiece', quality: true),
    PiecePhrase('1girl'),
    PiecePhrase('red dress'),
    PiecePhrase('holding a sword'),
    PiecePhrase('blue eyes'),
    PiecePhrase('castle in the background'),
    PiecePhrase('oil painting', look: true),
  ];

  test('a tile keeps what holds everywhere and what it shows, never the rest', () {
    expect(piecePrompt(phrases, seen: {5}, loras: ['<lora:ink:0.7>']), 'masterpiece, castle in the background, oil painting, <lora:ink:0.7>');
    expect(piecePrompt(phrases), 'masterpiece, oil painting');
  });

  test('a tile with nothing left asks for detail', () {
    expect(piecePrompt(const [PiecePhrase('a fox')]), 'highly detailed, sharp focus');
  });

  test('a hand is drawn as a hand, with no person or face in it', () {
    final p = piecePrompt(phrases, seen: {1, 2, 3, 4}, kind: DetailKind.hand, extra: 'gloves');
    expect(p, 'a detailed hand, natural fingers, correct anatomy, masterpiece, red dress, holding a sword, oil painting, gloves');
    expect(p, isNot(contains('1girl')));
    expect(p, isNot(contains('eyes')));
  });

  test('a face keeps what is seen around it', () {
    expect(piecePrompt(phrases, seen: {1, 4}, kind: DetailKind.face), 'a detailed face, clear eyes, masterpiece, 1girl, blue eyes, oil painting');
  });

  test('negatives gain what a part should not be', () {
    expect(pieceNegative('blurry', kind: DetailKind.hand), startsWith('blurry, extra fingers'));
    expect(pieceNegative('', kind: DetailKind.face), 'deformed face, asymmetrical eyes');
    expect(pieceNegative('blurry'), 'blurry');
  });

  test('LoRA tags are kept as written', () {
    expect(loraTags('a fox <lora:fur:0.8>, snow, <hypernet:x:1>'), ['<lora:fur:0.8>', '<hypernet:x:1>']);
  });

  test('a core reply is read, and a failing core leaves the subjects out', () async {
    final prompts = await piecePrompts(
      (method, args) async => {
        'phrases': [
          {'text': 'best quality', 'quality': true, 'look': false},
          {'text': 'a fox', 'quality': false, 'look': false},
          {'text': 'snowy forest', 'quality': false, 'look': false},
        ],
        'parts': [
          [1],
          [2],
        ],
      },
      path: 'x.png',
      prompt: 'best quality, a fox, snowy forest <lora:a:1>',
      boxes: const [
        [0, 0, 10, 10],
        [10, 0, 20, 10],
      ],
    );
    expect(prompts, ['best quality, a fox, <lora:a:1>', 'best quality, snowy forest, <lora:a:1>']);

    final failed = await piecePrompts(
      (method, args) async => throw StateError('no core'),
      path: 'x.png',
      prompt: 'a fox',
      boxes: const [
        [0, 0, 1, 1],
      ],
      kinds: const [DetailKind.hand],
    );
    expect(failed, ['a detailed hand, natural fingers, correct anatomy']);
  });

  test('tiles are never asked for a subject, even one the model sees', () async {
    Object? asked;
    final prompts = await piecePrompts(
      (method, args) async {
        asked = args['boxes'];
        return {
          'phrases': [
            {'text': '1girl', 'quality': false, 'look': false},
            {'text': 'oil painting', 'quality': false, 'look': true},
          ],
          'parts': [
            [0],
            [0],
          ],
        };
      },
      path: 'x.png',
      prompt: '1girl, oil painting <lora:a:1>',
      boxes: const [
        [0, 0, 10, 10],
        [10, 0, 20, 10],
      ],
      subjects: false,
    );
    expect(prompts, ['oil painting, <lora:a:1>', 'oil painting, <lora:a:1>']);
    expect(asked, isEmpty);
  });

  test('without the content model only the marks are gone by', () async {
    final prompts = await piecePrompts(
      (method, args) async => {
        'phrases': [
          {'text': 'a fox', 'quality': false, 'look': false},
          {'text': 'watercolor', 'quality': false, 'look': true},
        ],
        'parts': null,
      },
      path: 'x.png',
      prompt: 'a fox, watercolor',
      boxes: const [
        [0, 0, 1, 1],
      ],
    );
    expect(prompts, ['watercolor']);
  });
}
