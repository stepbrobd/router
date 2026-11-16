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
    /// Print NixOS options.json for every setting, described from doc/bird.sgml
    Options {
        /// BIRD source tree
        source: PathBuf,
        /// URL the source tree's files are browsable under, ending with a slash
        #[arg(long)]
        source_url: String,
    },
}

fn main() -> anyhow::Result<()> {
    match Cli::parse().command {
        Command::Generate { source, output } => router::generate(&source, &output),
        Command::Options { source, source_url } => {
            let options = router::options(&source, &source_url)?;
            eprintln!(
                "{} of {} settings have no entry in doc/bird.sgml",
                options.undocumented,
                options.options.len()
            );
            let mut stdout = std::io::stdout().lock();
            serde_json::to_writer(&mut stdout, &options.options)?;
            writeln!(stdout)?;
            Ok(())
        }
        Command::Inspect { source } => {
            let mut stdout = std::io::stdout().lock();
            serde_json::to_writer_pretty(&mut stdout, &router::inspect(&source)?)?;
            writeln!(stdout)?;
            Ok(())
        }
    }
}
