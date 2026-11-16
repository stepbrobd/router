pub mod grammar;
pub mod options;
pub mod registry;
pub mod source;
pub mod surface;
pub mod values;

use anyhow::Context;
use serde::Serialize;
use std::fs;
use std::path::Path;

#[derive(Debug, Serialize)]
pub struct Inventory {
    pub format_version: u32,
    pub compiler_version: &'static str,
    pub source: source::Source,
    pub grammar: grammar::Grammar,
    pub keywords: Vec<source::Keyword>,
    pub lexer_include: source::Include,
    pub schema: surface::Schema,
    pub registry: registry::Registry,
}

pub fn inspect(source: &Path) -> Result<Inventory, grammar::Error> {
    let assembly = source::read(source)?;
    let lexed = |token: &str| {
        assembly.lexer_words.contains(token)
            || assembly
                .keywords
                .iter()
                .any(|keyword| keyword.token == token)
    };
    let grammar = grammar::parse_lexed(&assembly.parser, &lexed)?;
    let mut registry = registry::Registry::resolve(&grammar, &assembly.keywords, &assembly.facts)?;
    let schema = surface::compile_with_registry(&grammar, &assembly.keywords, &registry);
    registry.complete(&grammar, &schema)?;
    Ok(Inventory {
        format_version: 2,
        compiler_version: env!("CARGO_PKG_VERSION"),
        source: assembly.source,
        grammar,
        keywords: assembly.keywords,
        lexer_include: assembly.include,
        schema,
        registry,
    })
}

// every setting must have an attribute form, so a BIRD bump that adds one without needs a registry change
pub fn generate(source: &Path, output: &Path) -> anyhow::Result<()> {
    let inventory = inspect(source)?;
    let unaddressable = &inventory.registry.diagnostics.unaddressable;
    if !unaddressable.is_empty() {
        anyhow::bail!(
            "{} setting forms cannot be written as attributes, name their values in registry/bird.toml:\n{}",
            unaddressable.len(),
            unaddressable.join("\n")
        );
    }
    fs::create_dir_all(output).with_context(|| format!("cannot create {}", output.display()))?;
    let path = output.join("grammar.json");
    fs::write(&path, serde_json::to_string_pretty(&inventory)? + "\n")
        .with_context(|| format!("cannot write {}", path.display()))
}

// NixOS options.json for every setting, with descriptions from the BIRD source's doc/bird.sgml
pub fn options(source: &Path, source_url: &str) -> anyhow::Result<options::Options> {
    let inventory = inspect(source)?;
    let manual = source.join("doc/bird.sgml");
    let manual =
        fs::read_to_string(&manual).with_context(|| format!("cannot read {}", manual.display()))?;
    Ok(options::options(&inventory, &manual, source_url))
}
