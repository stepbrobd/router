use crate::grammar::{Error, Grammar, Location, Production, Rule, Symbol};
use crate::source::Keyword;
use crate::surface::Schema;
use crate::values::{Naming, RecordPart, ValueShape};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::LazyLock;

// Registry vocabularies. Their kebab-case names are the spellings registry/bird.toml and the
// inventory use, so serde rejects an unknown word when the registry loads.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Representation {
    Duration,
    Expression,
    Integer,
    IpAddress,
    NumberExpression,
    Prefix,
    String,
    Switch,
    Symbol,
    TypeName,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Shape {
    Body,
    Constructor,
    Flag,
    List,
    Record,
    // native text with no delimiters of its own, such as a flowspec operator expression
    Text,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Merge {
    Append,
    Fields,
    Replace,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum StorageRole {
    Body,
    Program,
    Semantic,
    Symbol,
    Text,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Definition {
    pub version: u32,
    pub header_field: String,
    pub roles: BTreeMap<String, String>,
    pub storage: BTreeMap<String, StorageRole>,
    pub lexical: BTreeMap<String, Representation>,
    pub families: BTreeMap<String, String>,
    pub channel_kinds: Vec<String>,
    pub c_types: BTreeMap<String, Vec<String>>,
    pub namespaces: Vec<Namespace>,
    pub bindings: Vec<BindingDefinition>,
    pub fields: Vec<FieldDefinition>,
    pub projections: Vec<Projection>,
    pub effects: Vec<EffectDefinition>,
    pub copy_fields: BTreeMap<String, BTreeMap<String, Vec<String>>>,
    pub constructors: Vec<ConstructorDefinition>,
    pub declaration_order: DeclarationOrder,
    #[serde(default)]
    pub labels: Vec<LabelDefinition>,
    #[serde(default)]
    pub exclusions: Vec<ExclusionDefinition>,
}

// Root declarations BIRD must read before the entries that reference them. Entries not named here
// render between the two lists, and includes always come first because BIRD's lexer expands them.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DeclarationOrder {
    pub first: Vec<String>,
    pub last: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Namespace {
    #[serde(default)]
    pub prefix: Vec<String>,
    #[serde(default)]
    pub suffix: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct BindingDefinition {
    pub id: String,
    pub rules: Vec<String>,
    pub file: String,
    pub storage: Option<String>,
    pub representation: Option<Representation>,
    pub label: Option<String>,
    pub shape: Option<Shape>,
    #[serde(default)]
    pub references: Vec<String>,
    #[serde(default)]
    pub classes: Vec<String>,
    #[serde(default)]
    pub values: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub atomic: bool,
    #[serde(default)]
    pub expand: bool,
    #[serde(default)]
    pub fields: BTreeMap<String, String>,
    #[serde(default)]
    pub native_fields: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Projection {
    pub id: String,
    pub scope: Option<String>,
    pub selectors: Vec<Vec<String>>,
    #[serde(default)]
    pub contains: Vec<String>,
    #[serde(default)]
    pub collection: bool,
    pub merge: Merge,
    #[serde(default)]
    pub fields: BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct EffectDefinition {
    scope: String,
    selector: Vec<String>,
    path: Vec<String>,
    target: Option<Vec<String>>,
    #[serde(default)]
    clears: Vec<Vec<String>>,
    storage: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ConstructorDefinition {
    id: String,
    binding: String,
    arguments: Vec<String>,
}

// names for the values of one production that neither a keyword nor a binding label tells apart
// `at` is the value's Bison position, the n of `$n` in the production's C action
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct LabelDefinition {
    id: String,
    rule: String,
    production: Vec<String>,
    fields: Vec<LabelField>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct LabelField {
    at: usize,
    name: String,
    storage: Option<String>,
}

// a grammar rule left out of the settings, such as a directive only BIRD's own test program reads
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ExclusionDefinition {
    rule: String,
    file: String,
    reason: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct FieldDefinition {
    id: String,
    scope: String,
    selector: Vec<String>,
    path: Vec<String>,
    storage: String,
}

#[derive(Debug, Serialize)]
pub struct Field {
    pub scope: String,
    pub syntax: Vec<String>,
    pub path: Vec<String>,
    pub storage: String,
    pub source: Location,
}

#[derive(Debug, Serialize)]
pub struct Label {
    pub rule: String,
    pub production: usize,
    pub source: Location,
    // value names by symbol index within the production
    pub names: BTreeMap<usize, String>,
}

// a label's name for one value slot, serialized as the name alone
#[derive(Clone, Debug, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(transparent)]
pub struct SlotLabel {
    pub name: String,
    #[serde(skip)]
    pub id: String,
}

#[derive(Debug, Serialize)]
pub struct Exclusion {
    pub source: Location,
    pub reason: String,
}

#[derive(Debug, Serialize)]
pub struct Binding {
    pub rule: String,
    pub source: Location,
    pub storage: Option<String>,
    pub c_type: Option<String>,
    pub representation: Option<Representation>,
    pub label: Option<String>,
    pub shape: Option<Shape>,
    pub checked_aliases: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct Protocol {
    pub class: String,
    pub copy_config: bool,
    pub copy_hook: Option<String>,
    pub source: Location,
    pub copy_source: Option<Location>,
    pub reset_paths: Vec<Vec<String>>,
    pub resets: BTreeMap<String, Location>,
    pub channels: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Effect {
    pub scope: String,
    pub path: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub clears: Vec<Vec<String>>,
    pub storage: String,
    pub source: Location,
    pub sources: Vec<Location>,
}

#[derive(Debug, Default, Serialize)]
pub struct Diagnostics {
    pub unaddressable: Vec<String>,
    pub unprojected: Vec<String>,
}

#[derive(Debug, Default, Serialize)]
pub struct Constructor {
    pub forms: Vec<ConstructorForm>,
}

#[derive(Debug, Serialize)]
pub struct ConstructorForm {
    pub rule: String,
    pub arity: usize,
    pub parts: Vec<RecordPart>,
    pub source: Location,
}

#[derive(Debug, Serialize)]
pub struct ProjectionBinding {
    pub scope: String,
    pub value_type: String,
    pub path: Vec<String>,
    pub source: Location,
}

#[derive(Debug, Serialize)]
pub struct Registry {
    pub version: u32,
    pub roles: BTreeMap<String, String>,
    pub bindings: BTreeMap<String, Binding>,
    pub fields: BTreeMap<String, Field>,
    pub projections: BTreeMap<String, Vec<ProjectionBinding>>,
    pub channel_kinds: BTreeSet<String>,
    pub protocols: BTreeMap<String, Protocol>,
    pub effects: Vec<Effect>,
    pub aliases: Vec<Effect>,
    pub constructors: BTreeMap<String, Constructor>,
    pub labels: BTreeMap<String, Label>,
    // excluded grammar rules by name
    pub exclusions: BTreeMap<String, Exclusion>,
    pub declaration_order: DeclarationOrder,
    pub diagnostics: Diagnostics,
    #[serde(skip)]
    pub(crate) definition: &'static Definition,
}

fn error(message: impl Into<String>) -> Error {
    Error::in_file("registry/bird.toml", message)
}

pub(crate) fn definition() -> &'static Definition {
    static DEFINITION: LazyLock<Definition> = LazyLock::new(|| {
        toml::from_str(include_str!("../registry/bird.toml"))
            .expect("embedded BIRD registry must be valid TOML")
    });
    &DEFINITION
}

pub(crate) fn storage_role(tag: &str) -> Option<StorageRole> {
    definition().storage.get(tag).copied()
}

pub(crate) fn role_field(role: &str) -> String {
    definition()
        .roles
        .get(role)
        .expect("native role must have a registry label")
        .clone()
}

pub(crate) fn fixed<'a>(
    grammar: &Grammar,
    spellings: &'a BTreeMap<String, String>,
    symbol: &'a Symbol,
) -> Option<&'a str> {
    match symbol {
        Symbol::Literal(text) => Some(text),
        Symbol::Reference(name) => {
            if let Some(spelling) = spellings.get(name) {
                return Some(spelling);
            }
            if !grammar.tokens.contains_key(name) {
                return None;
            }
            (name == "END").then_some("")
        }
    }
}

pub(crate) fn spellings(grammar: &Grammar, keywords: &[Keyword]) -> BTreeMap<String, String> {
    keywords
        .iter()
        .filter(|keyword| grammar.tokens.contains_key(&keyword.token))
        .map(|keyword| (keyword.token.clone(), keyword.spelling.clone()))
        .collect()
}

// a binding's field names, or else the rule's own name
pub(crate) fn fallback_name(rule: &str, fields: &BTreeMap<String, String>) -> (String, Naming) {
    fields.get(rule).map_or_else(
        || (rule.replace('_', "-"), Naming::Fallback),
        |name| (name.clone(), Naming::Registry),
    )
}

pub(crate) fn canonical_path(prefix: &[String], named: bool) -> Vec<String> {
    if prefix.is_empty() {
        return Vec::new();
    }
    if named {
        for namespace in &definition().namespaces {
            if !namespace.prefix.is_empty() && prefix.starts_with(&namespace.prefix) {
                return prefix.to_vec();
            }
            if !namespace.suffix.is_empty() && prefix.ends_with(&namespace.suffix) {
                let family = &prefix[..prefix.len() - namespace.suffix.len()];
                let mut path = Vec::with_capacity(namespace.suffix.len() + 1);
                if !family.is_empty() {
                    path.push(family.join("-"));
                }
                path.extend_from_slice(&namespace.suffix);
                return path;
            }
        }
    }
    vec![prefix.join("-")]
}

fn semantic_types(grammar: &Grammar) -> BTreeMap<String, String> {
    let tokens = c_tokens(&grammar.semantic_storage);
    let mut result = BTreeMap::new();
    let mut start = 0;
    for (index, token) in tokens.iter().enumerate() {
        if token.text != ";" {
            continue;
        }
        let member = &tokens[start..index];
        if let Some((name, c_type)) = member.split_last() {
            let c_type = c_type
                .iter()
                .filter(|token| token.text != "{")
                .map(|token| token.text)
                .collect::<Vec<_>>()
                .join(" ");
            result.insert(name.text.to_owned(), c_type);
        }
        start = index + 1;
    }
    result
}

// Bison numbers mid-rule actions like symbols, so `$n` of symbol i counts the actions before it
fn bison_positions(production: &Production) -> Vec<usize> {
    let mut position = 0;
    (0..production.symbols.len())
        .map(|index| {
            position += production
                .actions
                .iter()
                .filter(|action| action.position == index)
                .count()
                + 1;
            position
        })
        .collect()
}

fn resolve_label(grammar: &Grammar, label: &LabelDefinition) -> Result<Label, Error> {
    let fail = |message: String| error(format!("label {}: {message}", label.id));
    let rule = grammar
        .rules
        .get(&label.rule)
        .ok_or_else(|| fail(format!("no grammar rule {}", label.rule)))?;
    let candidates = rule
        .productions
        .iter()
        .enumerate()
        .filter(|(_, production)| {
            production
                .symbols
                .iter()
                .map(|symbol| match symbol {
                    Symbol::Reference(name) => name.clone(),
                    Symbol::Literal(text) => format!("'{text}'"),
                })
                .eq(label.production.iter().cloned())
        })
        .collect::<Vec<_>>();
    let [(number, production)] = candidates.as_slice() else {
        return Err(fail(format!(
            "{} has {} productions {:?}",
            label.rule,
            candidates.len(),
            label.production
        )));
    };
    let positions = bison_positions(production);
    let mut names = BTreeMap::new();
    for field in &label.fields {
        let index = positions
            .iter()
            .position(|position| *position == field.at)
            .ok_or_else(|| fail(format!("${} is not a grammar symbol", field.at)))?;
        let Symbol::Reference(name) = &production.symbols[index] else {
            return Err(fail(format!("${} is a literal", field.at)));
        };
        let value = grammar
            .rules
            .get(name)
            .map(|rule| rule.storage_type.is_some())
            .or_else(|| {
                grammar
                    .tokens
                    .get(name)
                    .map(|token| token.storage_type.is_some())
            });
        if value != Some(true) {
            return Err(fail(format!(
                "${} ({name}) carries no semantic value",
                field.at
            )));
        }
        if let Some(storage) = &field.storage
            && !production.actions.iter().any(|action| {
                action
                    .assignments
                    .iter()
                    .any(|(lhs, position)| lhs == storage && *position == field.at)
            })
        {
            return Err(fail(format!(
                "source does not assign ${} to {storage}",
                field.at
            )));
        }
        if names.values().any(|existing| existing == &field.name)
            || names.insert(index, field.name.clone()).is_some()
        {
            return Err(fail(format!(
                "duplicate field {} or position ${}",
                field.name, field.at
            )));
        }
    }
    Ok(Label {
        rule: label.rule.clone(),
        production: *number,
        source: production.source.clone(),
        names,
    })
}

// dropping an exclusion must remove nothing else, so every use of the rule is a whole alternative
fn resolve_exclusion(
    grammar: &Grammar,
    exclusion: &ExclusionDefinition,
) -> Result<Exclusion, Error> {
    let fail = |message: String| error(format!("exclusion {}: {message}", exclusion.rule));
    let rule = grammar
        .rules
        .get(&exclusion.rule)
        .ok_or_else(|| fail("no grammar rule has this name".into()))?;
    if rule.source.file != exclusion.file {
        return Err(fail(format!(
            "defined in {}, expected {}",
            rule.source.file, exclusion.file
        )));
    }
    let reference = Symbol::Reference(exclusion.rule.clone());
    let mut alternatives = 0;
    for (name, parent) in &grammar.rules {
        if name == &exclusion.rule {
            continue;
        }
        for production in &parent.productions {
            if !production.symbols.contains(&reference) {
                continue;
            }
            if production.symbols.len() != 1 {
                return Err(fail(format!(
                    "{name} uses it inside a longer production at {}:{}",
                    production.source.file, production.source.line
                )));
            }
            alternatives += 1;
        }
    }
    if alternatives == 0 {
        return Err(fail("no rule offers it as an alternative".into()));
    }
    Ok(Exclusion {
        source: rule.source.clone(),
        reason: exclusion.reason.clone(),
    })
}

fn select_binding<'a>(
    grammar: &'a Grammar,
    binding: &BindingDefinition,
) -> Result<(&'a str, &'a Rule), Error> {
    let candidates = binding
        .rules
        .iter()
        .filter_map(|name| {
            grammar
                .rules
                .get_key_value(name)
                .map(|(name, rule)| (name.as_str(), rule))
        })
        .collect::<Vec<_>>();
    let [(name, rule)] = candidates.as_slice() else {
        return Err(error(format!(
            "required binding {} must match exactly one of {:?}, found {}",
            binding.id,
            binding.rules,
            candidates.len()
        )));
    };
    if rule.source.file != binding.file || rule.storage_type != binding.storage {
        return Err(error(format!(
            "stale binding {}: {} is {}:{} with storage {:?}, expected file {} and storage {:?}",
            binding.id,
            name,
            rule.source.file,
            rule.source.line,
            rule.storage_type,
            binding.file,
            binding.storage
        )));
    }
    Ok((*name, *rule))
}

impl Registry {
    pub fn resolve(
        grammar: &Grammar,
        keywords: &[Keyword],
        facts: &BTreeMap<String, String>,
    ) -> Result<Self, Error> {
        let definition = definition();
        let spellings = spellings(grammar, keywords);
        let semantic_types = semantic_types(grammar);
        for tag in definition.families.keys() {
            let actual = semantic_types
                .get(tag)
                .ok_or_else(|| error(format!("missing lexical C storage alias {tag}")))?;
            if !definition
                .c_types
                .get(tag)
                .is_some_and(|accepted| accepted.contains(actual))
            {
                return Err(error(format!(
                    "incompatible lexical C storage alias {tag}: {actual}"
                )));
            }
        }
        let mut bindings = BTreeMap::new();
        for binding in &definition.bindings {
            if bindings.contains_key(&binding.id) {
                return Err(error(format!("duplicate stable identity {}", binding.id)));
            }
            let (name, rule) = select_binding(grammar, binding)?;
            let c_type = if let Some(tag) = &binding.storage {
                let actual = semantic_types.get(tag).ok_or_else(|| {
                    error(format!(
                        "missing C semantic storage alias {tag} for {}",
                        binding.id
                    ))
                })?;
                let accepted = definition.c_types.get(tag).ok_or_else(|| {
                    error(format!(
                        "missing centralized C storage constraint for {tag}"
                    ))
                })?;
                if !accepted.contains(actual) {
                    return Err(error(format!(
                        "incompatible C storage for {}: {tag} is {actual}, expected {accepted:?}",
                        binding.id
                    )));
                }
                Some(actual.clone())
            } else {
                None
            };
            for class in &binding.classes {
                if !rule
                    .productions
                    .iter()
                    .flat_map(|production| &production.actions)
                    .any(|action| action.symbol_classes.contains(class))
                {
                    return Err(error(format!(
                        "stale binding {}: missing source symbol class {class}",
                        binding.id
                    )));
                }
            }
            for (label, tokens) in &binding.values {
                if !rule.productions.iter().any(|production| {
                    production
                        .symbols
                        .iter()
                        .map(|symbol| fixed(grammar, &spellings, symbol).map(str::to_owned))
                        .collect::<Option<Vec<_>>>()
                        .as_ref()
                        == Some(tokens)
                }) {
                    return Err(error(format!(
                        "stale literal alias {}.{label}: source has no {tokens:?} production",
                        binding.id
                    )));
                }
            }
            for reference in &binding.references {
                if !rule.productions.iter().any(|production| {
                    production
                        .symbols
                        .contains(&Symbol::Reference(reference.clone()))
                }) {
                    return Err(error(format!(
                        "stale binding {}: {} no longer references {reference}",
                        binding.id, name
                    )));
                }
            }
            bindings.insert(
                binding.id.clone(),
                Binding {
                    rule: name.to_owned(),
                    source: rule.source.clone(),
                    storage: rule.storage_type.clone(),
                    c_type,
                    representation: binding.representation,
                    label: binding.label.clone(),
                    shape: binding.shape,
                    checked_aliases: binding.rules.clone(),
                },
            );
        }
        for binding in &definition.bindings {
            for id in &binding.native_fields {
                if !bindings.get(id).is_some_and(|binding| {
                    binding
                        .storage
                        .as_deref()
                        .is_some_and(|tag| storage_role(tag) == Some(StorageRole::Program))
                }) {
                    return Err(error(format!(
                        "native slot {} requires an executable source expression binding {id}",
                        binding.id
                    )));
                }
            }
        }
        let mut registry = Self {
            version: definition.version,
            roles: definition.roles.clone(),
            bindings,
            protocols: BTreeMap::new(),
            effects: Vec::new(),
            aliases: Vec::new(),
            constructors: BTreeMap::new(),
            labels: BTreeMap::new(),
            exclusions: BTreeMap::new(),
            declaration_order: definition.declaration_order.clone(),
            diagnostics: Diagnostics::default(),
            definition,
            fields: BTreeMap::new(),
            channel_kinds: BTreeSet::new(),
            projections: BTreeMap::new(),
        };
        for field in &definition.fields {
            let name = registry.rule(&field.scope)?.to_owned();
            let productions = grammar.rules[&name].productions.iter().filter(|production| {
                let symbols = if matches!(production.symbols.first(), Some(Symbol::Reference(reference)) if reference == &name) { &production.symbols[1..] } else { &production.symbols };
                let prefix = symbols.iter().map_while(|symbol| fixed(grammar, &spellings, symbol)).map(str::to_owned).collect::<Vec<_>>();
                prefix == field.selector && production.actions.iter().any(|action| action.storage.contains(&field.storage))
            }).collect::<Vec<_>>();
            let [production] = productions.as_slice() else {
                return Err(error(format!(
                    "field {} requires one source assignment to {}, found {}",
                    field.id,
                    field.storage,
                    productions.len()
                )));
            };
            if registry
                .fields
                .insert(
                    field.id.clone(),
                    Field {
                        scope: format!("{name}[]"),
                        syntax: field.selector.clone(),
                        path: field.path.clone(),
                        storage: field.storage.clone(),
                        source: production.source.clone(),
                    },
                )
                .is_some()
            {
                return Err(error(format!(
                    "duplicate stable field identity {}",
                    field.id
                )));
            }
        }
        for id in &definition.channel_kinds {
            let name = registry.rule(id)?.to_owned();
            for production in &grammar.rules[&name].productions {
                let tokens = production
                    .symbols
                    .iter()
                    .map(|symbol| fixed(grammar, &spellings, symbol).map(str::to_owned))
                    .collect::<Option<Vec<_>>>()
                    .ok_or_else(|| error(format!("unsupported channel kind syntax in {id}")))?;
                registry.channel_kinds.insert(tokens.join("-"));
            }
        }
        for effect in &definition.effects {
            let name = registry.rule(&effect.scope)?;
            let rule = &grammar.rules[name];
            let mut sources = Vec::new();
            for production in &rule.productions {
                let symbols = if matches!(production.symbols.first(), Some(Symbol::Reference(reference)) if reference == name)
                {
                    &production.symbols[1..]
                } else {
                    &production.symbols
                };
                let prefix = symbols
                    .iter()
                    .map_while(|symbol| fixed(grammar, &spellings, symbol))
                    .map(str::to_owned)
                    .collect::<Vec<_>>();
                if prefix.starts_with(&effect.selector)
                    && production
                        .actions
                        .iter()
                        .any(|action| action.storage.contains(&effect.storage))
                {
                    sources.push(production.source.clone());
                }
            }
            let Some(source) = sources.first().cloned() else {
                return Err(error(format!(
                    "stale effect for {} {:?}: no source production assigns {}",
                    effect.scope, effect.selector, effect.storage
                )));
            };
            let resolved = Effect {
                scope: format!("{name}[]"),
                path: effect.path.clone(),
                target: effect.target.clone(),
                clears: effect.clears.clone(),
                storage: effect.storage.clone(),
                source,
                sources,
            };
            if resolved
                .target
                .as_ref()
                .is_some_and(|target| target != &resolved.path)
            {
                registry.aliases.push(resolved.clone());
            }
            registry.effects.push(resolved);
        }
        for constructor in &definition.constructors {
            let rule = registry.rule(&constructor.binding)?.to_owned();
            let arguments = constructor
                .arguments
                .iter()
                .map(|id| registry.rule(id).map(str::to_owned))
                .collect::<Result<Vec<_>, _>>()?;
            let candidates = grammar.rules[&rule]
                .productions
                .iter()
                .filter(|production| {
                    production
                        .symbols
                        .iter()
                        .filter(|symbol| fixed(grammar, &spellings, symbol).is_none())
                        .map(|symbol| match symbol {
                            Symbol::Reference(name) => name,
                            Symbol::Literal(_) => unreachable!(),
                        })
                        .eq(arguments.iter())
                })
                .collect::<Vec<_>>();
            let [production] = candidates.as_slice() else {
                return Err(error(format!(
                    "constructor {} has {} matching source productions",
                    constructor.id,
                    candidates.len()
                )));
            };
            let mut index = 0;
            let parts = production
                .symbols
                .iter()
                .map(|symbol| {
                    if let Some(text) = fixed(grammar, &spellings, symbol) {
                        RecordPart::Literal { text: text.into() }
                    } else {
                        let Symbol::Reference(rule) = symbol else {
                            unreachable!()
                        };
                        let name = index.to_string();
                        index += 1;
                        RecordPart::Field {
                            name,
                            rule: rule.clone(),
                            optional: false,
                            naming: Naming::Registry,
                        }
                    }
                })
                .collect();
            registry
                .constructors
                .entry(constructor.id.clone())
                .or_default()
                .forms
                .push(ConstructorForm {
                    rule: rule.clone(),
                    arity: arguments.len(),
                    parts,
                    source: production.source.clone(),
                });
        }
        for label in &definition.labels {
            let resolved = resolve_label(grammar, label)?;
            if registry
                .labels
                .values()
                .any(|other| other.rule == resolved.rule && other.production == resolved.production)
            {
                return Err(error(format!(
                    "label {} names a production another label already names",
                    label.id
                )));
            }
            if registry.labels.insert(label.id.clone(), resolved).is_some() {
                return Err(error(format!(
                    "duplicate stable label identity {}",
                    label.id
                )));
            }
        }
        for exclusion in &definition.exclusions {
            let resolved = resolve_exclusion(grammar, exclusion)?;
            if registry
                .exclusions
                .insert(exclusion.rule.clone(), resolved)
                .is_some()
            {
                return Err(error(format!("duplicate exclusion {}", exclusion.rule)));
            }
        }
        registry.protocols = protocol_facts(facts, &definition.copy_fields)?;
        Ok(registry)
    }

    pub(crate) fn slot_label(
        &self,
        rule: &str,
        production: usize,
        symbol: usize,
    ) -> Option<SlotLabel> {
        let (id, label) = self
            .labels
            .iter()
            .find(|(_, label)| label.rule == rule && label.production == production)?;
        label.names.get(&symbol).map(|name| SlotLabel {
            name: name.clone(),
            id: id.clone(),
        })
    }

    pub(crate) fn rule(&self, id: &str) -> Result<&str, Error> {
        self.bindings
            .get(id)
            .map(|binding| binding.rule.as_str())
            .ok_or_else(|| error(format!("unknown stable binding {id}")))
    }

    pub(crate) fn binding(&self, rule: &str) -> Option<&BindingDefinition> {
        self.definition.bindings.iter().find(|binding| {
            self.bindings
                .get(&binding.id)
                .is_some_and(|resolved| resolved.rule == rule)
        })
    }

    pub(crate) fn label(&self, rule: &str, fields: &BTreeMap<String, String>) -> (String, Naming) {
        if let Some(binding) = self.binding(rule)
            && let Some(label) = fields.get(&binding.id).or(binding.label.as_ref())
        {
            return (label.clone(), Naming::Registry);
        }
        fallback_name(rule, fields)
    }

    pub fn complete(&mut self, grammar: &Grammar, schema: &Schema) -> Result<(), Error> {
        for definition in &self.definition.bindings {
            let binding = &self.bindings[&definition.id];
            let shape = &schema.value_types[&binding.rule];
            if let Some(expected) = definition.representation
                && !matches!(shape, ValueShape::Primitive { representation, .. } if *representation == expected)
            {
                return Err(error(format!(
                    "stale binding {}: source no longer supports its {expected:?} representation",
                    definition.id
                )));
            }
            let compatible = match definition.shape {
                Some(Shape::List) => matches!(shape, ValueShape::List { .. }),
                Some(Shape::Body) => {
                    matches!(shape, ValueShape::Body { roles, .. } if roles.iter().any(|role| matches!(role, crate::surface::DeclarationRole::Body { prefix, .. } if !prefix.is_empty())))
                }
                Some(Shape::Flag) => {
                    matches!(shape, ValueShape::Enum { values, .. } if values.contains_key("true"))
                }
                Some(Shape::Constructor) => matches!(shape, ValueShape::Constructor { .. }),
                Some(Shape::Text) => {
                    matches!(shape, ValueShape::Body { roles, .. } if matches!(roles.as_slice(), [crate::surface::DeclarationRole::Body { prefix, suffix, .. }] if prefix.is_empty() && suffix.is_empty()))
                }
                Some(Shape::Record) => matches!(
                    shape,
                    ValueShape::Record { .. } | ValueShape::Choice { .. } | ValueShape::Enum { .. }
                ),
                None => true,
            };
            if !compatible {
                return Err(error(format!(
                    "stale binding {}: source no longer has its required {:?} shape",
                    definition.id, definition.shape
                )));
            }
        }
        for projection in &self.definition.projections {
            let prefix = format!("$projection:{}:", projection.id);
            let mut bindings = Vec::new();
            for (scope, forms) in &schema.scopes {
                for form in forms {
                    if let Some(value_type) = form.parts.iter().find_map(|part| match part {
                        crate::surface::Part::Value { rule, .. } if rule.starts_with(&prefix) => {
                            Some(rule)
                        }
                        _ => None,
                    }) {
                        let source_rule = scope.strip_suffix("[]").unwrap_or(scope);
                        let source = grammar.rules.get(source_rule).ok_or_else(|| {
                            error(format!(
                                "projection {} has no source scope {scope}",
                                projection.id
                            ))
                        })?;
                        bindings.push(ProjectionBinding {
                            scope: scope.clone(),
                            value_type: value_type.clone(),
                            path: form.path.clone(),
                            source: source.source.clone(),
                        });
                    }
                }
            }
            if bindings.is_empty() {
                return Err(error(format!(
                    "required projection {} matches no readable source forms",
                    projection.id
                )));
            }
            self.projections.insert(projection.id.clone(), bindings);
        }
        for (name, token) in &grammar.tokens {
            if token.configuration_reachable
                && token.storage_type.is_some()
                && matches!(schema.value_types.get(name), Some(ValueShape::Exact { .. }))
                && fixed(grammar, &BTreeMap::new(), &Symbol::Reference(name.clone())).is_none()
            {
                return Err(error(format!(
                    "reachable lexical token {name} has no source-bound data representation"
                )));
            }
        }
        let mut kinds = BTreeSet::new();
        for form in &schema.scopes[&schema.root] {
            let protocol_header = form.parts.iter().any(|part| matches!(part, crate::surface::Part::Value { rule, .. } if rule == &self.bindings["protocol.header"].rule));
            if protocol_header && form.header.is_none() {
                return Err(error(
                    "required protocol header binding is ambiguous or has an unsupported source shape",
                ));
            }
            if !protocol_header || form.path.len() < 2 {
                continue;
            }
            let kind = &form.path[1];
            if !self.protocols.contains_key(kind) {
                return Err(error(format!(
                    "protocol {kind} has no unambiguous C class definition"
                )));
            }
            kinds.insert(kind.clone());
            if let Some(scope) = form.parts.iter().find_map(|part| match part {
                crate::surface::Part::Block { scope } => Some(scope),
                _ => None,
            }) {
                let channels = schema.scopes[scope]
                    .iter()
                    .filter(|channel| {
                        channel
                            .parts
                            .iter()
                            .any(|part| matches!(part, crate::surface::Part::Block { .. }))
                    })
                    .filter(|channel| channel.path.len() == 1)
                    .filter(|channel| self.channel_kinds.contains(&channel.path[0]))
                    .filter_map(|channel| channel.path.first().cloned())
                    .collect::<BTreeSet<_>>();
                self.protocols.get_mut(kind).unwrap().channels = channels.into_iter().collect();
            }
        }
        self.protocols.retain(|kind, _| kinds.contains(kind));
        let roots = schema.scopes[&schema.root]
            .iter()
            .filter_map(|form| form.path.first())
            .collect::<BTreeSet<_>>();
        for name in self
            .declaration_order
            .first
            .iter()
            .chain(&self.declaration_order.last)
        {
            if !roots.contains(name) {
                return Err(error(format!(
                    "stale declaration order entry {name}: no root setting has that path"
                )));
            }
        }
        self.diagnostics.unaddressable = crate::values::unaddressable(grammar, schema);
        self.diagnostics.unprojected = schema
            .value_types
            .keys()
            .filter(|rule| {
                !self.bindings.values().any(|binding| &binding.rule == *rule)
                    && !rule.starts_with('$')
            })
            .cloned()
            .collect();
        Ok(())
    }
}

#[derive(Clone, Copy, Debug)]
struct CToken<'a> {
    text: &'a str,
    line: usize,
    quoted: bool,
}

fn c_tokens(text: &str) -> Vec<CToken<'_>> {
    let bytes = text.as_bytes();
    let mut tokens = Vec::new();
    let mut index = 0;
    let mut line = 1;
    while index < bytes.len() {
        if bytes[index].is_ascii_whitespace() {
            if bytes[index] == b'\n' {
                line += 1;
            }
            index += 1;
            continue;
        }
        if bytes[index..].starts_with(b"/*") {
            index += 2;
            while index < bytes.len() && !bytes[index..].starts_with(b"*/") {
                if bytes[index] == b'\n' {
                    line += 1;
                }
                index += 1;
            }
            index = (index + 2).min(bytes.len());
            continue;
        }
        if bytes[index..].starts_with(b"//") {
            while index < bytes.len() && bytes[index] != b'\n' {
                index += 1;
            }
            continue;
        }
        let start = index;
        let token_line = line;
        let quoted = matches!(bytes[index], b'\'' | b'"');
        if quoted {
            let quote = bytes[index];
            index += 1;
            while index < bytes.len() {
                if bytes[index] == b'\n' {
                    line += 1;
                }
                if bytes[index] == b'\\' {
                    index = (index + 2).min(bytes.len());
                } else {
                    let end = bytes[index] == quote;
                    index += 1;
                    if end {
                        break;
                    }
                }
            }
        } else if bytes[index].is_ascii_alphanumeric() || bytes[index] == b'_' {
            index += 1;
            while index < bytes.len()
                && (bytes[index].is_ascii_alphanumeric() || bytes[index] == b'_')
            {
                index += 1;
            }
        } else if bytes[index..].starts_with(b"->") {
            index += 2;
        } else {
            index += 1;
        }
        tokens.push(CToken {
            text: &text[start..index],
            line: token_line,
            quoted,
        });
    }
    tokens
}

fn closing(tokens: &[CToken<'_>], start: usize, open: &str, close: &str) -> Option<usize> {
    let mut depth = 0;
    for (index, token) in tokens.iter().enumerate().skip(start) {
        if token.quoted {
            continue;
        }
        if token.text == open {
            depth += 1;
        }
        if token.text == close {
            depth -= 1;
            if depth == 0 {
                return Some(index);
            }
        }
    }
    None
}

fn member<'a, 'source>(tokens: &'a [CToken<'source>], name: &str) -> Option<&'a CToken<'source>> {
    tokens
        .windows(4)
        .find(|window| window[0].text == "." && window[1].text == name && window[2].text == "=")
        .map(|window| &window[3])
}

fn function<'a, 'source>(
    files: &'a BTreeMap<&'source str, Vec<CToken<'source>>>,
    name: &str,
) -> Result<(&'a [CToken<'source>], &'a [CToken<'source>], Location), Error> {
    let mut matches = Vec::new();
    for (file, tokens) in files {
        for index in 0..tokens.len().saturating_sub(1) {
            if tokens[index].quoted || tokens[index].text != name || tokens[index + 1].text != "(" {
                continue;
            }
            let Some(end) = closing(tokens, index + 1, "(", ")") else {
                continue;
            };
            if tokens.get(end + 1).is_none_or(|token| token.text != "{") {
                continue;
            }
            let Some(close) = closing(tokens, end + 1, "{", "}") else {
                continue;
            };
            matches.push((
                &tokens[index + 2..end],
                &tokens[end + 2..close],
                Location {
                    file: (*file).to_owned(),
                    line: tokens[index].line,
                },
            ));
        }
    }
    if matches.len() != 1 {
        return Err(error(format!(
            "copy hook {name} must have one C definition, found {}",
            matches.len()
        )));
    }
    Ok(matches.pop().unwrap())
}

fn source_aliases<'source>(
    parameters: &[CToken<'source>],
    body: &[CToken<'source>],
) -> Result<BTreeSet<&'source str>, Error> {
    let parameter = parameters
        .split(|token| token.text == ",")
        .nth(1)
        .and_then(|parameter| {
            parameter
                .windows(2)
                .find(|pair| pair[0].text == "*")
                .map(|pair| pair[1].text)
        })
        .ok_or_else(|| error("copy hook lacks an identifiable source pointer parameter"))?;
    let identifier = |name: &str| {
        name.bytes()
            .next()
            .is_some_and(|byte| byte.is_ascii_alphabetic() || byte == b'_')
            && name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
    };
    let mut aliases = BTreeSet::from([parameter]);
    loop {
        let mut changed = false;
        for (index, token) in body.iter().enumerate().skip(1) {
            if token.text != "=" || !identifier(body[index - 1].text) {
                continue;
            }
            if index > 1 && matches!(body[index - 2].text, "->" | ".") {
                continue;
            }
            if index > 1
                && body[index - 2].text == "*"
                && (index < 3 || !identifier(body[index - 3].text))
            {
                continue;
            }
            let rhs = body[index + 1..]
                .split(|token| token.text == ";")
                .next()
                .unwrap_or(&[]);
            if rhs.iter().any(|token| aliases.contains(token.text)) {
                changed |= aliases.insert(body[index - 1].text);
            }
        }
        if !changed {
            return Ok(aliases);
        }
    }
}

fn protocol_facts(
    facts: &BTreeMap<String, String>,
    labels: &BTreeMap<String, BTreeMap<String, Vec<String>>>,
) -> Result<BTreeMap<String, Protocol>, Error> {
    let files = facts
        .iter()
        .filter(|(path, _)| path.ends_with(".c"))
        .map(|(path, text)| (path.as_str(), c_tokens(text)))
        .collect::<BTreeMap<_, _>>();
    let mut result = BTreeMap::new();
    for (file, tokens) in &files {
        for index in 0..tokens.len().saturating_sub(4) {
            if tokens[index].text != "struct"
                || tokens[index + 1].text != "protocol"
                || tokens[index + 3].text != "="
                || tokens[index + 4].text != "{"
            {
                continue;
            }
            let end = closing(tokens, index + 4, "{", "}")
                .ok_or_else(|| error(format!("unclosed C protocol initializer in {file}")))?;
            let fields = &tokens[index + 5..end];
            let Some(template) = member(fields, "template").filter(|token| token.quoted) else {
                continue;
            };
            let kind = template
                .text
                .trim_matches('"')
                .split('%')
                .next()
                .unwrap_or("")
                .to_owned();
            if kind.is_empty() {
                return Err(error(format!("empty C protocol template in {file}")));
            }
            let hook = member(fields, "copy_config")
                .filter(|token| !matches!(token.text, "NULL" | "0"))
                .map(|token| token.text.to_owned());
            let mut resets = BTreeMap::new();
            let mut reset_paths = Vec::new();
            let copy_source = if let Some(hook) = &hook {
                let (parameters, body, source) = function(&files, hook)?;
                let aliases = source_aliases(parameters, body)?;
                let mut reset_fields = BTreeMap::new();
                for window in body.windows(7) {
                    if window[0].text == "init_list"
                        && window[1].text == "("
                        && window[2].text == "&"
                        && window[4].text == "->"
                        && window[6].text == ")"
                    {
                        reset_fields.insert(window[5].text, window[0].line);
                    }
                }
                for (position, window) in body.windows(4).enumerate() {
                    if window[1].text != "->" || window[3].text != "=" {
                        continue;
                    }
                    let rhs = body[position + 4..]
                        .split(|token| token.text == ";")
                        .next()
                        .unwrap_or(&[]);
                    if rhs
                        .windows(2)
                        .any(|pair| pair[0].text == "{" && pair[1].text == "}")
                    {
                        reset_fields.insert(window[2].text, window[0].line);
                    }
                }
                for (field, line) in reset_fields {
                    if body.windows(3).any(|window| {
                        aliases.contains(window[0].text)
                            && window[1].text == "->"
                            && window[2].text == field
                    }) {
                        continue;
                    }
                    let path = labels.get(&kind).and_then(|labels| labels.get(field)).ok_or_else(|| error(format!("copy hook {hook} resets unmapped source field {field}, add a source-checked public slot label")))?;
                    reset_paths.push(path.clone());
                    resets.insert(
                        field.to_owned(),
                        Location {
                            file: source.file.clone(),
                            line,
                        },
                    );
                }
                Some(source)
            } else {
                None
            };
            reset_paths.sort();
            let protocol = Protocol {
                class: tokens[index + 2].text.to_owned(),
                copy_config: hook.is_some(),
                copy_hook: hook,
                source: Location {
                    file: (*file).to_owned(),
                    line: tokens[index].line,
                },
                copy_source,
                reset_paths,
                resets,
                channels: Vec::new(),
            };
            if result.insert(kind.clone(), protocol).is_some() {
                return Err(error(format!("ambiguous C protocol identity {kind}")));
            }
        }
    }
    for (kind, fields) in labels {
        let protocol = result
            .get(kind)
            .ok_or_else(|| error(format!("stale copy-field binding: no C protocol {kind}")))?;
        for field in fields.keys() {
            if !protocol.resets.contains_key(field) {
                return Err(error(format!(
                    "stale copy-field binding {kind}.{field}: source hook no longer resets it"
                )));
            }
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn label(fields: Vec<(usize, &str, Option<&str>)>) -> LabelDefinition {
        LabelDefinition {
            id: "cork".into(),
            rule: "opt".into(),
            production: ["CORK", "expr", "expr", "';'"].map(String::from).to_vec(),
            fields: fields
                .into_iter()
                .map(|(at, name, storage)| LabelField {
                    at,
                    name: name.into(),
                    storage: storage.map(String::from),
                })
                .collect(),
        }
    }

    #[test]
    fn labels_name_values_by_bison_position_and_check_their_storage() {
        let grammar = crate::grammar::parse("%union { int i; }\n%token END CORK\n%token <i> NUM\n%type <i> expr\n%start config\n%%\nconfig: opt END;\nopt: CORK { mid(); } expr expr ';' { cfg->low = $3; cfg->high = $4; };\nexpr: NUM;\n%%").unwrap();
        let resolved = resolve_label(
            &grammar,
            &label(vec![(3, "low", Some("cfg->low")), (4, "high", None)]),
        )
        .unwrap();
        assert_eq!(
            resolved.names,
            BTreeMap::from([(1, "low".to_owned()), (2, "high".to_owned())])
        );
        let swapped = resolve_label(&grammar, &label(vec![(4, "low", Some("cfg->low"))]));
        assert!(swapped.unwrap_err().message.contains("does not assign $4"));
        let keyword = resolve_label(&grammar, &label(vec![(1, "cork", None)]));
        assert!(
            keyword
                .unwrap_err()
                .message
                .contains("carries no semantic value")
        );
        let action = resolve_label(&grammar, &label(vec![(2, "mid", None)]));
        assert!(
            action
                .unwrap_err()
                .message
                .contains("is not a grammar symbol")
        );
    }

    #[test]
    fn exclusions_must_be_whole_alternatives_in_their_source_file() {
        let grammar = |conf: &str| {
            crate::grammar::parse(&format!("#line 1 \"test.Y\"\n%token END X PROBE\n%start config\n%%\nconfig: entries END; entries: | entries conf;\n{conf}\nprobe: PROBE ';';\n%%")).unwrap()
        };
        let exclusion = |rule: &str, file: &str| -> ExclusionDefinition {
            toml::from_str(&format!(
                "rule='{rule}'\nfile='{file}'\nreason='only a test program reads it'\n"
            ))
            .unwrap()
        };
        let alternative = grammar("conf: X ';' | probe;");
        let resolved = resolve_exclusion(&alternative, &exclusion("probe", "test.Y")).unwrap();
        assert_eq!(resolved.source.file, "test.Y");
        assert_eq!(resolved.reason, "only a test program reads it");
        let moved = resolve_exclusion(&alternative, &exclusion("probe", "other.Y")).unwrap_err();
        assert!(moved.message.contains("exclusion probe"));
        assert!(moved.message.contains("test.Y"));
        let absent = resolve_exclusion(&alternative, &exclusion("absent", "test.Y")).unwrap_err();
        assert!(absent.message.contains("no grammar rule"));
        let embedded = resolve_exclusion(&grammar("conf: X probe;"), &exclusion("probe", "test.Y"))
            .unwrap_err();
        assert!(embedded.message.contains("inside a longer production"));
        let start = resolve_exclusion(&alternative, &exclusion("config", "test.Y")).unwrap_err();
        assert!(
            start.message.contains("no rule offers it"),
            "{}",
            start.message
        );
    }

    #[test]
    fn c_comments_and_literals_cannot_invent_copy_hooks() {
        let text = "/* struct protocol fake = { .template = \"fake%d\", .copy_config = bad }; */\nconst char *s = \".copy_config = bad\";\nstruct protocol p = { .template = \"plain%d\" };";
        let facts = BTreeMap::from([("proto/test.c".into(), text.into())]);
        let protocols = protocol_facts(&facts, &BTreeMap::new()).unwrap();
        assert!(!protocols["plain"].copy_config);
        assert!(!protocols.contains_key("fake"));
    }

    #[test]
    fn stable_bindings_reject_ambiguous_renamed_aliases() {
        let grammar = crate::grammar::parse("#line 1 \"test.Y\"\n%union { int i; }\n%token END WORD\n%type <i> old new\n%start config\n%%\nconfig: old new END; old: WORD; new: WORD;\n%%").unwrap();
        let binding =
            toml::from_str("id='stable.value'\nrules=['old','new']\nfile='test.Y'\nstorage='i'\n")
                .unwrap();
        let failure = select_binding(&grammar, &binding).unwrap_err();
        assert!(failure.message.contains("stable.value"));
        assert!(failure.message.contains("exactly one"));
    }

    #[test]
    fn stable_bindings_accept_one_renamed_alias_but_reject_stale_storage() {
        let grammar = crate::grammar::parse("#line 1 \"test.Y\"\n%union { int i; }\n%token END WORD\n%type <i> new\n%start config\n%%\nconfig: new END; new: WORD;\n%%").unwrap();
        let mut binding =
            toml::from_str("id='stable.value'\nrules=['old','new']\nfile='test.Y'\nstorage='i'\n")
                .unwrap();
        assert_eq!(select_binding(&grammar, &binding).unwrap().0, "new");
        binding.storage = Some("s".into());
        assert!(
            select_binding(&grammar, &binding)
                .unwrap_err()
                .message
                .contains("stale binding stable.value")
        );
        binding.storage = Some("i".into());
        binding.rules = vec!["absent".into()];
        assert!(
            select_binding(&grammar, &binding)
                .unwrap_err()
                .message
                .contains("stable.value")
        );
    }
    #[test]
    fn reconstructed_lists_and_renamed_source_aliases_are_not_copy_resets() {
        let facts = BTreeMap::from([("proto/test.c".into(), "void cp(struct proto_config *dest, struct proto_config *src) { struct config *d = (void *) dest; struct config *parent = (void *) src; init_list(&d->routes); WALK_LIST(r, parent->routes) add_tail(&d->routes, r); init_list(&d->patterns); } struct protocol p = { .template = \"demo%d\", .copy_config = cp };".into())]);
        let labels = BTreeMap::from([(
            "demo".into(),
            BTreeMap::from([("patterns".into(), vec!["interface".into()])]),
        )]);
        let protocols = protocol_facts(&facts, &labels).unwrap();
        assert_eq!(protocols["demo"].reset_paths, vec![vec!["interface"]]);
        assert!(!protocols["demo"].resets.contains_key("routes"));
    }
}
