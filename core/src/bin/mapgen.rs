//! Builds `World.bin`; the logic lives in `mimundo_core::datagen::world`.
//!
//! Usage: mapgen <ne_110m_admin_0_countries.geojson> <ne_50m_admin_0_countries.geojson> <out World.bin>

use std::process::ExitCode;

use mimundo_core::datagen::world::run;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: mapgen <ne_110m.geojson> <ne_50m.geojson> <out World.bin>");
        return ExitCode::from(2);
    }
    match run(&args[1], &args[2], &args[3]) {
        Ok(summary) => {
            println!("{summary}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("mapgen: {e}");
            ExitCode::FAILURE
        }
    }
}
