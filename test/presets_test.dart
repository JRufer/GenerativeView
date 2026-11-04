import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/core/backends.dart';
import 'package:generativeview/src/core/lora_edits.dart';
import 'package:generativeview/src/core/models.dart';
import 'package:generativeview/src/core/presets.dart';

void main() {
  const ink = Preset(
    id: 'a',
    name: 'Ink wash',
    prompt: 'ink wash painting, (loose brushwork:1.2)',
    negative: 'photo',
    loras: [PresetLora('styles/inkwash.safetensors', 0.8)],
    steps: 28,
    cfg: 4.5,
  );

  test('a preset survives the file it is exported to', () {
    final back = presetsFromFile(presetsToFile([ink])).single;
    expect(back.toJson(), ink.toJson());
    expect(back.parts, ['Prompt', 'Negative', '1 LoRA', 'Steps, CFG']);
    expect(() => presetsFromFile('{"images":{}}'), throwsFormatException);
  });

  test('another model drops the picture\'s own graph and finds its name', () {
    final info = GenInfo(
      source: 'invokeai',
      prompt: 'a fox',
      negative: '',
      seed: '1',
      model: 'gone.safetensors',
      models: const [],
      loras: const [],
      params: const [],
      nodes: const [],
      raw: const [MapEntry('invokeai_graph', '{}'), MapEntry('invokeai_metadata', '{}')],
      width: 64,
      height: 64,
      durationMs: 0,
    );
    final swapped = withModel(info, 'krea2');
    expect(swapped.model, 'krea2');
    expect(carriesGraph('invokeai', swapped), isFalse);
    expect([for (final r in swapped.raw) r.key], ['invokeai_metadata']);
    expect(matchServerModel('models/Krea2.safetensors', ['krea2.safetensors']), 'krea2.safetensors');
    expect(matchServerModel('gone', ['krea2']), isNull);
  });

  test('text is added phrase by phrase, or replaces', () {
    expect(applyPresetText('a fox', 'snow, dawn', replace: false), 'a fox, snow, dawn');
    expect(applyPresetText('a fox, snow', 'snow, dawn', replace: false), 'a fox, snow, dawn');
    expect(applyPresetText('a fox', 'an owl', replace: true), 'an owl');
    expect(addedPresetPhrases('a fox, snow', 'snow, dawn', replace: false), ['dawn']);
  });

  test('a LoRA the picture has takes the weight, and a new one joins', () {
    final loras = [LoraChoice(LoraRef('inkwash.safetensors', 0.3, null, ''), enabled: false)];
    applyPresetLoras(loras, const [PresetLora('styles/inkwash.safetensors', 0.8), PresetLora('grain', 0.5)]);
    expect(loras.length, 2);
    expect(loras[0].enabled, isTrue);
    expect(loras[0].weight, 0.8);
    expect(loras[1].original.name, 'grain');
  });

  test('import skips what is here already and numbers a clash', () {
    var n = 0;
    final other = ink.copyWith(id: 'b');
    expect(mergePresets([ink], [other], () => '${n++}').length, 1);
    const clash = Preset(id: 'c', name: 'Ink wash', prompt: 'something else');
    final merged = mergePresets([ink], [clash], () => '${n++}');
    expect(merged.last.name, 'Ink wash (2)');
  });
}
