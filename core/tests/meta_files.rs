//! End-to-end metadata extraction: bytes on disk -> GenInfo.

mod common;
use common::*;
use gvcore::meta::{extract, GenInfo};

fn param<'a>(info: &'a GenInfo, key: &str) -> Option<&'a str> {
    info.params.iter().find(|p| p.0 == key).map(|p| p.1.as_str())
}

fn kinds(info: &GenInfo, kind: &str) -> Vec<String> {
    info.models.iter().filter(|m| m.kind == kind).map(|m| m.name.clone()).collect()
}

fn comfy_png(name: &str) -> GenInfo {
    let (prompt, workflow) = comfy(name);
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("ComfyUI_00001_.png");
    write_png(&path, 1, &[("prompt", &prompt), ("workflow", &workflow)]);
    extract(&path)
}

#[test]
fn comfy_flux_custom_sampler() {
    // SamplerCustomAdvanced: seed, steps and prompt all arrive through links
    // (RandomNoise, BasicScheduler, BasicGuider -> FluxGuidance -> CLIPTextEncode).
    let info = comfy_png("comfy_flux_dev.json");
    assert_eq!(info.source, "comfyui");
    assert_eq!((info.width, info.height), (96, 64));
    assert!(info.prompt.starts_with("cute anime girl with massive fluffy fennec ears"), "{}", info.prompt);
    assert_eq!(info.negative, "");
    assert_eq!(info.seed, "219670278747233");
    assert_eq!(info.model, "flux1-dev.safetensors");
    assert_eq!(kinds(&info, "unet"), ["flux1-dev.safetensors"]);
    assert_eq!(kinds(&info, "vae"), ["ae.safetensors"]);
    assert_eq!(kinds(&info, "clip"), ["t5xxl_fp16.safetensors", "clip_l.safetensors"]);
    assert_eq!(param(&info, "Steps"), Some("20"));
    assert_eq!(param(&info, "Sampler"), Some("euler"));
    assert_eq!(param(&info, "Scheduler"), Some("simple"));
    assert_eq!(param(&info, "Guidance"), Some("3.5"));
    assert_eq!(param(&info, "Size"), Some("1024x1024"));
    // The whole graph is available for display, and the raw JSON for copying.
    assert!(info.nodes.iter().any(|n| n.class == "SamplerCustomAdvanced"));
    assert!(info.raw.iter().any(|(k, v)| k == "workflow" && v.starts_with('{')));
}

#[test]
fn comfy_loras_with_weights() {
    let info = comfy_png("comfy_lora_multiple.json");
    assert_eq!(info.prompt, "masterpiece best quality girl");
    assert_eq!(info.negative, "bad hands");
    assert_eq!(info.model, "v1-5-pruned-emaonly.ckpt");
    let loras: Vec<_> = info.loras.iter().map(|l| (l.name.as_str(), l.weight, l.weight_clip)).collect();
    assert_eq!(
        loras,
        [
            ("epiNoiseoffset_v2.safetensors", Some(1.0), Some(1.0)),
            ("theovercomer8sContrastFix_sd15.safetensors", Some(1.0), Some(1.0)),
        ]
    );
    assert_eq!(param(&info, "CFG"), Some("8"));
}

#[test]
fn comfy_controlnet_keeps_polarity_and_zeroed_negative() {
    // positive/negative both pass through ControlNetApplyAdvanced, and the
    // negative is a ConditioningZeroOut of the positive text: no negative.
    let info = comfy_png("comfy_sd35_controlnet.json");
    assert!(info.prompt.starts_with("happy cute anime fox girl"));
    assert_eq!(info.negative, "");
    assert_eq!(kinds(&info, "controlnet"), ["sd3.5_large_controlnet_canny.safetensors"]);
    assert_eq!(info.model, "sd3.5_large_fp8_scaled.safetensors");
}

#[test]
fn comfy_area_composition_gathers_every_prompt() {
    let info = comfy_png("comfy_area_composition.json");
    for needle in ["fennec ears", "snow mountain peak", "(hands), text, error"] {
        let hay = if needle.starts_with("(hands)") { &info.negative } else { &info.prompt };
        assert!(hay.contains(needle), "missing {needle:?} in {hay:?}");
    }
    assert_eq!(param(&info, "Clip skip"), Some("-2"));
}

#[test]
fn comfy_two_pass_reports_first_pass() {
    let info = comfy_png("comfy_hires_fix.json");
    assert_eq!(info.seed, "251225068430076");
    assert_eq!(param(&info, "Denoise"), Some("1"));
    assert_eq!(kinds(&info, "upscaler"), ["RealESRGAN_x4plus.pth"]);

    let info = comfy_png("comfy_sdxl_refiner.json");
    assert_eq!(kinds(&info, "checkpoint"), ["sd_xl_base_1.0.safetensors", "sd_xl_refiner_1.0.safetensors"]);
    assert_eq!(info.model, "sd_xl_base_1.0.safetensors");
    assert_eq!(param(&info, "End step"), Some("20"));
}

