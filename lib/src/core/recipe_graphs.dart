/// Building a plain text-to-image graph for ComfyUI or InvokeAI from a
/// picture's settings, for when the picture does not carry that program's
/// own graph (it was made somewhere else). The model and LoRAs are matched
/// by name against what the server has installed.
library;

import 'models.dart';

/// The settings a built graph is made from, read from a picture's metadata
/// in whichever program's words it was written.
class Recipe {
  Recipe({
    required this.prompt,
    required this.negative,
    required this.model,
    required this.loras,
    required this.width,
    required this.height,
    this.steps,
    this.cfg,
    this.sampler,
    this.scheduler,
    this.clipSkip,
    this.vae = '',
    this.textEncoder = '',
    this.family,
  });

  final String prompt;
  final String negative;
  final String model;
  final List<LoraRef> loras;
  final int width;
  final int height;
  final int? steps;
  final double? cfg;

  /// In ComfyUI's words: `euler`, `dpmpp_2m`, `euler_ancestral`...
  final String? sampler;

  /// In ComfyUI's words: `normal`, `karras`, `exponential`...
  final String? scheduler;
  final int? clipSkip;

  /// The VAE and text encoder the picture names, if it names them: for a
  /// model that needs them chosen apart from it (a single-file Krea 2).
  final String vae;
  final String textEncoder;

  /// The family of model the picture was made with, as InvokeAI names its
  /// bases, when its names make it plain: `krea-2`. Null when they do not.
  /// For finding the same kind of model on a server that has it under
  /// another name or in another format.
  final String? family;

  /// Read from [info], with the user's own [prompt], [negative] and size,
  /// and their [steps] and [cfg] where set.
  factory Recipe.from(
    GenInfo info, {
    required String prompt,
    required String negative,
    required int width,
    required int height,
    int? steps,
    double? cfg,
    List<LoraRef>? loras,
  }) {
    String? p(List<String> names) {
      for (final e in info.params) {
        if (names.contains(e.key.toLowerCase())) return e.value.trim();
      }
      return null;
    }

    final (sampler, scheduler) = canonicalSampler(
      p(['sampler', 'sampler_name']),
      p(['schedule type', 'scheduler']),
    );
    return Recipe(
      prompt: prompt,
      negative: negative,
      model: info.model,
      loras: loras ?? info.loras,
      width: width,
      height: height,
      steps: steps ?? int.tryParse(p(['steps']) ?? '') ?? double.tryParse(p(['steps']) ?? '')?.round(),
      cfg: cfg ?? double.tryParse(p(['cfg scale', 'cfg', 'cfg_scale']) ?? ''),
      sampler: sampler,
      scheduler: scheduler,
      clipSkip: int.tryParse(p(['clip skip', 'clip_skip']) ?? ''),
      vae: [for (final m in info.models) if (m.kind == 'vae') m.name].firstOrNull ?? '',
      textEncoder: [for (final m in info.models) if (m.kind == 'clip') m.name].firstOrNull ?? '',
      family: pictureFamily(info),
    );
  }
}

// ---------------------------------------------------------------- samplers

