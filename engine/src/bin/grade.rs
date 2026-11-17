//! Command-line front end for the engine (testing and batch use).
//!
//!   grade apply  <in> <recipe.json|preset-name> <out>
//!   grade auto   <in> <outdir>          # analysis + style candidates
//!   grade presets <in> <outdir>         # every built-in template
//!   grade match  <in> <reference> <out> [strength]

use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use photo_grade_engine::{analysis, apply, io, matching, presets, Recipe};

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("apply") if args.len() == 4 => {
            let img = io::load(&args[1])?;
            let recipe = match presets::by_name(&args[2]) {
                Some(r) => r,
                None => Recipe::from_json(&std::fs::read_to_string(&args[2]).context("read recipe")?)?,
            };
            let out = Path::new(&args[3]);
            io::save(&apply(&recipe, &img), out, io::Format::from_path(out))?;
        }
        Some("auto") if args.len() == 3 => {
            let img = io::load(&args[1])?;
            let dir = PathBuf::from(&args[2]);
            std::fs::create_dir_all(&dir)?;
            let (stats, cands) = analysis::candidates(&img);
            println!("{}", serde_json::to_string_pretty(&stats)?);
            let preview = img.downscale(1200);
            for (i, r) in cands.iter().enumerate() {
                let stem = format!("{:02}_{}", i, r.name.replace(' ', "_"));
                io::save(&apply(r, &preview), dir.join(format!("{stem}.jpg")), io::Format::Jpeg(92))?;
                std::fs::write(dir.join(format!("{stem}.json")), r.to_json())?;
                println!("candidate: {}", r.name);
            }
        }
        Some("presets") if args.len() == 3 => {
            let img = io::load(&args[1])?.downscale(1200);
            let dir = PathBuf::from(&args[2]);
            std::fs::create_dir_all(&dir)?;
            let base = analysis::auto_correct(&analysis::analyze(&img));
            io::save(&apply(&Recipe::default(), &img), dir.join("_원본.jpg"), io::Format::Jpeg(92))?;
            io::save(&apply(&base, &img), dir.join("_자동보정.jpg"), io::Format::Jpeg(92))?;
            let stats = analysis::analyze(&img);
            let adapt = std::env::var("ACG_ADAPT").is_ok();
            for r in presets::all() {
                let r = if adapt {
                    let (r, rep) = photo_grade_engine::adapt::adapt(&r, &base, &stats, &img);
                    println!("{}\t{:.0}%\t{}", r.name, rep.strength * 100.0, rep.notes.join(" / "));
                    r
                } else {
                    base.layered(&r)
                };
                io::save(&apply(&r, &img), dir.join(format!("{}.jpg", r.name.replace(' ', "_"))), io::Format::Jpeg(92))?;
            }
        }
        Some("match") if args.len() >= 4 => {
            let img = io::load(&args[1])?;
            let reference = io::load(&args[2])?;
            let strength: f32 = args.get(4).map(|s| s.parse()).transpose()?.unwrap_or(1.0);
            let src_disp = io::linear_to_display(&img);
            let ref_disp = io::linear_to_display(&reference);
            let recipe = matching::match_reference(&src_disp, &ref_disp, strength);
            let out = Path::new(&args[3]);
            io::save(&apply(&recipe, &img), out, io::Format::from_path(out))?;
            if let Some(lut) = &recipe.lut {
                std::fs::write(out.with_extension("cube"), lut.to_cube("reference match"))?;
            }
        }
        Some("list") => {
            for r in presets::all() {
                println!("{}\t{}\t{}", r.name, r.category, r.description);
            }
        }
        _ => bail!("usage: grade apply|auto|presets|match ... (see source header)"),
    }
    Ok(())
}