#[test]
fn comfy_webp_exif() {
    let (prompt, workflow) = comfy("comfy_wan_video.json");
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("ComfyUI_00001_.webp");
    std::fs::write(&path, webp_with_comfy_exif(&prompt, &workflow)).unwrap();
    let info = extract(&path);
    assert_eq!(info.source, "comfyui");
    assert_eq!((info.width, info.height), (72, 40));
    assert!(info.prompt.starts_with("a fox moving quickly"));
    assert!(info.negative.contains("JPEG"));
    assert_eq!(info.model, "wan2.1_t2v_1.3B_fp16.safetensors");
    assert_eq!(param(&info, "Frames"), Some("33"));
}

#[test]
fn comfy_video_containers() {
    for name in ["vhs_comment.mp4", "vhs_comment.mov", "comfy_tags.mp4", "comfy_tags.webm"] {
        let info = extract(&fixture_path(name));
        assert_eq!(info.source, "comfyui", "{name}");
        assert_eq!((info.width, info.height), (64, 48), "{name}");
        assert_eq!(info.duration_ms, 1000, "{name}");
        assert_eq!(info.seed, "82628696717253", "{name}");
        assert!(info.prompt.starts_with("a fox moving quickly"), "{name}");
    }
}

#[test]
fn comfy_tolerates_nan() {
    let prompt = r#"{"1":{"class_type":"KSampler","inputs":{"seed":7,"steps":4,"cfg":NaN,"sampler_name":"lcm","scheduler":"normal","denoise":1.0,"positive":["2",0],"negative":["3",0],"model":["4",0],"latent_image":["5",0]}},"2":{"class_type":"CLIPTextEncode","inputs":{"text":"a NaN-proof prompt","clip":["4",1]}},"3":{"class_type":"CLIPTextEncode","inputs":{"text":"","clip":["4",1]}},"4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"sub/dir/dream.safetensors"},"is_changed":NaN},"5":{"class_type":"EmptyLatentImage","inputs":{"width":512,"height":768,"batch_size":4}}}"#;
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("x.png");
    write_png(&path, 1, &[("prompt", prompt)]);
    let info = extract(&path);
    assert_eq!(info.prompt, "a NaN-proof prompt");
    assert_eq!(info.seed, "7");
    assert_eq!(info.model, "sub/dir/dream.safetensors");
    assert_eq!(param(&info, "Batch"), Some("4"));
}

#[test]
fn comfy_linked_text_and_power_lora() {
    // Prompt text supplied by primitive / concat nodes; rgthree-style lora
    // objects; seed supplied by a separate node.
    let prompt = r#"{
      "10":{"class_type":"KSampler","inputs":{"seed":["20",0],"steps":25,"cfg":5.5,"sampler_name":"dpmpp_2m","scheduler":"karras","denoise":1,"positive":["11",0],"negative":["12",0],"model":["30",0],"latent_image":["40",0]}},
      "11":{"class_type":"CLIPTextEncode","inputs":{"text":["13",0],"clip":["30",1]}},
      "12":{"class_type":"CLIPTextEncode","inputs":{"text":["15",0],"clip":["30",1]}},
      "13":{"class_type":"Text Concatenate","inputs":{"delimiter":", ","clean_whitespace":"true","text_a":["14",0],"text_b":"golden hour"}},
      "14":{"class_type":"PrimitiveStringMultiline","inputs":{"value":"a stone bridge over a river"}},
      "15":{"class_type":"PrimitiveString","inputs":{"value":"fog"}},
      "20":{"class_type":"Seed (rgthree)","inputs":{"seed":998877}},
      "30":{"class_type":"Power Lora Loader (rgthree)","inputs":{"PowerLoraLoaderHeaderWidget":{"type":"PowerLoraLoaderHeaderWidget"},"lora_1":{"on":true,"lora":"style/inkwash.safetensors","strength":0.6},"lora_2":{"on":false,"lora":"unused.safetensors","strength":1},"model":["31",0],"clip":["31",1]}},
      "31":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"realvis.safetensors"}},
      "40":{"class_type":"EmptyLatentImage","inputs":{"width":832,"height":1216,"batch_size":1}}
    }"#;
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("x.png");
    write_png(&path, 1, &[("prompt", prompt)]);
    let info = extract(&path);
    assert_eq!(info.prompt, "a stone bridge over a river\n\ngolden hour");
    assert_eq!(info.negative, "fog");
    assert_eq!(info.seed, "998877");
    assert_eq!(info.loras.len(), 1);
    assert_eq!(info.loras[0].name, "style/inkwash.safetensors");
    assert_eq!(info.loras[0].weight, Some(0.6));
    assert_eq!(param(&info, "Size"), Some("832x1216"));
}