/// A sampler (and schedule) in any program's words, as ComfyUI's
/// `(sampler_name, scheduler)`. Null where it is not known.
(String?, String?) canonicalSampler(String? sampler, String? schedule) {
  String? scheduler = switch (schedule?.toLowerCase().trim()) {
    'karras' => 'karras',
    'exponential' => 'exponential',
    'sgm uniform' || 'sgm_uniform' => 'sgm_uniform',
    'simple' => 'simple',
    'normal' => 'normal',
    'beta' => 'beta',
    'ddim_uniform' || 'ddim uniform' => 'ddim_uniform',
    _ => null,
  };
  if (sampler == null || sampler.trim().isEmpty) {
    // InvokeAI has no sampler setting: its "scheduler" is the sampler, with
    // Karras as a `_k` on the end ("dpmpp_2m_k").
    if (scheduler == null && schedule != null && schedule.trim().isNotEmpty) {
      return canonicalSampler(schedule, null);
    }
    return (null, scheduler);
  }
  var s = sampler.trim().toLowerCase();

  // A1111 / Forge spell the schedule into the name: "DPM++ 2M Karras".
  for (final (word, value) in const [
    (' karras', 'karras'),
    (' exponential', 'exponential'),
    (' sgm uniform', 'sgm_uniform'),
  ]) {
    if (s.endsWith(word)) {
      s = s.substring(0, s.length - word.length).trim();
      scheduler ??= value;
    }
  }
  // InvokeAI spells Karras as a `_k` suffix: "dpmpp_2m_k".
  if (s.endsWith('_k')) {
    s = s.substring(0, s.length - 2);
    scheduler ??= 'karras';
  }

  final name = switch (s) {
    'euler a' || 'euler_a' || 'euler_ancestral' => 'euler_ancestral',
    'euler' => 'euler',
    'heun' => 'heun',
    'lms' => 'lms',
    'ddim' => 'ddim',
    'ddpm' => 'ddpm',
    'deis' => 'deis',
    'lcm' => 'lcm',
    'dpm2' || 'dpm_2' || 'kdpm_2' => 'dpm_2',
    'dpm2 a' || 'dpm_2_a' || 'dpm_2_ancestral' || 'kdpm_2_a' => 'dpm_2_ancestral',
    'dpm++ 2m' || 'dpmpp_2m' => 'dpmpp_2m',
    'dpm++ 2m sde' || 'dpmpp_2m_sde' => 'dpmpp_2m_sde',
    'dpm++ sde' || 'dpmpp_sde' => 'dpmpp_sde',
    'dpm++ 2s a' || 'dpmpp_2s_a' || 'dpmpp_2s_ancestral' => 'dpmpp_2s_ancestral',
    'dpm++ 3m sde' || 'dpmpp_3m_sde' || 'dpmpp_3m' => 'dpmpp_3m_sde',
    'unipc' || 'uni_pc' => 'uni_pc',
    _ => null,
  };
  return (name, scheduler);
}

/// ComfyUI's `(sampler, scheduler)` as one of InvokeAI's scheduler names.
String? invokeScheduler(String? sampler, String? scheduler) {
  final base = switch (sampler) {
    'euler' => 'euler',
    'euler_ancestral' => 'euler_a',
    'heun' => 'heun',
    'lms' => 'lms',
    'ddim' => 'ddim',
    'ddpm' => 'ddpm',
    'deis' => 'deis',
    'lcm' => 'lcm',
    'dpm_2' => 'dpm_2',
    'dpm_2_ancestral' => 'dpm_2_a',
    'dpmpp_2m' => 'dpmpp_2m',
    'dpmpp_2m_sde' => 'dpmpp_2m_sde',
    'dpmpp_sde' => 'dpmpp_sde',
    'dpmpp_3m_sde' => 'dpmpp_3m',
    'uni_pc' => 'unipc',
    // No InvokeAI equivalent: the nearest.
    'dpmpp_2s_ancestral' => 'euler_a',
    _ => null,
  };
  if (base == null) return null;
  // InvokeAI has Karras versions of these, as `_k`.
  const withKarras = {'euler', 'heun', 'lms', 'deis', 'dpm_2', 'dpm_2_a', 'dpmpp_2m', 'dpmpp_2m_sde', 'dpmpp_sde', 'dpmpp_3m', 'unipc'};
  if (scheduler == 'karras' && withKarras.contains(base)) return '${base}_k';
  return base;
}

// ---------------------------------------------------------------- names

