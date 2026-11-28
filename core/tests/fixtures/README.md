Test fixtures.

`comfy_*.json` are the `prompt` and `workflow` graphs embedded in images from
https://github.com/comfyanonymous/ComfyUI_examples (free to use for any
purpose per that repository's licence). The tests write them back into image
files to exercise the readers end to end.

The video files are one-second ffmpeg test patterns carrying the same graph in
the ways ComfyUI tools store it:

- `vhs_comment.mp4` / `.mov` — VideoHelperSuite: one `comment` tag holding
  `{"prompt": "<json string>", "workflow": {...}}`
- `comfy_tags.mp4` — ComfyUI SaveVideo: separate `prompt` / `workflow` tags
  (`-movflags use_metadata_tags`)
- `comfy_tags.webm` — ComfyUI SaveWEBM: Matroska tags

`novelai_v5.json` is the text chunks (`Description`, `Software`, `Source`,
`Generation time`, `Comment`) of a NovelAI Diffusion V5 picture with three
characters, from the app's author. The tests put them back as PNG text
chunks, as WebP EXIF (NovelAI's WebP layout) and hidden in the alpha
channel.
