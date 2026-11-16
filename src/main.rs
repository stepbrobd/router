use clap::{Parser, Subcommand};
use std::io::Write;
use std::path::PathBuf;

/// Compile the Linux configuration grammar selected by a BIRD source tree's build manifests.
///
/// GNU m4 must be on PATH or selected with M4.
#[derive(Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Write grammar.json for a BIRD source tree
    Generate {
        /// BIRD source tree
        source: PathBuf,
        /// Directory that receives grammar.json
        #[arg(long)]
        output: PathBuf,
    },
    /// Print the grammar inventory of a BIRD source tree as JSON
    Inspect {
        /// BIRD source tree
        source: PathBuf,
    },
}

fn main() -> anyhow::Result<()> {
    match Cli::parse().command {
        Command::Generate { source, output } => router::generate(&source, &output),
        Command::Inspect { source } => {
            let mut stdout = std::io::stdout().lock();
            serde_json::to_writer_pretty(&mut stdout, &router::inspect(&source)?)?;
            writeln!(stdout)?;
            Ok(())
        }
    }
}