/// A model name reduced to what names it the same everywhere: no folder,
/// no extension, no ` [hash]`, lower case.
String modelKey(String name) {
  var s = name.trim();
  s = s.replaceFirst(RegExp(r'\s*\[[0-9a-fA-F]+\]$'), '');
  s = s.split(RegExp(r'[/\\]')).last;
  s = s.replaceFirst(RegExp(r'\.(safetensors|ckpt|pt|pth|bin|gguf|sft)$', caseSensitive: false), '');
  return s.toLowerCase().trim();
}

/// The one of [installed] that [wanted] names, matched by [modelKey].
T? findModel<T>(String wanted, Iterable<T> installed, Iterable<String> Function(T) names) {
  final key = modelKey(wanted);
  if (key.isEmpty) return null;
  for (final m in installed) {
    if (names(m).any((n) => modelKey(n) == key)) return m;
  }
  return null;
}

// ---------------------------------------------------------------- ComfyUI

/// What a built ComfyUI graph needs from the server: the file names of the
/// checkpoint and of each LoRA it has, exactly as it lists them.
class ComfyModels {
  const ComfyModels(this.checkpoints, this.loras);
  final List<String> checkpoints;
  final List<String> loras;

  /// The choices of input [field] of node [node] in an `/object_info` reply,
  /// in either of the shapes ComfyUI has used.
  static List<String> options(Map<String, dynamic> objectInfo, String node, String field) {
    final spec = (((objectInfo[node] as Map?)?['input'] as Map?)?['required'] as Map?)?[field];
    if (spec is! List || spec.isEmpty) return const [];
    final first = spec.first;
    if (first is List) return first.map((e) => '$e').toList();
    // Newer: ["COMBO", {"options": [...]}].
    if (spec.length > 1 && spec[1] is Map && (spec[1] as Map)['options'] is List) {
      return ((spec[1] as Map)['options'] as List).map((e) => '$e').toList();
    }
    return const [];
  }
}

/// A ComfyUI API-format graph making [recipe] with [seed], with the
/// checkpoint and LoRAs found in [installed]. [skipped] collects the LoRAs
/// left out because the server does not have them.
///
/// Throws [StateError] with a message for the user when the checkpoint is
/// not there.
Map<String, dynamic> comfyGraph(Recipe recipe, int seed, ComfyModels installed, {List<String>? skipped}) {
  final ckpt = findModel(recipe.model, installed.checkpoints, (n) => [n]);
  if (ckpt == null) {
    throw StateError(
      recipe.model.isEmpty
          ? 'This picture does not say which model made it, so ComfyUI cannot be given a workflow for it.'
          : 'ComfyUI has no checkpoint called "${recipe.model}". Install it there, or send to another server.',
    );
  }
  final g = <String, dynamic>{};
  var next = 1;
  String add(String type, Map<String, dynamic> inputs) {
    final id = '${next++}';
    g[id] = {'class_type': type, 'inputs': inputs};
    return id;
  }

  final loader = add('CheckpointLoaderSimple', {'ckpt_name': ckpt});
  List<Object> model = [loader, 0];
  List<Object> clip = [loader, 1];
  final vae = [loader, 2];
  for (final l in recipe.loras) {
    final file = findModel(l.name, installed.loras, (n) => [n]);
    if (file == null) {
      skipped?.add(l.name);
      continue;
    }
    final id = add('LoraLoader', {
      'lora_name': file,
      'strength_model': l.weight ?? 1.0,
      'strength_clip': l.weightClip ?? l.weight ?? 1.0,
      'model': model,
      'clip': clip,
    });
    model = [id, 0];
    clip = [id, 1];
  }
  final skip = recipe.clipSkip;
  if (skip != null && skip > 1) {
    final id = add('CLIPSetLastLayer', {'stop_at_clip_layer': -skip, 'clip': clip});
    clip = [id, 0];
  }
  final positive = add('CLIPTextEncode', {'text': recipe.prompt, 'clip': clip});
  final negative = add('CLIPTextEncode', {'text': recipe.negative, 'clip': clip});
  final latent = add('EmptyLatentImage', {'width': recipe.width, 'height': recipe.height, 'batch_size': 1});
  final sampler = add('KSampler', {
    'seed': seed,
    'steps': recipe.steps ?? 25,
    'cfg': recipe.cfg ?? 7.0,
    'sampler_name': recipe.sampler ?? 'euler',
    'scheduler': recipe.scheduler ?? 'normal',
    'denoise': 1.0,
    'model': model,
    'positive': [positive, 0],
    'negative': [negative, 0],
    'latent_image': [latent, 0],
  });
  final decode = add('VAEDecode', {'samples': [sampler, 0], 'vae': vae});
  add('SaveImage', {'filename_prefix': 'GenerativeView', 'images': [decode, 0]});
  return g;
}

