//! Builds `Features.bin`; the logic lives in `mimundo_core::datagen::features`.
//!
//! Usage: featuregen <rivers_lake_centerlines> <lakes> <geography_regions_polys>
//!                   <geography_regions_elevation_points> <out Features.bin>

use std::process::ExitCode;

use mimundo_core::datagen::features::run;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 6 {
        eprintln!(
            "usage: featuregen <rivers> <lakes> <regions_polys> <elevation_points> <out Features.bin>"
        );
        return ExitCode::from(2);
    }
    match run(&args[1], &args[2], &args[3], &args[4], &args[5]) {
        Ok(summary) => {
            println!("{summary}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("featuregen: {e}");
            ExitCode::FAILURE
        }
    }
}
