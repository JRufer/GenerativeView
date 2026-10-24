# Remix servers: keeping ComfyUI, InvokeAI and Forge level

Every remix feature should work the same whichever server it goes to. Three
layers check that.

## 1. The parity table (runs in CI)

`test/backend_parity_test.dart` runs every remix feature against every
server, each played by a small stand-in server that keeps what it is sent.
The same checks read what each server was sent, so a feature that works for
one server and not another fails there.

Each feature is tried on four pictures:

- the server's own SDXL picture (its graph sent back, changed in place)
- the server's own Krea 2 picture
- an SDXL picture from another program (a graph built from its settings)
- a Krea 2 picture from another program (built, with the model found by
  family when the server has it under another name)

Features covered: edited prompt, seed and one more per picture, size, steps
and CFG, the model, a LoRA reweighted, a LoRA switched off, image to image,
a painted area redrawn, and hires fix.

**Adding a feature:** add a `Feature` to the `features` list. It then runs
on every server and every picture. If a combination truly cannot work, add it
to `notApplicable` with the reason, so the gap is written down rather than
silent.

**Adding a server:** add it to `servers`, give `FakeServer` its answers and
`read` its payload shape. The table checks that every server in
`backendNames` is there.

## 2. The live check (your own servers)

`test/live_remix_test.dart` sends real remixes to real servers and waits for
the pictures: text to image (two pictures), image to image from the first,
a masked half redrawn, and a remix picked up again as though the app had
been closed. It skips itself unless addresses are given:

```sh
GV_LIVE_COMFYUI=http://127.0.0.1:8188 \
GV_LIVE_INVOKEAI=http://127.0.0.1:9090 \
GV_LIVE_KREA2_MODEL=krea2_turbo_fp8_scaled \
GV_LIVE_SDXL_MODEL=juggernautXL_v9 \
GV_LIVE_OUT=/tmp/gv-live \
flutter test test/live_remix_test.dart
```

Leave out any server or model you do not have. One model name works for
every server: it is matched the way the app matches it. Pictures are saved
to `GV_LIVE_OUT` to look over.

## 3. By hand, on the Fold and on Linux

With ComfyUI chosen in the remix panel, for a ComfyUI picture, an InvokeAI
Krea 2 picture, and a Forge picture:

- [ ] Text to image: edited prompt, two pictures, random seed off
- [ ] Size slider stops only on sizes the server takes; the aspect lock holds
- [ ] Steps and CFG, by slider and typed
- [ ] LoRA section: one switched off, one reweighted
- [ ] Image to image at a few strengths
- [ ] Mask painted, then traced, only that area redrawn
- [ ] Hires fix (upscale, then refine on ComfyUI) at 1.5× and 2×
- [ ] Close the app mid-render: the remix is picked up on reopening
- [ ] Android: screen locked while waiting; notification when done
- [ ] Status button: running, then done; tapping done opens Remixes with the
      new pictures highlighted
- [ ] A Krea 2 picture with no Krea 2 model on the server says so plainly