// ---------------------------------------------------------------- InvokeAI

/// A model as InvokeAI identifies it in a graph.
class InvokeModel {
  const InvokeModel({
    required this.key,
    required this.hash,
    required this.name,
    required this.base,
    required this.type,
    this.path = '',
    this.format = '',
    this.variant = '',
  });
  final String key;
  final String hash;
  final String name;
  final String base;
  final String type;
  final String path;

  /// How it is stored: `diffusers`, `checkpoint`, `gguf_quantized`...
  final String format;

  /// Which of its kind it is: `krea2_turbo`, `qwen3_vl_4b`...
  final String variant;

  factory InvokeModel.fromJson(Map<String, dynamic> j) => InvokeModel(
        key: '${j['key'] ?? ''}',
        hash: '${j['hash'] ?? ''}',
        name: '${j['name'] ?? ''}',
        base: '${j['base'] ?? ''}',
        type: '${j['type'] ?? ''}',
        path: '${j['path'] ?? ''}',
        format: '${j['format'] ?? ''}',
        variant: '${j['variant'] ?? ''}',
      );

  Map<String, dynamic> get identifier => {'key': key, 'hash': hash, 'name': name, 'base': base, 'type': type};

  Iterable<String> get names => [name, if (path.isNotEmpty) path];
}

/// A picture already on the server for a built graph to start from, for
/// image to image.
class GraphInit {
  const GraphInit({required this.image, required this.strength, this.mask});

  /// The server's name for the picture.
  final String image;

  /// How much of it is redrawn, 0 to 1.
  final double strength;

  /// The server's name for the mask, if only part is redrawn. For InvokeAI
  /// it is white where the picture is kept.
  final String? mask;
}

