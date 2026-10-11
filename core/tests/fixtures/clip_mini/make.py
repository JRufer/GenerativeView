"""Regenerates the CLIP reference fixtures in this folder.

    pip install torch transformers safetensors pillow numpy
    python make.py /path/to/bpe_simple_vocab_16e6.txt.gz

(the vocabulary file is OpenAI's, from github.com/openai/CLIP, clip/).

What it writes, and what the Rust tests do with it:

  model.safetensors, config.json
      A CLIP model in Hugging Face's layout with made-up weights: a few
      layers, a few dozen dimensions. The tests run it through gvcore's own
      implementation and compare against what transformers computed.
  tokenizer.json
      CLIP's tokenizer cut down to its first 1,200 merges.
  reference.json
      Token ids, embeddings and preprocessed pixels to compare against.
  photo.png
      A small picture to preprocess.
"""
import gzip, json, sys, os
import numpy as np
import torch
from PIL import Image
from tokenizers import Regex, Tokenizer, models, normalizers, pre_tokenizers, processors
from transformers import CLIPConfig, CLIPImageProcessor, CLIPModel

here = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[2] if len(sys.argv) > 2 else here
merges_kept = int(sys.argv[3]) if len(sys.argv) > 3 else 1200
torch.manual_seed(7)
np.random.seed(7)

# ---------------------------------------------------------------- tokenizer
def bytes_to_unicode():
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    cs = bs[:]
    n = 0
    for b in range(2 ** 8):
        if b not in bs:
            bs.append(b)
            cs.append(2 ** 8 + n)
            n += 1
    return dict(zip(bs, [chr(c) for c in cs]))

lines = gzip.open(sys.argv[1]).read().decode("utf-8").split("\n")
merges = [tuple(m.split()) for m in lines[1:49152 - 256 - 2 + 1]][:merges_kept]
vocab = list(bytes_to_unicode().values())
vocab = vocab + [v + "</w>" for v in vocab] + ["".join(m) for m in merges] + ["<|startoftext|>", "<|endoftext|>"]
os.makedirs(out, exist_ok=True)
tmp = os.path.join(out, "_tmp")
os.makedirs(tmp, exist_ok=True)
json.dump({t: i for i, t in enumerate(vocab)}, open(os.path.join(tmp, "vocab.json"), "w"), ensure_ascii=False)
open(os.path.join(tmp, "merges.txt"), "w").write("#version: 0.2\n" + "\n".join(" ".join(m) for m in merges) + "\n")
# The tokenizer as Hugging Face ships it for CLIP: NFC, single spaces and
# lower case; CLIP's splitting pattern; byte-level BPE with </w> word ends.
sot, eot = len(vocab) - 2, len(vocab) - 1
tok = Tokenizer(models.BPE(vocab={t: i for i, t in enumerate(vocab)}, merges=merges, unk_token="<|endoftext|>",
                           continuing_subword_prefix="", end_of_word_suffix="</w>", fuse_unk=False))
tok.normalizer = normalizers.Sequence([normalizers.NFC(), normalizers.Replace(Regex(r"\s+"), " "), normalizers.Lowercase()])
tok.pre_tokenizer = pre_tokenizers.Sequence([
    pre_tokenizers.Split(Regex(r"""<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"""),
                         behavior="removed", invert=True),
    pre_tokenizers.ByteLevel(add_prefix_space=False),
])
tok.post_processor = processors.RobertaProcessing(("<|endoftext|>", eot), ("<|startoftext|>", sot), False, False)
tok.add_special_tokens(["<|startoftext|>", "<|endoftext|>"])
tok.enable_truncation(max_length=77)
tok.save(os.path.join(out, "tokenizer.json"))

