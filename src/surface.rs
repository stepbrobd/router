use crate::grammar::{Grammar, Production, Symbol};
use crate::registry::{self, Registry, StorageRole};
use crate::source::Keyword;
use crate::values::ValueShape;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Part {
    Literal {
        text: String,
    },
    Value {
        rule: String,
        value_kind: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        value_type: Option<String>,
        // registry name of the production slot that produced this value
        #[serde(skip_serializing_if = "Option::is_none")]
        label: Option<String>,
    },
    Body {
        rule: String,
    },
    Declaration {
        rule: String,
        production: usize,
        native_rule: String,
        roles: Vec<DeclarationRole>,
    },
    Options {
        scope: String,
    },
    Block {
        scope: String,
    },
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ParameterPart {
    Literal { text: String },
    Name { rule: String },
    Type { rule: String },
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(tag = "role", rename_all = "snake_case")]
pub enum DeclarationRole {
    Args {
        rule: String,
        field: String,
        prefix: Vec<String>,
        suffix: Vec<String>,
        separator: Vec<String>,
        parts: Vec<ParameterPart>,
        empty: Option<Vec<String>>,
    },
    Return {
        rule: String,
        field: String,
        value_rule: String,
        prefix: Vec<String>,
        suffix: Vec<String>,
    },
    Variables {
        field: String,
        rule: String,
    },
    Body {
        rule: String,
        field: String,
        prefix: Vec<String>,
        suffix: Vec<String>,
    },
}

#[derive(Debug, Serialize)]
pub struct NativeDeclaration {
    pub prefix: Vec<String>,
    pub lines: Vec<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct Form {
    pub parts: Vec<Part>,
    pub path: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header: Option<Header>,
    // the first value after the keywords names the entry even without a block after it
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub named: bool,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct Header {
    pub name_rule: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from_rule: Option<String>,
    pub from_prefix: Vec<String>,
    pub field: String,
    pub modifiers: Vec<HeaderModifier>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct HeaderModifier {
    pub field: String,
    pub parts: Vec<String>,
}
#[derive(Debug, Serialize)]
pub struct Schema {
    pub root: String,
    pub scopes: BTreeMap<String, Vec<Form>>,
    pub native_declarations: Vec<NativeDeclaration>,
    pub value_rules: BTreeMap<String, String>,
    pub native_rules: Vec<String>,
    pub program_rules: BTreeSet<String>,
    pub value_types: BTreeMap<String, ValueShape>,
}

struct Compiler<'a> {
    grammar: &'a Grammar,
    spellings: BTreeMap<String, String>,
    scopes: BTreeMap<String, Vec<Form>>,
    active: BTreeSet<String>,
    registry: Option<&'a Registry>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Parameters {
    parts: Vec<ParameterPart>,
    separator: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ArgumentSyntax {
    prefix: Vec<String>,
    suffix: Vec<String>,
    parameters: Parameters,
    empty: Option<Vec<String>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct AnnotationSyntax {
    rule: String,
    prefix: Vec<String>,
    suffix: Vec<String>,
}

struct BodySyntax {
    variables: Option<String>,
    rule: String,
    prefix: Vec<String>,
    suffix: Vec<String>,
}

fn literal(text: impl Into<String>) -> Part {
    Part::Literal { text: text.into() }
}
fn value(rule: &str, kind: &str) -> Part {
    Part::Value {
        rule: rule.into(),
        value_kind: kind.into(),
        value_type: None,
        label: None,
    }
}

// a production slot of `rule`: production number and the index of its first symbol
type Origin<'b> = Option<(&'b str, usize, usize)>;

impl<'a> Compiler<'a> {
    fn native(&self, name: &str) -> bool {
        self.grammar
            .rules
            .get(name)
            .and_then(|rule| rule.storage_type.as_deref())
            .is_some_and(|tag| registry::storage_role(tag) == Some(StorageRole::Body))
    }

    fn pure_keywords(&self, name: &str, visited: &mut BTreeSet<String>) -> bool {
        if self.spellings.contains_key(name) {
            return true;
        }
        if !visited.insert(name.into()) {
            return false;
        }
        let result = self.grammar.rules.get(name).is_some_and(|rule| {
            !rule.productions.is_empty()
                && rule.productions.iter().all(|production| {
                    production.symbols.iter().all(|symbol| match symbol {
                        Symbol::Literal(_) => true,
                        Symbol::Reference(name) => self.pure_keywords(name, visited),
                    })
                })
        });
        visited.remove(name);
        result
    }

    fn atomic(&self, name: &str) -> Option<Part> {
        if self.native(name) {
            return Some(Part::Body { rule: name.into() });
        }
        if self
            .registry
            .is_some_and(|registry| registry.bindings["protocol.header"].rule == name)
        {
            return Some(value(name, "symbol"));
        }
        if self
            .registry
            .and_then(|registry| registry.binding(name))
            .is_some_and(|binding| binding.atomic)
        {
            return Some(value(name, "typed"));
        }
        let rule = self.grammar.rules.get(name)?;
        let tag = rule.storage_type.as_deref()?;
        if self.pure_keywords(name, &mut BTreeSet::new()) {
            return None;
        }
        let storage = &self.grammar.semantic_storage;
        match registry::storage_role(tag) {
            Some(StorageRole::Symbol) => Some(value(name, "symbol")),
            Some(StorageRole::Text) => Some(value(name, "text")),
            Some(StorageRole::Semantic) => Some(value(name, "semantic")),
            Some(StorageRole::Program) if storage.contains("struct f_") => {
                Some(value(name, "semantic"))
            }
            _ => None,
        }
    }

    fn fixed<'b>(&'b self, symbol: &'b Symbol) -> Option<&'b str> {
        registry::fixed(self.grammar, &self.spellings, symbol)
    }

    fn symbol_name(&self, name: &str) -> bool {
        self.grammar
            .rules
            .get(name)
            .and_then(|rule| rule.storage_type.as_deref())
            .or_else(|| {
                self.grammar
                    .tokens
                    .get(name)
                    .and_then(|token| token.storage_type.as_deref())
            })
            .is_some_and(|tag| registry::storage_role(tag) == Some(StorageRole::Symbol))
    }

    fn unaliased<'b>(&'b self, mut name: &'b str) -> Option<(&'b str, &'b [Production])> {
        let mut visited = BTreeSet::new();
        loop {
            if !visited.insert(name) {
                return None;
            }
            let productions = &self.grammar.rules.get(name)?.productions;
            if let [production] = productions.as_slice()
                && let [Symbol::Reference(reference)] = production.symbols.as_slice()
                && self.grammar.rules.contains_key(reference)
            {
                name = reference;
                continue;
            }
            return Some((name, productions));
        }
    }

    fn nullable<'b>(&'b self, name: &'b str, visited: &mut BTreeSet<&'b str>) -> bool {
        if !visited.insert(name) {
            return false;
        }
        let result = self.grammar.rules.get(name).is_some_and(|rule| {
            rule.productions.iter().any(|production| {
                production.symbols.iter().all(|symbol| match symbol {
                    Symbol::Reference(reference) => self.nullable(reference, visited),
                    Symbol::Literal(_) => false,
                })
            })
        });
        visited.remove(name);
        result
    }

    fn tuple_parts<'b>(
        &'b self,
        symbols: &'b [Symbol],
        visited: &mut BTreeSet<&'b str>,
        parts: &mut Vec<ParameterPart>,
    ) -> Option<()> {
        for symbol in symbols {
            if let Some(text) = self.fixed(symbol) {
                if !text.is_empty() {
                    parts.push(ParameterPart::Literal { text: text.into() });
                }
                continue;
            }
            let Symbol::Reference(name) = symbol else {
                return None;
            };
            if self.symbol_name(name) {
                parts.push(ParameterPart::Name { rule: name.clone() });
            } else {
                let rule = self.grammar.rules.get(name)?;
                if rule.storage_type.is_none() && rule.productions.len() == 1 {
                    if !visited.insert(name) {
                        return None;
                    }
                    self.tuple_parts(&rule.productions[0].symbols, visited, parts)?;
                    visited.remove(name.as_str());
                } else {
                    parts.push(ParameterPart::Type { rule: name.clone() });
                }
            }
        }
        Some(())
    }

    fn parameter_parts(&self, symbols: &[Symbol]) -> Option<Vec<ParameterPart>> {
        let mut parts = Vec::new();
        self.tuple_parts(symbols, &mut BTreeSet::new(), &mut parts)?;
        if parts
            .iter()
            .filter(|part| matches!(part, ParameterPart::Name { .. }))
            .count()
            != 1
            || parts
                .iter()
                .filter(|part| matches!(part, ParameterPart::Type { .. }))
                .count()
                != 1
        {
            return None;
        }
        Some(parts)
    }

    fn repeated_parameters(
        &self,
        name: &str,
        item: &[ParameterPart],
        empty_base: bool,
    ) -> Option<(Vec<String>, bool)> {
        let (name, productions) = self.unaliased(name)?;
        let mut syntax = None;
        let mut bases = 0;
        for production in productions {
            let symbols = &production.symbols;
            let repeated = if matches!(symbols.first(), Some(Symbol::Reference(reference)) if reference == name)
            {
                Some((&symbols[1..], true))
            } else if matches!(symbols.last(), Some(Symbol::Reference(reference)) if reference == name)
            {
                Some((&symbols[..symbols.len() - 1], false))
            } else {
                None
            };
            let Some((chunk, left_recursive)) = repeated else {
                if !symbols.is_empty()
                    && (empty_base || self.parameter_parts(symbols)?.as_slice() != item)
                {
                    return None;
                }
                bases += 1;
                continue;
            };
            let parts = self.parameter_parts(chunk)?;
            let (separator, before) = if parts.len() > item.len() && parts.starts_with(item) {
                (&parts[item.len()..], false)
            } else if parts.len() > item.len() && parts.ends_with(item) {
                (&parts[..parts.len() - item.len()], true)
            } else {
                return None;
            };
            if !empty_base && before != left_recursive {
                return None;
            }
            let separator = separator
                .iter()
                .map(|part| match part {
                    ParameterPart::Literal { text } => Some(text.clone()),
                    _ => None,
                })
                .collect::<Option<Vec<_>>>()?;
            let candidate = (separator, empty_base && before);
            if syntax.as_ref().is_some_and(|syntax| syntax != &candidate) {
                return None;
            }
            syntax = Some(candidate);
        }
        if bases == 0 {
            return None;
        }
        syntax
    }

    fn separated_parameters(&self, name: &str) -> Option<Parameters> {
        let (name, productions) = self.unaliased(name)?;
        let base = productions.iter().find(|production| {
            !production.symbols.is_empty()
                && !matches!(production.symbols.first(), Some(Symbol::Reference(reference)) if reference == name)
                && !matches!(production.symbols.last(), Some(Symbol::Reference(reference)) if reference == name)
        })?;
        let parts = self.parameter_parts(&base.symbols)?;
        let (separator, _) = self.repeated_parameters(name, &parts, false)?;
        Some(Parameters { parts, separator })
    }

    fn parameters(&self, symbols: &[Symbol]) -> Option<Parameters> {
        if let [Symbol::Reference(name)] = symbols
            && let Some(parameters) = self.separated_parameters(name)
        {
            return Some(parameters);
        }
        if let Some(Symbol::Reference(name)) = symbols.first()
            && let Some(parts) = self.parameter_parts(&symbols[1..])
            && let Some((separator, false)) = self.repeated_parameters(name, &parts, true)
        {
            return Some(Parameters { parts, separator });
        }
        if let Some(Symbol::Reference(name)) = symbols.last()
            && let Some(parts) = self.parameter_parts(&symbols[..symbols.len() - 1])
            && let Some((separator, true)) = self.repeated_parameters(name, &parts, true)
        {
            return Some(Parameters { parts, separator });
        }
        None
    }

    fn argument_syntax(&self, name: &str) -> Option<ArgumentSyntax> {
        let (_, productions) = self.unaliased(name)?;
        let empty = productions.iter().find_map(|production| {
            production
                .symbols
                .iter()
                .map(|symbol| self.fixed(symbol).map(str::to_owned))
                .collect::<Option<Vec<_>>>()
        });
        let mut syntax = None;
        for production in productions {
            let symbols = &production.symbols;
            if symbols.is_empty() {
                continue;
            }
            if symbols.len() < 2
                || self.fixed(&symbols[0]) != Some("(")
                || self.fixed(symbols.last()?) != Some(")")
            {
                return None;
            }
            if symbols.len() == 2 {
                continue;
            }
            let candidate = ArgumentSyntax {
                prefix: vec![self.fixed(&symbols[0])?.into()],
                suffix: vec![self.fixed(symbols.last()?)?.into()],
                parameters: self.parameters(&symbols[1..symbols.len() - 1])?,
                empty: empty.clone(),
            };
            if syntax.as_ref().is_some_and(|syntax| syntax != &candidate) {
                return None;
            }
            syntax = Some(candidate);
        }
        syntax
    }

    fn annotation_syntax(&self, name: &str) -> Option<AnnotationSyntax> {
        let (_, productions) = self.unaliased(name)?;
        if !productions
            .iter()
            .any(|production| production.symbols.is_empty())
        {
            return None;
        }
        let mut syntax = None;
        for production in productions {
            if production.symbols.is_empty() {
                continue;
            }
            let index = production
                .symbols
                .iter()
                .position(|symbol| self.fixed(symbol).is_none())?;
            let Symbol::Reference(rule) = &production.symbols[index] else {
                return None;
            };
            if self.symbol_name(rule) || !self.grammar.rules.contains_key(rule) {
                return None;
            }
            let prefix = production.symbols[..index]
                .iter()
                .map(|symbol| self.fixed(symbol).map(str::to_owned))
                .collect::<Option<Vec<_>>>()?;
            let suffix = production.symbols[index + 1..]
                .iter()
                .map(|symbol| self.fixed(symbol).map(str::to_owned))
                .collect::<Option<Vec<_>>>()?;
            if prefix.is_empty()
                || prefix
                    .iter()
                    .chain(&suffix)
                    .any(|text| matches!(text.as_str(), "(" | ")" | "{" | "}"))
            {
                return None;
            }
            let candidate = AnnotationSyntax {
                rule: rule.clone(),
                prefix,
                suffix,
            };
            if syntax.as_ref().is_some_and(|syntax| syntax != &candidate) {
                return None;
            }
            syntax = Some(candidate);
        }
        syntax
    }

    fn body_syntax(&self, name: &str) -> Option<BodySyntax> {
        let (_, productions) = self.unaliased(name)?;
        let [production] = productions else {
            return None;
        };
        let (variables, symbols) = match production.symbols.as_slice() {
            [Symbol::Reference(variables), rest @ ..]
                if self.nullable(variables, &mut BTreeSet::new()) =>
            {
                (Some(variables.clone()), rest)
            }
            symbols => (None, symbols),
        };
        let [open, Symbol::Reference(rule), close] = symbols else {
            return None;
        };
        if self.fixed(open) != Some("{") || self.fixed(close) != Some("}") {
            return None;
        }
        Some(BodySyntax {
            variables,
            rule: rule.clone(),
            prefix: vec![self.fixed(open)?.into()],
            suffix: vec![self.fixed(close)?.into()],
        })
    }

    fn symbol(&mut self, symbol: &Symbol) -> Vec<Vec<Part>> {
        match symbol {
            Symbol::Literal(text) => vec![vec![literal(text)]],
            Symbol::Reference(name) => {
                if let Some(text) = self.fixed(symbol) {
                    return vec![vec![literal(text)]];
                }
                if self.grammar.tokens.contains_key(name) {
                    return vec![vec![value(
                        name,
                        if self.symbol_name(name) {
                            "symbol"
                        } else {
                            "semantic"
                        },
                    )]];
                }
                self.rule(name)
            }
        }
    }

    fn sequence(&mut self, symbols: &[Symbol], origin: Origin<'_>) -> Vec<Vec<Part>> {
        let mut forms = vec![Vec::new()];
        for (index, symbol) in symbols.iter().enumerate() {
            let mut choices = self.symbol(symbol);
            // values a nested production made carry that production's label already
            if let Some((rule, number, offset)) = origin
                && let Some(name) = self
                    .registry
                    .and_then(|registry| registry.slot_label(rule, number, offset + index))
            {
                for part in choices.iter_mut().flatten() {
                    if let Part::Value {
                        label: label @ None,
                        ..
                    } = part
                    {
                        *label = Some(name.to_owned());
                    }
                }
            }
            let mut next = Vec::with_capacity(forms.len() * choices.len());
            for prefix in &forms {
                for choice in &choices {
                    let mut parts = Vec::with_capacity(prefix.len() + choice.len());
                    parts.extend_from_slice(prefix);
                    parts.extend_from_slice(choice);
                    next.push(parts);
                }
            }
            forms = next;
        }
        forms
    }

    fn declaration(
        &mut self,
        name: &str,
        number: usize,
        production: &Production,
    ) -> Option<Vec<Vec<Part>>> {
        let Symbol::Reference(body) = production.symbols.last()? else {
            return None;
        };
        if !self.native(body) {
            return None;
        }
        let syntax = self.body_syntax(body)?;
        let index = production.symbols.iter().position(|symbol| {
            self.fixed(symbol).is_none()
                && matches!(symbol, Symbol::Reference(name) if self.symbol_name(name))
        })?;
        if index == 0 || index + 1 == production.symbols.len() {
            return None;
        }
        let Symbol::Reference(symbol) = &production.symbols[index] else {
            return None;
        };
        let mut roles = Vec::new();
        for part in &production.symbols[index + 1..production.symbols.len() - 1] {
            let Symbol::Reference(rule) = part else {
                return None;
            };
            if let Some(syntax) = self.argument_syntax(rule) {
                if roles
                    .iter()
                    .any(|role| matches!(role, DeclarationRole::Args { .. }))
                {
                    return None;
                }
                roles.push(DeclarationRole::Args {
                    field: registry::role_field("args"),
                    rule: rule.clone(),
                    prefix: syntax.prefix,
                    suffix: syntax.suffix,
                    separator: syntax.parameters.separator,
                    parts: syntax.parameters.parts,
                    empty: syntax.empty,
                });
            } else {
                let syntax = self.annotation_syntax(rule)?;
                if roles
                    .iter()
                    .any(|role| matches!(role, DeclarationRole::Return { .. }))
                {
                    return None;
                }
                roles.push(DeclarationRole::Return {
                    field: registry::role_field("return"),
                    rule: rule.clone(),
                    value_rule: syntax.rule,
                    prefix: syntax.prefix,
                    suffix: syntax.suffix,
                });
            }
        }
        if let Some(rule) = syntax.variables {
            roles.push(DeclarationRole::Variables {
                field: registry::role_field("variables"),
                rule,
            });
        }
        roles.push(DeclarationRole::Body {
            field: registry::role_field("body"),
            rule: syntax.rule,
            prefix: syntax.prefix,
            suffix: syntax.suffix,
        });
        let declaration = Part::Declaration {
            rule: name.into(),
            production: number,
            native_rule: body.clone(),
            roles,
        };
        let mut forms = self.sequence(&production.symbols[..index], None);
        if forms.iter().any(|form| {
            form.iter()
                .any(|part| !matches!(part, Part::Literal { .. }))
        }) {
            return None;
        }
        for form in &mut forms {
            form.push(value(symbol, "symbol"));
            form.push(declaration.clone());
        }
        Some(forms)
    }

    // `X: item | X ',' item` is a list value, not a block of statements
    fn separated_list(&self, name: &str) -> bool {
        let productions = &self.grammar.rules[name].productions;
        let (recursive, base): (Vec<_>, Vec<_>) = productions.iter().partition(|production| {
            matches!(production.symbols.first(), Some(Symbol::Reference(reference)) if reference == name)
        });
        let [item] = base.as_slice() else {
            return false;
        };
        !recursive.is_empty()
            && recursive.iter().all(|production| {
                let tail = &production.symbols[1..];
                tail.len() > item.symbols.len()
                    && tail.ends_with(&item.symbols)
                    && tail[..tail.len() - item.symbols.len()]
                        .iter()
                        .all(|symbol| matches!(symbol, Symbol::Literal(_)))
            })
    }

    fn rule(&mut self, name: &str) -> Vec<Vec<Part>> {
        if let Some(part) = self.atomic(name) {
            return vec![vec![part]];
        }
        if self.separated_list(name) {
            return vec![vec![value(name, "typed")]];
        }
        if !self.active.insert(name.into()) {
            // Indirect or mixed recursion remains explicitly grammar-shaped, never raw source.
            return vec![vec![value(name, "positional")]];
        }
        let grammar = self.grammar;
        let productions = &grammar.rules[name].productions;
        let mut base = Vec::new();
        let mut items = Vec::new();
        let mut left = Vec::new();
        let mut right = Vec::new();
        for (number, production) in productions.iter().enumerate() {
            if matches!(production.symbols.first(), Some(Symbol::Reference(reference)) if reference == name)
            {
                left.push((number, 1, &production.symbols[1..]));
            } else if matches!(production.symbols.last(), Some(Symbol::Reference(reference)) if reference == name)
            {
                right.push((
                    number,
                    0,
                    &production.symbols[..production.symbols.len() - 1],
                ));
            } else {
                items.push(production.symbols.as_slice());
                base.extend(
                    self.declaration(name, number, production)
                        .unwrap_or_else(|| {
                            self.sequence(&production.symbols, Some((name, number, 0)))
                        }),
                );
            }
        }
        if !left.is_empty() || !right.is_empty() {
            if !left.is_empty() && !right.is_empty() {
                self.active.remove(name);
                return vec![vec![value(name, "positional")]];
            }
            let scope = format!("{name}[]");
            self.scopes.entry(scope.clone()).or_default();
            let mut forms = Vec::new();
            for (number, offset, symbols) in left.iter().chain(&right) {
                let origin = Some((name, *number, *offset));
                forms.extend(
                    self.sequence(symbols, origin)
                        .into_iter()
                        .map(|parts| Form {
                            path: Vec::new(),
                            header: None,
                            named: false,
                            parts: fold_blocks(parts),
                        }),
                );
            }
            dedup(&mut forms);
            self.scopes.insert(scope.clone(), forms);
            let options = Part::Options { scope };
            for form in &mut base {
                if right.is_empty() {
                    form.push(options.clone());
                } else {
                    form.insert(0, options.clone());
                }
            }
            // in a pure repetition such as `X: Y | X Y` the scope alone can hold every item, the first included
            if right.is_empty()
                && left.iter().all(|(_, _, tail)| items.contains(tail))
                && items
                    .iter()
                    .all(|item| left.iter().any(|(_, _, tail)| tail == item))
            {
                base.push(vec![options]);
            }
        }
        self.active.remove(name);
        base
    }
}

fn fold_blocks(parts: Vec<Part>) -> Vec<Part> {
    let mut result = Vec::new();
    let mut iter = parts
        .into_iter()
        .filter(|part| !matches!(part, Part::Literal { text } if text.is_empty()))
        .peekable();
    while let Some(part) = iter.next() {
        if part == literal("{")
            && let Some(Part::Options { scope }) = iter.peek()
        {
            let scope = scope.clone();
            iter.next();
            if iter.peek() == Some(&literal("}")) {
                iter.next();
                result.push(Part::Block { scope });
                continue;
            }
            result.push(part);
            result.push(Part::Options { scope });
            continue;
        }
        result.push(part);
    }
    result
}

fn dedup(forms: &mut Vec<Form>) {
    let mut seen = BTreeSet::new();
    forms.retain(|form| seen.insert(form.clone()));
}

fn compile_syntax(grammar: &Grammar, keywords: &[Keyword], registry: Option<&Registry>) -> Schema {
    let spellings = keywords
        .iter()
        .filter(|keyword| grammar.tokens.contains_key(&keyword.token))
        .map(|keyword| (keyword.token.clone(), keyword.spelling.clone()))
        .collect();
    let mut compiler = Compiler {
        grammar,
        spellings,
        scopes: BTreeMap::new(),
        active: BTreeSet::new(),
        registry,
    };
    let mut root = compiler
        .rule(&grammar.configuration_start)
        .into_iter()
        .map(|parts| Form {
            path: Vec::new(),
            header: None,
            named: false,
            parts: fold_blocks(parts),
        })
        .collect::<Vec<_>>();
    // The start is normally an empty-based repetition of conf. Expose the item scope directly.
    let root_name = if let [Form { parts, .. }] = root.as_slice() {
        if let [Part::Options { scope }] = parts.as_slice() {
            scope.clone()
        } else {
            "$configuration".into()
        }
    } else {
        "$configuration".into()
    };
    if root_name == "$configuration" {
        root = root
            .into_iter()
            .flat_map(|form| {
                if let [Part::Options { scope }] = form.parts.as_slice() {
                    compiler.scopes[scope].clone()
                } else {
                    vec![form]
                }
            })
            .collect();
        dedup(&mut root);
        compiler.scopes.insert(root_name.clone(), root);
    }
    let native_declarations = compiler.scopes.get(&root_name).into_iter().flatten().filter_map(|form| {
        let index = form.parts.iter().position(|part| matches!(part, Part::Declaration { .. }))?;
        if index == 0 || !matches!(form.parts.get(index - 1), Some(Part::Value { value_kind, .. }) if value_kind == "symbol") { return None; }
        let prefix = form.parts[..index - 1].iter().map(|part| match part { Part::Literal { text } => Some(text.clone()), _ => None }).collect::<Option<Vec<_>>>()?;
        let Part::Declaration { roles, .. } = &form.parts[index] else { return None; };
        let lines = roles.iter().filter_map(|role| match role {
            DeclarationRole::Variables { field, .. } | DeclarationRole::Body { field, .. } => Some(field.clone()),
            _ => None,
        }).collect();
        Some(NativeDeclaration { prefix, lines })
    }).collect();
    let mut value_rules: BTreeMap<String, String> = grammar
        .rules
        .keys()
        .filter_map(|name| match compiler.atomic(name) {
            Some(Part::Value { value_kind, .. }) => Some((name.clone(), value_kind)),
            _ => None,
        })
        .collect();
    let native_rules = grammar
        .rules
        .keys()
        .filter(|name| compiler.native(name))
        .cloned()
        .collect();
    let mut program_rules = grammar
        .rules
        .iter()
        .filter(|(_, rule)| {
            rule.storage_type.as_deref().is_some_and(|tag| {
                matches!(
                    registry::storage_role(tag),
                    Some(StorageRole::Program | StorageRole::Body)
                )
            })
        })
        .map(|(name, _)| name.clone())
        .collect::<BTreeSet<_>>();
    loop {
        let mut added = Vec::new();
        for (name, rule) in &grammar.rules {
            if program_rules.contains(name) {
                continue;
            }
            let mut refers_to_program = false;
            let only_program_parts = rule.productions.iter().all(|production| {
                production.symbols.iter().all(|symbol| match symbol {
                    Symbol::Literal(text) => matches!(text.as_str(), "{" | "}" | ";"),
                    Symbol::Reference(reference) => {
                        if program_rules.contains(reference) {
                            refers_to_program = true;
                            true
                        } else {
                            reference == name
                        }
                    }
                })
            });
            if only_program_parts && refers_to_program {
                added.push(name.clone());
            }
        }
        if added.is_empty() {
            break;
        }
        program_rules.extend(added);
    }
    for name in &program_rules {
        if !compiler.native(name) {
            value_rules.insert(name.clone(), "native".into());
        }
    }
    Schema {
        root: root_name,
        scopes: compiler.scopes,
        native_declarations,
        value_rules,
        native_rules,
        program_rules,
        value_types: BTreeMap::new(),
    }
}

pub fn compile(grammar: &Grammar, keywords: &[Keyword]) -> Schema {
    let mut schema = compile_syntax(grammar, keywords, None);
    crate::values::compile(grammar, keywords, None, &mut schema);
    schema
}

pub fn compile_with_registry(
    grammar: &Grammar,
    keywords: &[Keyword],
    registry: &Registry,
) -> Schema {
    let mut schema = compile_syntax(grammar, keywords, Some(registry));
    crate::values::compile(grammar, keywords, Some(registry), &mut schema);
    schema
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::grammar::Location;
    use crate::grammar::parse;

    #[test]
    fn recursion_becomes_scopes_without_losing_new_options() {
        let grammar = parse("%token END PROTOCOL DEMO NEW\n%start config\n%%\nconfig: entries END; entries: | entries conf; conf: proto '}'; proto: PROTOCOL DEMO '{' | proto NEW ';';\n%%").unwrap();
        let keywords = ["PROTOCOL", "DEMO", "NEW"].map(|name| Keyword {
            spelling: name.to_lowercase(),
            token: name.into(),
            source: Location {
                file: "test.Y".into(),
                line: 1,
            },
        });
        let schema = compile(&grammar, &keywords);
        let root = &schema.scopes[&schema.root];
        assert!(
            root[0]
                .parts
                .iter()
                .any(|part| matches!(part, Part::Block { .. }))
        );
        assert!(
            schema
                .scopes
                .values()
                .flatten()
                .any(|form| form.parts.contains(&literal("new")))
        );
    }

    #[test]
    fn pure_repetitions_also_take_every_item_from_their_scope() {
        let grammar = parse("%token END ROUTE VIA WEIGHT NUM\n%start config\n%%\nconfig: entries END; entries: | entries conf; conf: ROUTE NUM hops ';'; hops: hop | hops hop; hop: VIA NUM | hop WEIGHT NUM;\n%%").unwrap();
        let keywords = ["ROUTE", "VIA", "WEIGHT"].map(|name| Keyword {
            spelling: name.to_lowercase(),
            token: name.into(),
            source: Location {
                file: "test.Y".into(),
                line: 1,
            },
        });
        let schema = compile(&grammar, &keywords);
        let options = |scope: &str| Part::Options {
            scope: scope.into(),
        };
        let routes = schema.scopes[&schema.root]
            .iter()
            .map(|form| &form.parts[2..])
            .collect::<Vec<_>>();
        assert_eq!(routes.len(), 2, "{routes:?}");
        assert!(
            routes
                .iter()
                .any(|parts| parts.first() == Some(&literal("via"))
                    && parts.ends_with(&[options("hop[]"), options("hops[]"), literal(";")]))
        );
        assert!(routes.contains(&[options("hops[]"), literal(";")].as_slice()));
    }

    #[test]
    fn indirect_recursion_remains_explicitly_positional() {
        let grammar = parse("%token END X\n%start config\n%%\nconfig: entries END; entries: | entries conf; conf: X a; a: b | X; b: a;\n%%").unwrap();
        let schema = compile(&grammar, &[]);
        assert!(schema.scopes.values().flatten().any(|form| form.parts.iter().any(|part| matches!(part, Part::Value { value_kind, .. } if value_kind == "positional"))));
    }

    #[test]
    fn native_declarations_do_not_expand_to_instruction_nodes() {
        let grammar = parse("%union { void *fl; void *x; void *s; }\n%token END FILTER WORD\n%type <s> symbol\n%type <fl> native_body\n%type <x> cmd\n%start config\n%%\nconfig: entries END; entries: | entries conf; conf: FILTER symbol native_body; symbol: WORD; native_body: '{' cmd '}'; cmd: WORD ';';\n%%").unwrap();
        let keyword = Keyword {
            spelling: "filter".into(),
            token: "FILTER".into(),
            source: Location {
                file: "test.Y".into(),
                line: 1,
            },
        };
        let schema = compile(&grammar, &[keyword]);
        assert_eq!(schema.native_declarations[0].prefix, vec!["filter"]);
        assert_eq!(schema.native_declarations[0].lines, vec!["body"]);
        assert!(schema.program_rules.contains("cmd"));
        assert!(schema.scopes[&schema.root][0].parts.iter().any(|part| matches!(part,
            Part::Declaration { native_rule, roles, .. }
                if native_rule == "native_body"
                    && roles.len() == 1
                    && roles[0] == (DeclarationRole::Body { field: "body".into(), rule: "cmd".into(), prefix: vec!["{".into()], suffix: vec!["}".into()] })
        )));
    }

    #[test]
    fn declaration_roles_follow_aliases_and_terminated_parameter_prefixes() {
        let grammar = parse(
            r#"
%union { void *fl; void *x; void *s; int i; }
%token END DECLARE WORD INT BOOL IMP
%type <s> identifier
%type <i> kind locals annotation
%type <fl> native_body body_alias
%type <x> cmds
%start config
%%
config: entries END;
entries: | entries conf;
conf: DECLARE identifier params annotation body_alias;
identifier: WORD;
kind: INT | BOOL;
params: '(' ')' | '(' previous kind identifier ')';
previous: | previous kind identifier ';';
annotation: | IMP kind;
locals: | locals kind identifier ';';
body_alias: native_body;
native_body: locals '{' cmds '}';
cmds: | WORD ';';
%%
"#,
        )
        .unwrap();
        let keywords = ["DECLARE", "INT", "BOOL", "IMP"].map(|name| Keyword {
            spelling: if name == "IMP" {
                "->".into()
            } else {
                name.to_lowercase()
            },
            token: name.into(),
            source: Location {
                file: "test.Y".into(),
                line: 1,
            },
        });
        let schema = compile(&grammar, &keywords);
        let declaration = schema.scopes[&schema.root][0]
            .parts
            .iter()
            .find(|part| matches!(part, Part::Declaration { .. }))
            .unwrap();
        assert_eq!(
            declaration,
            &Part::Declaration {
                rule: "conf".into(),
                production: 0,
                native_rule: "body_alias".into(),
                roles: vec![
                    DeclarationRole::Args {
                        field: "args".into(),
                        rule: "params".into(),
                        prefix: vec!["(".into()],
                        suffix: vec![")".into()],
                        separator: vec![";".into()],
                        empty: Some(vec!["(".into(), ")".into()]),
                        parts: vec![
                            ParameterPart::Type {
                                rule: "kind".into()
                            },
                            ParameterPart::Name {
                                rule: "identifier".into()
                            }
                        ],
                    },
                    DeclarationRole::Return {
                        field: "return".into(),
                        rule: "annotation".into(),
                        value_rule: "kind".into(),
                        prefix: vec!["->".into()],
                        suffix: vec![]
                    },
                    DeclarationRole::Variables {
                        field: "variables".into(),
                        rule: "locals".into()
                    },
                    DeclarationRole::Body {
                        field: "body".into(),
                        rule: "cmds".into(),
                        prefix: vec!["{".into()],
                        suffix: vec!["}".into()]
                    },
                ],
            }
        );
        assert_eq!(
            schema.native_declarations[0].lines,
            vec!["variables", "body"]
        );
        assert!(schema.program_rules.contains("cmds"));
        assert!(!schema.scopes.values().flatten().any(|form| {
            form.parts.iter().any(
                |part| matches!(part, Part::Value { value_kind, .. } if value_kind == "header"),
            )
        }));
    }

    #[test]
    fn parameter_tuples_keep_field_order_and_right_recursive_separators() {
        let grammar = parse(
            r#"
%union { void *fl; void *x; void *s; int i; }
%token END DECLARE WORD INT
%type <s> identifier
%type <i> kind
%type <fl> native_body
%type <x> cmds
%start config
%%
config: entries END;
entries: | entries conf;
conf: DECLARE identifier params native_body;
identifier: WORD;
kind: INT;
params: '(' ')' | '(' pairs ')';
pairs: pair | pair ',' pairs;
pair: identifier ':' kind;
native_body: '{' cmds '}';
cmds: | WORD ';';
%%
"#,
        )
        .unwrap();
        let keyword = Keyword {
            spelling: "declare".into(),
            token: "DECLARE".into(),
            source: Location {
                file: "test.Y".into(),
                line: 1,
            },
        };
        let schema = compile(&grammar, &[keyword]);
        let roles = schema.scopes[&schema.root][0]
            .parts
            .iter()
            .find_map(|part| match part {
                Part::Declaration { roles, .. } => Some(roles),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            roles[0],
            DeclarationRole::Args {
                field: "args".into(),
                rule: "params".into(),
                prefix: vec!["(".into()],
                suffix: vec![")".into()],
                separator: vec![",".into()],
                empty: Some(vec!["(".into(), ")".into()]),
                parts: vec![
                    ParameterPart::Name {
                        rule: "identifier".into()
                    },
                    ParameterPart::Literal { text: ":".into() },
                    ParameterPart::Type {
                        rule: "kind".into()
                    },
                ],
            }
        );
    }

    #[test]
    fn incompatible_parameter_separators_do_not_infer_a_lossy_role() {
        let grammar = parse(
            r#"
%union { void *fl; void *x; void *s; int i; }
%token END DECLARE WORD INT
%type <s> identifier
%type <i> kind
%type <fl> native_body
%type <x> cmds
%start config
%%
config: entries END;
entries: | entries conf;
conf: DECLARE identifier params native_body;
identifier: WORD;
kind: INT;
params: '(' ')' | '(' previous kind identifier ')';
previous: | previous kind identifier ';' | previous kind identifier ',';
native_body: '{' cmds '}';
cmds: | WORD ';';
%%
"#,
        )
        .unwrap();
        let keyword = Keyword {
            spelling: "declare".into(),
            token: "DECLARE".into(),
            source: Location {
                file: "test.Y".into(),
                line: 1,
            },
        };
        let schema = compile(&grammar, &[keyword]);
        assert!(!schema.scopes.values().flatten().any(|form| {
            form.parts
                .iter()
                .any(|part| matches!(part, Part::Declaration { .. }))
        }));
        assert!(schema.scopes[&schema.root].iter().any(|form| {
            form.parts
                .iter()
                .any(|part| matches!(part, Part::Body { rule } if rule == "native_body"))
        }));
    }

    #[test]
    fn declaration_keywords_with_symbol_storage_do_not_capture_the_name() {
        let grammar = parse(
            r#"
%union { void *s; void *fa; void *fl; void *x; int i; }
%token END WORD IMP
%token <s> FUNCTION INT BOOL
%type <s> symbol
%type <fa> function_args function_argsn
%type <i> type function_type function_vars
%type <fl> function_body
%type <x> cmds
%start config
%%
config: entries END;
entries: | entries conf;
conf: FUNCTION symbol function_args function_type function_body;
symbol: WORD;
type: INT | BOOL;
function_args: '(' ')' | '(' function_argsn type symbol ')';
function_argsn: | function_argsn type symbol ';';
function_type: | IMP type;
function_vars: | function_vars type symbol ';';
function_body: function_vars '{' cmds '}';
cmds: | WORD ';';
%%
"#,
        )
        .unwrap();
        let keywords = ["FUNCTION", "INT", "BOOL", "IMP"].map(|name| Keyword {
            spelling: if name == "IMP" {
                "->".into()
            } else {
                name.to_lowercase()
            },
            token: name.into(),
            source: Location {
                file: "test.Y".into(),
                line: 1,
            },
        });
        let schema = compile(&grammar, &keywords);
        let [form] = schema.scopes[&schema.root].as_slice() else {
            panic!("expected one native declaration form");
        };
        let [
            Part::Literal { text },
            Part::Value { rule, .. },
            Part::Declaration { roles, .. },
        ] = form.parts.as_slice()
        else {
            panic!("symbol-typed keywords must retain the native declaration roles");
        };
        assert_eq!(text, "function");
        assert_eq!(rule, "symbol");
        assert!(matches!(roles.as_slice(), [
            DeclarationRole::Args { rule: args, empty: Some(empty), .. },
            DeclarationRole::Return { rule: annotation, value_rule, .. },
            DeclarationRole::Variables { rule: variables, .. },
            DeclarationRole::Body { rule: body, .. },
        ] if args == "function_args" && empty == &["(", ")"]
            && annotation == "function_type" && value_rule == "type"
            && variables == "function_vars" && body == "cmds"));
        assert_eq!(schema.native_declarations[0].prefix, vec!["function"]);
        assert_eq!(
            schema.native_declarations[0].lines,
            vec!["variables", "body"]
        );
    }

    #[test]
    fn native_names_follow_token_storage_not_a_token_spelling_prefix() {
        let grammar = parse("%union { void *s; void *fl; void *x; }\n%token END FILTER WORD\n%token <s> DECL_NAME\n%type <fl> native_body\n%type <x> cmds\n%start config\n%%\nconfig: entries END; entries: | entries conf; conf: FILTER DECL_NAME native_body; native_body: '{' cmds '}'; cmds: WORD ';';\n%%").unwrap();
        let keyword = Keyword {
            spelling: "filter".into(),
            token: "FILTER".into(),
            source: Location {
                file: "test.Y".into(),
                line: 1,
            },
        };
        let schema = compile(&grammar, &[keyword]);
        assert_eq!(schema.native_declarations[0].lines, vec!["body"]);
        assert!(schema.scopes[&schema.root].iter().any(|form| form.parts.iter().any(|part| matches!(part, Part::Declaration { native_rule, .. } if native_rule == "native_body"))));
    }
}