/// An InvokeAI graph making [recipe] with [seed], with the main model and
/// LoRAs found among [mains] and [loras]. [skipped] collects the LoRAs left
/// out because the server does not have them (or has them only for another
/// kind of model).
///
/// Throws [StateError] with a message for the user when the model is not
/// there or is of a kind this cannot build for.
Map<String, dynamic> invokeGraph(
  Recipe recipe,
  int seed,
  List<InvokeModel> mains,
  List<InvokeModel> loras, {
  List<String>? skipped,
  GraphInit? init,
  List<InvokeModel> vaes = const [],
  List<InvokeModel> encoders = const [],
  List<String>? standIn,
}) {
  final (main, instead) = resolveMain(recipe, mains);
  if (main == null) {
    throw StateError(
      recipe.model.isEmpty
          ? 'This picture does not say which model made it, so InvokeAI cannot be given a graph for it.'
          : recipe.family == 'krea-2'
          ? 'InvokeAI has no Krea 2 model installed (this picture was made with "${recipe.model}"). '
                'Install one there, such as the Krea-2 bundle in its Model Manager.'
          : 'InvokeAI has no model called "${recipe.model}". Install it there, or send to another server.',
    );
  }
  if (instead) standIn?.add(main.name);
  if (main.base == 'krea-2') {
    return _krea2Graph(recipe, seed, main, loras, vaes, encoders, skipped: skipped, init: init);
  }
  final xl = main.base == 'sdxl';
  if (!xl && main.base != 'sd-1' && main.base != 'sd-2') {
    throw StateError(
      '"${main.name}" is a ${main.base} model. Only SD 1.x, SD 2.x, SDXL and Krea 2 '
      'graphs can be made for pictures from other programs.',
    );
  }

  final nodes = <String, dynamic>{};
  final edges = <Map<String, dynamic>>[];
  void node(String id, String type, [Map<String, dynamic> fields = const {}]) {
    nodes[id] = {'id': id, 'type': type, 'is_intermediate': true, 'use_cache': true, ...fields};
  }

  void edge(String from, String out, String to, String into) {
    edges.add({
      'source': {'node_id': from, 'field': out},
      'destination': {'node_id': to, 'field': into},
    });
  }

  node('model_loader', xl ? 'sdxl_model_loader' : 'main_model_loader', {'model': main.identifier});
  var unet = 'model_loader';
  var clip = 'model_loader';
  var clip2 = 'model_loader';
  var n = 0;
  for (final l in recipe.loras) {
    final found = findModel(l.name, loras.where((m) => m.base == main.base), (m) => m.names);
    if (found == null) {
      skipped?.add(l.name);
      continue;
    }
    final id = 'lora_${n++}';
    node(id, xl ? 'sdxl_lora_loader' : 'lora_loader', {'lora': found.identifier, 'weight': l.weight ?? 1.0});
    edge(unet, 'unet', id, 'unet');
    edge(clip, 'clip', id, 'clip');
    if (xl) edge(clip2, 'clip2', id, 'clip2');
    unet = clip = clip2 = id;
  }
  final skip = recipe.clipSkip;
  if (!xl && skip != null && skip > 1) {
    node('clip_skip', 'clip_skip', {'skipped_layers': skip - 1});
    edge(clip, 'clip', 'clip_skip', 'clip');
    clip = 'clip_skip';
  }

  for (final (id, text) in [('positive', recipe.prompt), ('negative', recipe.negative)]) {
    if (xl) {
      node(id, 'sdxl_compel_prompt', {
        'prompt': text,
        'style': text,
        'original_width': recipe.width,
        'original_height': recipe.height,
        'crop_top': 0,
        'crop_left': 0,
        'target_width': recipe.width,
        'target_height': recipe.height,
      });
      edge(clip, 'clip', id, 'clip');
      edge(clip2, 'clip2', id, 'clip2');
    } else {
      node(id, 'compel', {'prompt': text});
      edge(clip, 'clip', id, 'clip');
    }
  }

  final scheduler = invokeScheduler(recipe.sampler, recipe.scheduler) ?? 'euler';
  final steps = recipe.steps ?? 30;
  final cfg = recipe.cfg ?? (xl ? 5.0 : 7.5);
  node('noise', 'noise', {'seed': seed, 'width': recipe.width, 'height': recipe.height, 'use_cpu': true});
  final strength = init?.strength.clamp(0.0, 1.0);
  node('denoise', 'denoise_latents', {
    'cfg_scale': cfg,
    'scheduler': scheduler,
    'steps': steps,
    // Starting part way along is how much of the picture is kept.
    'denoising_start': strength == null ? 0.0 : 1 - strength,
    'denoising_end': 1.0,
  });
  edge(unet, 'unet', 'denoise', 'unet');
  edge('positive', 'conditioning', 'denoise', 'positive_conditioning');
  edge('negative', 'conditioning', 'denoise', 'negative_conditioning');
  edge('noise', 'noise', 'denoise', 'noise');
  if (init != null) {
    // The picture to start from, encoded.
    node('i2l', 'i2l', {
      'image': {'image_name': init.image},
      'fp32': xl,
    });
    edge('model_loader', 'vae', 'i2l', 'vae');
    edge('i2l', 'latents', 'denoise', 'latents');
    if (init.mask != null) {
      // Only the part not kept is redrawn.
      node('denoise_mask', 'create_denoise_mask', {
        'image': {'image_name': init.image},
        'mask': {'image_name': init.mask},
        'fp32': xl,
      });
      edge('model_loader', 'vae', 'denoise_mask', 'vae');
      edge('denoise_mask', 'denoise_mask', 'denoise', 'denoise_mask');
    }
  }

  // So the picture carries its settings, and reads (and remixes) like any
  // other InvokeAI picture.
  node('metadata', 'core_metadata', {
    'generation_mode': '${xl ? 'sdxl_' : ''}${init == null ? 'txt2img' : init.mask == null ? 'img2img' : 'inpaint'}',
    'strength': ?strength,
    'positive_prompt': recipe.prompt,
    'negative_prompt': recipe.negative,
    'width': recipe.width,
    'height': recipe.height,
    'seed': seed,
    'cfg_scale': cfg,
    'steps': steps,
    'scheduler': scheduler,
    'model': main.identifier,
    'loras': [
      for (final id in nodes.keys.where((k) => k.startsWith('lora_')))
        {'model': (nodes[id] as Map)['lora'], 'weight': (nodes[id] as Map)['weight']},
    ],
  });

  node('l2i', 'l2i', {'is_intermediate': false, 'use_cache': false, 'fp32': xl});
  edge('denoise', 'latents', 'l2i', 'latents');
  edge('model_loader', 'vae', 'l2i', 'vae');
  edge('metadata', 'metadata', 'l2i', 'metadata');

  return {'id': init == null ? 'generativeview_txt2img' : 'generativeview_img2img', 'nodes': nodes, 'edges': edges};
}

