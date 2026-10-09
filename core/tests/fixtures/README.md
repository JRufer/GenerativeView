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