texts = [
    "a photo of a cat",
    "a photo of a dog",
    "A red fox asleep in fresh snow, macro",
    "cinematic photo of a lighthouse on a cliff, stormy sea; volumetric light!",
    "it's the cat's 2nd birthday... they're 10 & don't care",
    "  Tabs\tand\nnewlines   collapse  ",
    "naïve café, 東京 at night — neon",
    "isometric cutaway of a clockwork owl (highly detailed:1.2) <lora:x:0.8>",
    "",
    "supercalifragilisticexpialidocious antidisestablishmentarianism " * 12,
]
ids = [tok.encode(t).ids for t in texts]

# ---------------------------------------------------------------- model
config = CLIPConfig(
    projection_dim=24,
    text_config=dict(vocab_size=len(vocab), hidden_size=32, intermediate_size=64, num_hidden_layers=3, num_attention_heads=4,
                     max_position_embeddings=77, hidden_act="gelu", eos_token_id=2, bos_token_id=0, pad_token_id=1),
    vision_config=dict(hidden_size=48, intermediate_size=96, num_hidden_layers=2, num_attention_heads=3, image_size=64,
                       patch_size=16, hidden_act="quick_gelu"),
)
model = CLIPModel(config).eval()
with torch.no_grad():
    for name, p in model.named_parameters():
        # Everything away from its initial value, so nothing is skipped unnoticed.
        scale = 0.6 if "embedding" in name else 0.25
        p.copy_(torch.randn_like(p) * scale + (1.0 if "norm" in name and name.endswith("weight") else 0.0))
model.save_pretrained(tmp, safe_serialization=True)
os.replace(os.path.join(tmp, "model.safetensors"), os.path.join(out, "model.safetensors"))
os.replace(os.path.join(tmp, "config.json"), os.path.join(out, "config.json"))

# ---------------------------------------------------------------- image
w, h = 150, 90
yy, xx = np.mgrid[0:h, 0:w]
photo = np.stack([
    (127 + 120 * np.sin(xx / 9.0) * np.cos(yy / 13.0)),
    (xx * 255.0 / w),
    (255 - yy * 255.0 / h) * (((xx // 15) + (yy // 15)) % 2),
], axis=-1).clip(0, 255).astype(np.uint8)
Image.fromarray(photo).save(os.path.join(out, "photo.png"))
processor = CLIPImageProcessor(size={"shortest_edge": 64}, crop_size={"height": 64, "width": 64})
pixels = processor(images=Image.open(os.path.join(out, "photo.png")), return_tensors="pt")["pixel_values"]

with torch.no_grad():
    image = model.get_image_features(pixel_values=pixels)
    image = getattr(image, "pooler_output", image)
    image = image / image.norm(dim=-1, keepdim=True)
    # Also a picture given as exact pixels, to check the model apart from the resizing.
    exact = torch.randn(1, 3, 64, 64)
    exact_out = model.get_image_features(pixel_values=exact)
    exact_out = getattr(exact_out, "pooler_output", exact_out)
    exact_out = exact_out / exact_out.norm(dim=-1, keepdim=True)
    text_out = []
    for seq in ids:
        t = model.get_text_features(input_ids=torch.tensor([seq]))
        t = getattr(t, "pooler_output", t)
        text_out.append((t / t.norm(dim=-1, keepdim=True))[0].tolist())

r = lambda a: [round(float(x), 6) for x in a]
json.dump({
    "texts": texts,
    "ids": ids,
    "text_embeddings": [r(t) for t in text_out],
    "exact_pixels": r(exact.flatten().tolist()),
    "exact_embedding": r(exact_out[0].tolist()),
    "photo_pixels": r(pixels.flatten().tolist()),
    "photo_embedding": r(image[0].tolist()),
}, open(os.path.join(out, "reference.json"), "w"))
for f in os.listdir(tmp):
    os.remove(os.path.join(tmp, f))
os.rmdir(tmp)
print({f: os.path.getsize(os.path.join(out, f)) for f in sorted(os.listdir(out))})
print("ids[0]", ids[0], "len(last)", len(ids[-1]))