/// Whether InvokeAI needs a VAE and a Qwen3-VL encoder chosen for [main]:
/// a Krea 2 model saved as one file (a checkpoint or a GGUF) holds only the
/// transformer. One installed as Diffusers carries both.
bool krea2NeedsParts(InvokeModel main) => main.base == 'krea-2' && main.format != 'diffusers';

/// The bases of the VAEs InvokeAI lets a Krea 2 model decode with: the
/// Qwen-Image VAE (the same file can be registered as Anima's).
const Set<String> _krea2VaeBases = {'qwen-image', 'anima', 'krea-2'};

/// A Krea 2 graph for InvokeAI, built the way InvokeAI's own Generate tab
/// builds one: the model loader, a Krea 2 text encoder for the prompt (and
/// for the negative prompt, only with CFG on, above 1), LoRAs through the
/// collection loader, Krea 2's denoise step, and the Qwen-Image VAE's
/// latents-to-image to finish. With [init], the picture is encoded with
/// the same VAE and the denoise step starts part way along.
Map<String, dynamic> _krea2Graph(
  Recipe recipe,
  int seed,
  InvokeModel main,
  List<InvokeModel> loras,
  List<InvokeModel> vaes,
  List<InvokeModel> encoders, {
  List<String>? skipped,
  GraphInit? init,
}) {
  InvokeModel? vae;
  InvokeModel? encoder;
  if (krea2NeedsParts(main)) {
    final fitting = [for (final m in vaes) if (m.type == 'vae' && _krea2VaeBases.contains(m.base)) m];
    vae = findModel(recipe.vae, fitting, (m) => m.names) ?? fitting.firstOrNull;
    // The 4B encoder is Krea 2's; the 8B one is another model's.
    final encoding = [
      for (final m in encoders)
        if (m.type == 'qwen3_vl_encoder' && m.variant != 'qwen3_vl_8b') m,
    ];
    encoder = findModel(recipe.textEncoder, encoding, (m) => m.names) ?? encoding.firstOrNull;
    final missing = [
      if (vae == null) 'a Qwen-Image VAE',
      if (encoder == null) 'a Qwen3-VL encoder',
    ];
    if (missing.isNotEmpty) {
      throw StateError(
        '"${main.name}" is a single-file Krea 2 model, so InvokeAI needs ${missing.join(' and ')} '
        'installed alongside it. The Krea-2 bundle in InvokeAI\'s Model Manager has both.',
      );
    }
  }

  final nodes = <String, dynamic>{};
  final edges = <Map<String, dynamic>>[];
  void node(String id, String type, [Map<String, dynamic> fields = const {}]) {
    nodes[id] = {'id': id, 'type': type, 'is_intermediate': true, 'use_cache': true, ...fields};
  }

  void edge(String from, String out, String to, String into) {
    edges.add({
      'source': {'node_id': from, 'field': out},
      'destination': {'node_id': to, 'field': into},
    });
  }

  // Turbo is distilled: 8 steps, CFG off (1). The undistilled base model
  // wants more of both. A picture that says what it used keeps that.
  final distilled = main.variant != 'krea2_base';
  final steps = recipe.steps ?? (distilled ? 8 : 28);
  final cfg = recipe.cfg ?? (distilled ? 1.0 : 5.5);
  final guided = cfg > 1;

  node('model_loader', 'krea2_model_loader', {
    'model': main.identifier,
    'vae_model': ?vae?.identifier,
    'qwen3_vl_encoder_model': ?encoder?.identifier,
  });
  var transformer = 'model_loader';
  var textEncoder = 'model_loader';

  // LoRAs: each picked, collected, and applied together, which reroutes
  // the transformer and the text encoder through the collection loader.
  final picked = <Map<String, dynamic>>[];
  for (final l in recipe.loras) {
    final found = findModel(l.name, loras.where((m) => m.base == 'krea-2' && m.type == 'lora'), (m) => m.names);
    if (found == null) {
      skipped?.add(l.name);
      continue;
    }
    picked.add({'model': found.identifier, 'weight': l.weight ?? 1.0});
  }
  if (picked.isNotEmpty) {
    node('lora_collect', 'collect');
    node('lora_loader', 'krea2_lora_collection_loader');
    for (var i = 0; i < picked.length; i++) {
      node('lora_$i', 'lora_selector', {'lora': picked[i]['model'], 'weight': picked[i]['weight']});
      edge('lora_$i', 'lora', 'lora_collect', 'item');
    }
    edge('lora_collect', 'collection', 'lora_loader', 'loras');
    edge('model_loader', 'transformer', 'lora_loader', 'transformer');
    edge('model_loader', 'qwen3_vl_encoder', 'lora_loader', 'qwen3_vl_encoder');
    transformer = textEncoder = 'lora_loader';
  }

  node('positive', 'krea2_text_encoder', {'prompt': recipe.prompt});
  edge(textEncoder, 'qwen3_vl_encoder', 'positive', 'qwen3_vl_encoder');
  node('positive_collect', 'collect');
  edge('positive', 'conditioning', 'positive_collect', 'item');
  if (guided) {
    node('negative', 'krea2_text_encoder', {'prompt': recipe.negative});
    edge(textEncoder, 'qwen3_vl_encoder', 'negative', 'qwen3_vl_encoder');
  }

  final strength = init?.strength.clamp(0.0, 1.0);
  node('denoise', 'krea2_denoise', {
    'cfg_scale': cfg,
    'steps': steps,
    'seed': seed,
    'width': recipe.width,
    'height': recipe.height,
    // Starting part way along is how much of the picture is kept.
    'denoising_start': strength == null ? 0.0 : 1 - strength,
    'denoising_end': 1.0,
  });
  edge(transformer, 'transformer', 'denoise', 'transformer');
  edge('positive_collect', 'collection', 'denoise', 'positive_conditioning');
  if (guided) edge('negative', 'conditioning', 'denoise', 'negative_conditioning');

  if (init != null) {
    // The picture to start from, encoded with the same VAE.
    node('i2l', 'qwen_image_i2l', {'image': {'image_name': init.image}});
    edge('model_loader', 'vae', 'i2l', 'vae');
    edge('i2l', 'latents', 'denoise', 'latents');
    if (init.mask != null) {
      // Only the part not kept is redrawn.
      node('denoise_mask', 'create_denoise_mask', {'mask': {'image_name': init.mask}});
      edge('model_loader', 'vae', 'denoise_mask', 'vae');
      edge('denoise_mask', 'denoise_mask', 'denoise', 'denoise_mask');
    }
  }

  // So the picture carries its settings, and reads (and remixes) like any
  // other InvokeAI picture.
  node('metadata', 'core_metadata', {
    'generation_mode': 'krea2_${init == null ? 'txt2img' : init.mask == null ? 'img2img' : 'inpaint'}',
    'strength': ?strength,
    'positive_prompt': recipe.prompt,
    if (guided) 'negative_prompt': recipe.negative,
    'width': recipe.width,
    'height': recipe.height,
    'seed': seed,
    'cfg_scale': cfg,
    'steps': steps,
    'model': main.identifier,
    'vae': ?vae?.identifier,
    'qwen3_vl_encoder': ?encoder?.identifier,
    'loras': picked,
  });

  node('l2i', 'qwen_image_l2i', {'is_intermediate': false, 'use_cache': false});
  edge('denoise', 'latents', 'l2i', 'latents');
  edge('model_loader', 'vae', 'l2i', 'vae');
  edge('metadata', 'metadata', 'l2i', 'metadata');

  return {'id': init == null ? 'generativeview_krea2_txt2img' : 'generativeview_krea2_img2img', 'nodes': nodes, 'edges': edges};
}

