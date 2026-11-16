pub mod grammar;
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
    let grammar = grammar::parse(&assembly.parser)?;
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

pub fn generate(source: &Path, output: &Path) -> anyhow::Result<()> {
    let inventory = inspect(source)?;
    fs::create_dir_all(output).with_context(|| format!("cannot create {}", output.display()))?;
    let path = output.join("grammar.json");
    fs::write(&path, serde_json::to_string_pretty(&inventory)? + "\n")
        .with_context(|| format!("cannot write {}", path.display()))
}