#[test]
fn comfy_workflow_only() {
    let workflow = r#"{"last_node_id":3,"nodes":[
      {"id":1,"type":"CheckpointLoaderSimple","widgets_values":["dreamshaper_8.safetensors"]},
      {"id":2,"type":"CLIPTextEncode","title":"Positive","widgets_values":["a paper boat"]},
      {"id":3,"type":"CLIPTextEncode","title":"Negative Prompt","widgets_values":["ugly"]},
      {"id":4,"type":"KSampler","widgets_values":[4242,"fixed",20,7,"euler","normal",1]}],"links":[]}"#;
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("x.png");
    write_png(&path, 1, &[("workflow", workflow)]);
    let info = extract(&path);
    assert_eq!(info.source, "comfyui");
    assert_eq!(info.prompt, "a paper boat");
    assert_eq!(info.negative, "ugly");
    assert_eq!(info.seed, "4242");
    assert_eq!(info.model, "dreamshaper_8.safetensors");
}

#[test]
fn a1111_png_jpeg_and_webp_style_exif() {
    let tmp = tempfile::tempdir().unwrap();
    let png = tmp.path().join("00012-3958203417.png");
    write_png(&png, 4, &[("parameters", A1111_TEXT)]);
    let jpg = tmp.path().join("00012-3958203417.jpg");
    std::fs::write(&jpg, jpeg_with_user_comment(A1111_TEXT)).unwrap();

    for path in [&png, &jpg] {
        let info = extract(path);
        assert_eq!(info.source, "a1111", "{}", path.display());
        assert!(info.prompt.starts_with("cinematic photo of a lighthouse"));
        assert_eq!(info.negative, "cartoon, lowres, text");
        assert_eq!(info.seed, "3958203417");
        assert_eq!(info.model, "sd_xl_base_1.0");
        assert_eq!(info.models[0].hash, "31e35c80fc");
        assert_eq!(info.loras[0].name, "add_detail");
        assert_eq!(info.loras[0].weight, Some(0.7));
        assert_eq!(param(&info, "Sampler"), Some("DPM++ 2M Karras"));
        assert_eq!(param(&info, "Size"), Some("768x1152"));
    }
    assert_eq!((extract(&jpg).width, extract(&jpg).height), (80, 48));
}

#[test]
fn invokeai_png() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("a1b2c3.png");
    write_png(&path, 5, &[("invokeai_metadata", INVOKE_TEXT), ("invokeai_graph", r#"{"id":"g","nodes":{},"edges":[]}"#)]);
    let info = extract(&path);
    assert_eq!(info.source, "invokeai");
    assert_eq!(info.prompt, "an isometric cutaway of a cozy submarine cabin");
    assert_eq!(info.negative, "blurry, people");
    assert_eq!(info.seed, "2718281828");
    assert_eq!(info.model, "Juggernaut XL v9");
    assert_eq!(info.loras[0].name, "cutaway-diagram-xl");
    assert_eq!(info.loras[0].weight, Some(0.85));
    assert_eq!(kinds(&info, "vae"), ["sdxl-vae-fp16-fix"]);
    assert_eq!(param(&info, "Size"), Some("1216x832"));
    assert_eq!(param(&info, "Scheduler"), Some("dpmpp_2m_sde_k"));
    // Identical style prompt is not repeated.
    assert_eq!(param(&info, "Positive style prompt"), None);
    assert!(info.raw.iter().any(|(k, _)| k == "invokeai_graph"));
}

#[test]
fn compressed_and_late_text_chunks() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("late.png");
    std::fs::write(&path, png_with_ztxt_itxt("parameters", A1111_TEXT, "Title", "späte Metadaten ✓")).unwrap();
    let info = extract(&path);
    assert_eq!(info.source, "a1111");
    assert_eq!(info.seed, "3958203417");
    assert!(info.raw.iter().any(|(k, v)| k == "Title" && v == "späte Metadaten ✓"));
}

#[test]
fn plain_and_broken_files_are_harmless() {
    let tmp = tempfile::tempdir().unwrap();
    let plain = tmp.path().join("photo.png");
    write_png(&plain, 6, &[]);
    let info = extract(&plain);
    assert_eq!(info.source, "");
    assert_eq!((info.width, info.height), (96, 64));

    let full = png_with_text(96, 64, 7, &[("parameters", A1111_TEXT)]);
    for cut in [0, 5, 20, 40, 200, full.len() / 2] {
        let path = tmp.path().join(format!("cut{cut}.png"));
        std::fs::write(&path, &full[..cut]).unwrap();
        let _ = extract(&path); // must not panic
    }
    let junk = tmp.path().join("junk.mp4");
    std::fs::write(&junk, [0u8, 0, 0, 1, b'f', b't', b'y', b'p', 9, 9, 9, 9, 0xFF, 0xFF]).unwrap();
    let _ = extract(&junk);
    assert_eq!(extract(&tmp.path().join("missing.png")).source, "");
}