/// The family of model [info] was made with, as InvokeAI names its bases,
/// when the picture's own names make it plain: the model, the other models
/// it loaded, and the workflow's nodes. Only `krea-2` for now: its files
/// are named for it (`krea2_turbo_fp8_scaled`, `Krea-2-Raw`), and the same
/// weights are installed under quite different names from one program to
/// the next.
String? pictureFamily(GenInfo info) {
  final krea = RegExp(r'krea[\s_-]?2', caseSensitive: false);
  final names = [
    info.model,
    for (final m in info.models) m.name,
    for (final n in info.nodes) ...[n.type, n.title, for (final i in n.inputs) i.value],
  ];
  return names.any(krea.hasMatch) ? 'krea-2' : null;
}

/// The main model of [mains] to build [recipe] with: the one it names, or,
/// when the server has it under no such name and the picture's [Recipe.family]
/// is known, the installed model of that family most like it: the same
/// variant (Turbo or the base model) first, then the most words of its name
/// in common. The second value is true when it is such a stand-in.
(InvokeModel?, bool) resolveMain(Recipe recipe, List<InvokeModel> mains) {
  final exact = findModel(recipe.model, mains, (m) => m.names);
  if (exact != null) return (exact, false);
  final family = recipe.family;
  if (family == null) return (null, false);
  final kin = [for (final m in mains) if (m.base == family && (m.type.isEmpty || m.type == 'main')) m];
  if (kin.isEmpty) return (null, false);
  Set<String> words(String name) => modelKey(name).split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 1).toSet();
  final wanted = words(recipe.model);
  // Turbo is distilled: few steps and CFG off. Named, or told by its settings.
  final wantsTurbo = wanted.contains('turbo') ||
      (!wanted.contains('raw') && !wanted.contains('base') && (recipe.steps ?? 8) <= 12 && (recipe.cfg ?? 1) <= 1.5);
  double score(InvokeModel m) {
    final turbo = m.variant.isEmpty ? words(m.name).contains('turbo') : m.variant == 'krea2_turbo';
    var s = turbo == wantsTurbo ? 10.0 : 0.0;
    for (final n in m.names) {
      s += words(n).intersection(wanted).length;
    }
    // One that needs no VAE or encoder chosen for it is the surer choice.
    if (m.format == 'diffusers') s += 0.5;
    return s;
  }

  final best = kin.reduce((a, b) => score(b) > score(a) ? b : a);
  return (best, true);
}
