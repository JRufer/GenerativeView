//! Print the extracted generation info for each file given on the command line.
use std::path::Path;

fn main() {
    let brief = std::env::args().any(|a| a == "--brief");
    for arg in std::env::args().skip(1).filter(|a| !a.starts_with("--")) {
        let info = gvcore::meta::extract(Path::new(&arg));
        if brief {
            println!(
                "{arg}\n  src={} {}x{} dur={} seed={} model={} loras={:?}\n  models={:?}\n  params={:?}\n  +: {:?}\n  -: {:?}",
                info.source, info.width, info.height, info.duration_ms, info.seed, info.model,
                info.loras.iter().map(|l| format!("{}@{:?}", l.name, l.weight)).collect::<Vec<_>>(),
                info.models.iter().map(|m| format!("{}:{}", m.kind, m.name)).collect::<Vec<_>>(),
                info.params,
                info.prompt.chars().take(140).collect::<String>(),
                info.negative.chars().take(80).collect::<String>(),
            );
        } else {
            let mut info = info;
            for r in info.raw.iter_mut() {
                if r.1.len() > 200 {
                    r.1 = format!("{}… ({} bytes)", r.1.chars().take(200).collect::<String>(), r.1.len());
                }
            }
            println!("{}", serde_json::to_string_pretty(&info).unwrap());
        }
    }
}
