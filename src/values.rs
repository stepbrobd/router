use crate::grammar::{Grammar, Rule, Symbol, Token};
use crate::registry::{
    self, BindingDefinition, Merge, Registry, Representation, Shape, StorageRole,
};
use crate::source::Keyword;
use crate::surface::{DeclarationRole, Form, Header, HeaderModifier, Part, Schema};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ValueShape {
    Primitive {
        representation: Representation,
        rule: String,
        nullable: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        expression_rule: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        family: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        bare: Option<bool>,
        #[serde(skip_serializing_if = "Vec::is_empty")]
        expression_prefix: Vec<String>,
        #[serde(skip_serializing_if = "Vec::is_empty")]
        expression_suffix: Vec<String>,
        #[serde(skip_serializing_if = "BTreeMap::is_empty")]
        units: BTreeMap<String, Vec<String>>,
        #[serde(skip_serializing_if = "BTreeMap::is_empty")]
        values: BTreeMap<String, Vec<String>>,
        #[serde(skip_serializing_if = "Vec::is_empty")]
        suffixes: Vec<Vec<String>>,
    },
    Enum {
        values: BTreeMap<String, Vec<String>>,
        nullable: bool,
    },
    Record {
        forms: Vec<RecordForm>,
        nullable: bool,
        merge: Merge,
    },
    List {
        item_rule: String,
        separator: Vec<String>,
        prefix: Vec<String>,
        suffix: Vec<String>,
        nullable: bool,
        merge: Merge,
    },
    Choice {
        alternatives: Vec<String>,
        nullable: bool,
    },
    Body {
        roles: Vec<DeclarationRole>,
        nullable: bool,
    },
    Exact {
        rule: String,
        nullable: bool,
    },
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct RecordForm {
    pub parts: Vec<RecordPart>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RecordPart {
    Literal {
        text: String,
    },
    Field {
        name: String,
        rule: String,
        optional: bool,
    },
    Spread {
        scope: String,
    },
    Body {
        name: String,
        rule: String,
        optional: bool,
    },
}

struct Values<'a> {
    grammar: &'a Grammar,
    spellings: BTreeMap<String, String>,
    registry: Option<&'a Registry>,
    program_rules: &'a BTreeSet<String>,
    types: BTreeMap<String, ValueShape>,
    active: BTreeSet<String>,
}

fn punctuation(text: &str) -> bool {
    matches!(
        text,
        ";" | "=" | ":" | "," | "(" | ")" | "[" | "]" | "{" | "}" | "" | "%"
    )
}

fn leading(parts: &[Part]) -> Vec<String> {
    parts
        .iter()
        .map_while(|part| match part {
            Part::Literal { text } if !punctuation(text) => Some(text.clone()),
            _ => None,
        })
        .collect()
}

fn common_prefix(values: &[Vec<String>]) -> Vec<String> {
    let Some(first) = values.first() else {
        return Vec::new();
    };
    first
        .iter()
        .enumerate()
        .take_while(|(index, value)| {
            values
                .iter()
                .all(|values| values.get(*index) == Some(*value))
        })
        .map(|(_, value)| value.clone())
        .collect()
}

impl Values<'_> {
    fn nullable(&self, name: &str, active: &mut BTreeSet<String>) -> bool {
        if !active.insert(name.into()) {
            return false;
        }
        let nullable = self.grammar.rules.get(name).is_some_and(|rule| {
            rule.productions.iter().any(|production| {
                production.symbols.iter().all(|symbol| match symbol {
                    Symbol::Reference(reference) => self.nullable(reference, active),
                    Symbol::Literal(_) => false,
                })
            })
        });
        active.remove(name);
        nullable
    }

    fn epsilon(&self, name: &str, active: &mut BTreeSet<String>) -> bool {
        if !active.insert(name.into()) {
            return false;
        }
        let empty = self.grammar.rules.get(name).is_some_and(|rule| {
            rule.productions.iter().all(|production| {
                production.symbols.iter().all(|symbol| match symbol {
                    Symbol::Reference(reference) => self.epsilon(reference, active),
                    Symbol::Literal(_) => false,
                })
            })
        });
        active.remove(name);
        empty
    }

    fn fixed<'a>(&'a self, symbol: &'a Symbol) -> Option<&'a str> {
        registry::fixed(self.grammar, &self.spellings, symbol)
    }

    fn label(&self, name: &str, fields: &BTreeMap<String, String>) -> String {
        self.registry.map_or_else(
            || {
                fields
                    .get(name)
                    .cloned()
                    .unwrap_or_else(|| name.replace('_', "-"))
            },
            |registry| registry.label(name, fields),
        )
    }

    fn literal_sequences(
        &self,
        symbols: &[Symbol],
        active: &mut BTreeSet<String>,
    ) -> Option<Vec<Vec<String>>> {
        let mut forms = vec![Vec::new()];
        for symbol in symbols {
            let choices = if let Some(text) = self.fixed(symbol) {
                vec![if text.is_empty() {
                    Vec::new()
                } else {
                    vec![text.to_owned()]
                }]
            } else {
                let Symbol::Reference(reference) = symbol else {
                    return None;
                };
                if !active.insert(reference.clone()) {
                    return None;
                }
                let mut choices = Vec::new();
                for production in &self.grammar.rules.get(reference)?.productions {
                    choices.extend(self.literal_sequences(&production.symbols, active)?);
                }
                active.remove(reference);
                choices
            };
            let mut next = Vec::with_capacity(forms.len() * choices.len());
            for prefix in forms {
                for choice in &choices {
                    let mut tokens = Vec::with_capacity(prefix.len() + choice.len());
                    tokens.extend_from_slice(&prefix);
                    tokens.extend_from_slice(choice);
                    next.push(tokens);
                }
            }
            forms = next;
        }
        Some(forms)
    }

    fn reaches(&self, name: &str, target: &str, active: &mut BTreeSet<String>) -> bool {
        if name == target {
            return true;
        }
        if !active.insert(name.into()) {
            return false;
        }
        let found = self.grammar.rules.get(name).is_some_and(|rule| {
            rule.productions.iter().any(|production| {
                production.symbols.iter().any(|symbol| match symbol {
                    Symbol::Reference(reference) => self.reaches(reference, target, active),
                    _ => false,
                })
            })
        });
        active.remove(name);
        found
    }

    fn family<'a>(&'a self, name: &'a str) -> Option<String> {
        let mut pending = vec![name];
        let mut visited = BTreeSet::new();
        let mut family = None;
        while let Some(reference) = pending.pop() {
            if !visited.insert(reference) {
                continue;
            }
            if let Some(token) = self.grammar.tokens.get(reference)
                && let Some(found) = token
                    .storage_type
                    .as_deref()
                    .and_then(|tag| registry::definition().families.get(tag))
            {
                if family.is_some_and(|family| family != found) {
                    return None;
                }
                family = Some(found);
            } else if let Some(rule) = self.grammar.rules.get(reference) {
                pending.extend(rule.productions.iter().flat_map(|production| {
                    production.symbols.iter().filter_map(|symbol| match symbol {
                        Symbol::Reference(reference) => Some(reference.as_str()),
                        _ => None,
                    })
                }));
            }
        }
        family.cloned()
    }

    fn expression_wrapper(
        &self,
        name: &str,
        expression: &str,
    ) -> Option<(Vec<String>, Vec<String>)> {
        let mut wrapper = None;
        for production in &self.grammar.rules.get(name)?.productions {
            let Some(index) = production.symbols.iter().position(
                |symbol| matches!(symbol, Symbol::Reference(reference) if reference == expression),
            ) else {
                continue;
            };
            let prefix = production.symbols[..index]
                .iter()
                .map(|symbol| self.fixed(symbol).map(str::to_owned))
                .collect::<Option<Vec<_>>>()?;
            let suffix = production.symbols[index + 1..]
                .iter()
                .map(|symbol| self.fixed(symbol).map(str::to_owned))
                .collect::<Option<Vec<_>>>()?;
            let candidate = (prefix, suffix);
            if wrapper
                .as_ref()
                .is_some_and(|wrapper| wrapper != &candidate)
            {
                return None;
            }
            wrapper = Some(candidate);
        }
        wrapper
    }

    fn primitive(&self, name: &str, representation: Representation) -> ValueShape {
        let mut units = BTreeMap::new();
        let mut bare = (representation == Representation::Duration).then_some(false);
        let (expression_prefix, expression_suffix) = if let Some(registry) = self.registry
            && registry.bindings["constant.reference-expression"].rule == name
        {
            let expression = &registry.bindings["constant.expression"].rule;
            let Some(wrapper) = self.expression_wrapper(name, expression) else {
                return ValueShape::Exact {
                    rule: name.into(),
                    nullable: self.nullable(name, &mut BTreeSet::new()),
                };
            };
            wrapper
        } else {
            (Vec::new(), Vec::new())
        };
        let mut values = self
            .registry
            .and_then(|registry| registry.binding(name))
            .map(|binding| binding.values.clone())
            .unwrap_or_default();
        let mut suffixes = Vec::new();
        if let Some(rule) = self.grammar.rules.get(name) {
            for production in &rule.productions {
                if representation == Representation::Duration
                    && matches!(production.symbols.first(), Some(Symbol::Reference(reference)) if self.fixed(&production.symbols[0]).is_none() && reference != name)
                    && let Some(sequences) = self.literal_sequences(
                        &production.symbols[1..],
                        &mut BTreeSet::from([name.into()]),
                    )
                {
                    for tokens in sequences {
                        if tokens.is_empty() {
                            bare = Some(true);
                        } else {
                            units.insert(tokens.join("-"), tokens);
                        }
                    }
                }
                if representation == Representation::TypeName {
                    if let Some(sequences) = self
                        .literal_sequences(&production.symbols, &mut BTreeSet::from([name.into()]))
                    {
                        for tokens in sequences {
                            if !tokens.is_empty() {
                                values.insert(tokens.join("-"), tokens);
                            }
                        }
                    } else if matches!(production.symbols.first(), Some(Symbol::Reference(reference)) if reference == name)
                        && let Some(tokens) = production.symbols[1..]
                            .iter()
                            .map(|symbol| self.fixed(symbol).map(str::to_owned))
                            .collect::<Option<Vec<_>>>()
                    {
                        suffixes.push(tokens);
                    }
                }
            }
        }
        let expression_rule = self
            .registry
            .and_then(|registry| registry.bindings.get("constant.reference-expression"))
            .map(|binding| &binding.rule)
            .filter(|target| self.reaches(name, target, &mut BTreeSet::new()))
            .cloned();
        let family = if matches!(
            representation,
            Representation::IpAddress | Representation::Prefix
        ) {
            self.family(name)
        } else {
            None
        };
        ValueShape::Primitive {
            representation,
            rule: name.into(),
            nullable: self.nullable(name, &mut BTreeSet::new()),
            expression_rule,
            family,
            bare,
            expression_prefix,
            expression_suffix,
            units,
            values,
            suffixes,
        }
    }

    fn body_shape(&self, name: &str, active: &mut BTreeSet<String>) -> ValueShape {
        let nullable = self.nullable(name, &mut BTreeSet::new());
        if active.insert(name.into())
            && let Some(rule) = self.grammar.rules.get(name)
        {
            let nonempty = rule
                .productions
                .iter()
                .filter(|production| !production.symbols.is_empty())
                .collect::<Vec<_>>();
            if let [production] = nonempty.as_slice() {
                if let [Symbol::Reference(reference)] = production.symbols.as_slice() {
                    let mut result = self.body_shape(reference, active);
                    if let ValueShape::Body {
                        nullable: result_nullable,
                        ..
                    } = &mut result
                    {
                        *result_nullable = nullable;
                    }
                    return result;
                }
                let symbols = &production.symbols;
                let open = symbols
                    .iter()
                    .position(|symbol| self.fixed(symbol) == Some("{"));
                let close = symbols
                    .iter()
                    .rposition(|symbol| self.fixed(symbol) == Some("}"));
                if let (Some(open), Some(close)) = (open, close)
                    && open < close
                    && let [Symbol::Reference(body)] = &symbols[open + 1..close]
                {
                    let prefix = symbols[open..open + 1]
                        .iter()
                        .map(|symbol| self.fixed(symbol).unwrap().to_owned())
                        .collect();
                    let suffix = symbols[close..]
                        .iter()
                        .map(|symbol| self.fixed(symbol).map(str::to_owned))
                        .collect::<Option<Vec<_>>>();
                    let mut roles = Vec::new();
                    if open == 1
                        && let Symbol::Reference(variables) = &symbols[0]
                        && self.nullable(variables, &mut BTreeSet::new())
                    {
                        roles.push(DeclarationRole::Variables {
                            field: registry::role_field("variables"),
                            rule: variables.clone(),
                        });
                    } else if open != 0 {
                        return self.raw_body(name, nullable);
                    }
                    if let Some(suffix) = suffix {
                        roles.push(DeclarationRole::Body {
                            field: registry::role_field("body"),
                            rule: body.clone(),
                            prefix,
                            suffix,
                        });
                        return ValueShape::Body { roles, nullable };
                    }
                }
            }
        }
        self.raw_body(name, nullable)
    }

    fn raw_body(&self, name: &str, nullable: bool) -> ValueShape {
        ValueShape::Body {
            roles: vec![DeclarationRole::Body {
                field: registry::role_field("body"),
                rule: name.into(),
                prefix: Vec::new(),
                suffix: Vec::new(),
            }],
            nullable,
        }
    }

    fn enum_shape(&self, sequences: &[Vec<String>], nullable: bool) -> ValueShape {
        let nonempty = sequences
            .iter()
            .filter(|tokens| !tokens.is_empty())
            .cloned()
            .collect::<Vec<_>>();
        let mut prefix = common_prefix(&nonempty);
        if nonempty.iter().any(|tokens| tokens.len() == prefix.len()) {
            prefix.clear();
        }
        let values = nonempty
            .into_iter()
            .map(|tokens| {
                let label = tokens[prefix.len()..].join("-");
                (label, tokens)
            })
            .collect();
        ValueShape::Enum { values, nullable }
    }

    fn infer(&mut self, name: &str) {
        if self.types.contains_key(name) || !self.active.insert(name.into()) {
            return;
        }
        let nullable = self.nullable(name, &mut BTreeSet::new());
        let binding = self.registry.and_then(|registry| registry.binding(name));
        let shape = if let Some(representation) = binding.and_then(|binding| binding.representation)
        {
            self.primitive(name, representation)
        } else if binding.and_then(|binding| binding.shape) == Some(Shape::Flag) {
            self.flag_shape(name, nullable)
        } else if binding.and_then(|binding| binding.shape) == Some(Shape::Body)
            || self
                .grammar
                .rules
                .get(name)
                .and_then(|rule| rule.storage_type.as_deref())
                .is_some_and(|tag| registry::storage_role(tag) == Some(StorageRole::Body))
        {
            self.body_shape(name, &mut BTreeSet::new())
        } else if let Some(token) = self.grammar.tokens.get(name) {
            self.token_shape(name, token)
        } else if self.program_rules.contains(name) {
            self.raw_body(name, nullable)
        } else if let Some(shape) = self.list_shape(name) {
            shape
        } else if self
            .grammar
            .rules
            .get(name)
            .is_some_and(|rule| rule.storage_type.is_none())
            && binding.and_then(|binding| binding.shape).is_none()
        {
            ValueShape::Exact {
                rule: name.into(),
                nullable,
            }
        } else if let Some(rule) = self.grammar.rules.get(name) {
            self.production_shape(name, rule, binding, nullable)
        } else {
            ValueShape::Exact {
                rule: name.into(),
                nullable,
            }
        };
        self.types.insert(name.into(), shape);
        self.active.remove(name);
    }

    // A registry flag is a fixed keyword sequence that renders for true and is absent for false.
    fn flag_shape(&self, name: &str, nullable: bool) -> ValueShape {
        let sequences = self.grammar.rules[name]
            .productions
            .iter()
            .map(|production| {
                production
                    .symbols
                    .iter()
                    .map(|symbol| self.fixed(symbol).map(str::to_owned))
                    .collect::<Option<Vec<_>>>()
            })
            .collect::<Option<Vec<_>>>();
        if let Some(sequences) = sequences.filter(|sequences| {
            sequences.iter().filter(|tokens| !tokens.is_empty()).count() == 1
                && sequences.iter().filter(|tokens| tokens.is_empty()).count() <= 1
        }) {
            let mut values = BTreeMap::new();
            for tokens in sequences {
                values.insert(
                    if tokens.is_empty() { "false" } else { "true" }.into(),
                    tokens,
                );
            }
            ValueShape::Enum { values, nullable }
        } else {
            ValueShape::Exact {
                rule: name.into(),
                nullable,
            }
        }
    }

    fn token_shape(&self, name: &str, token: &Token) -> ValueShape {
        if let Some(representation) = token
            .storage_type
            .as_deref()
            .and_then(|tag| registry::definition().lexical.get(tag).copied())
        {
            self.primitive(name, representation)
        } else if let Some(text) = self.spellings.get(name) {
            ValueShape::Enum {
                values: BTreeMap::from([(text.clone(), vec![text.clone()])]),
                nullable: false,
            }
        } else {
            ValueShape::Exact {
                rule: name.into(),
                nullable: false,
            }
        }
    }

    // A rule with stored semantics becomes an enum, a record, a choice between its alternatives,
    // or an exact node when a production has no typed reading.
    fn production_shape(
        &mut self,
        name: &str,
        rule: &Rule,
        binding: Option<&BindingDefinition>,
        nullable: bool,
    ) -> ValueShape {
        let mut literals = Vec::new();
        let mut alternatives = Vec::new();
        let mut records = Vec::new();
        let fields = binding
            .map(|binding| &binding.fields)
            .cloned()
            .unwrap_or_default();
        let mut exact = false;
        for production in &rule.productions {
            let symbols = production.symbols.iter().filter(|symbol| !matches!(symbol, Symbol::Reference(reference) if self.epsilon(reference, &mut BTreeSet::new()))).cloned().collect::<Vec<_>>();
            if let Some(tokens) = symbols
                .iter()
                .map(|symbol| self.fixed(symbol).map(str::to_owned))
                .collect::<Option<Vec<_>>>()
            {
                literals.push(tokens);
            } else if let [Symbol::Reference(reference)] = symbols.as_slice() {
                if self.active.contains(reference) {
                    exact = true;
                    break;
                }
                self.infer(reference);
                alternatives.push(reference.clone());
            } else if let Some(forms) =
                self.symbol_records(&symbols, &fields, &mut BTreeSet::from([name.into()]), None)
            {
                records.extend(forms);
            } else {
                exact = true;
                break;
            }
        }
        if let Some(binding) = binding {
            for id in &binding.native_fields {
                let native_rule = self.registry.unwrap().bindings[id].rule.clone();
                let key = format!("${name}:{id}:native");
                let shape = self.raw_body(&native_rule, false);
                self.types.insert(key.clone(), shape);
                for form in &mut records {
                    for part in &mut form.parts {
                        if let RecordPart::Field {
                            name,
                            rule,
                            optional,
                        } = part
                            && rule == &native_rule
                        {
                            *part = RecordPart::Body {
                                name: name.clone(),
                                rule: key.clone(),
                                optional: *optional,
                            };
                        }
                    }
                }
            }
        }
        if exact {
            ValueShape::Exact {
                rule: name.into(),
                nullable,
            }
        } else if alternatives.is_empty() && records.is_empty() {
            self.enum_shape(&literals, nullable)
        } else {
            if literals.iter().any(|tokens| !tokens.is_empty()) {
                let key = format!("${name}:enum");
                self.types
                    .insert(key.clone(), self.enum_shape(&literals, nullable));
                alternatives.push(key);
            }
            if !records.is_empty() {
                dedup_records(&mut records);
                if alternatives.is_empty() {
                    ValueShape::Record {
                        forms: records,
                        nullable,
                        merge: Merge::Replace,
                    }
                } else {
                    let key = format!("${name}:record");
                    self.types.insert(
                        key.clone(),
                        ValueShape::Record {
                            forms: records,
                            nullable,
                            merge: Merge::Replace,
                        },
                    );
                    alternatives.push(key);
                    ValueShape::Choice {
                        alternatives,
                        nullable,
                    }
                }
            } else if let [alternative] = alternatives.as_slice() {
                if let Some(shape @ ValueShape::List { .. }) = self.types.get(alternative) {
                    shape.clone()
                } else {
                    ValueShape::Choice {
                        alternatives,
                        nullable,
                    }
                }
            } else {
                ValueShape::Choice {
                    alternatives,
                    nullable,
                }
            }
        }
    }

    fn list_shape(&mut self, name: &str) -> Option<ValueShape> {
        let rule = self.grammar.rules.get(name)?;
        let mut recursive = Vec::new();
        let mut bases = Vec::new();
        let mut direction = None;
        for production in &rule.productions {
            let symbols = &production.symbols;
            if matches!(symbols.first(), Some(Symbol::Reference(reference)) if reference == name) {
                if direction == Some(false) {
                    return None;
                }
                direction = Some(true);
                recursive.push(&symbols[1..]);
            } else if matches!(symbols.last(), Some(Symbol::Reference(reference)) if reference == name)
            {
                if direction == Some(true) {
                    return None;
                }
                direction = Some(false);
                recursive.push(&symbols[..symbols.len() - 1]);
            } else {
                bases.push(symbols.as_slice());
            }
        }
        if recursive.is_empty() || bases.is_empty() {
            return None;
        }
        let nullable = bases.iter().any(|base| base.is_empty());
        let item = bases
            .iter()
            .find(|base| !base.is_empty())
            .copied()
            .unwrap_or(recursive[0]);
        if bases.iter().any(|base| !base.is_empty() && *base != item) {
            return None;
        }
        let mut separator = None;
        for chunk in recursive {
            let remaining = if direction == Some(true) && chunk.ends_with(item) {
                &chunk[..chunk.len() - item.len()]
            } else if direction == Some(false) && chunk.starts_with(item) {
                &chunk[item.len()..]
            } else {
                return None;
            };
            let tokens = remaining
                .iter()
                .map(|symbol| self.fixed(symbol).map(str::to_owned))
                .collect::<Option<Vec<_>>>()?;
            if separator
                .as_ref()
                .is_some_and(|separator| separator != &tokens)
            {
                return None;
            }
            separator = Some(tokens);
        }
        let item_rule = if let [Symbol::Reference(reference)] = item {
            if self.active.contains(reference) {
                return None;
            }
            self.infer(reference);
            reference.clone()
        } else {
            let forms = self.symbol_records(
                item,
                &BTreeMap::new(),
                &mut BTreeSet::from([name.into()]),
                None,
            )?;
            let key = format!("${name}:item");
            self.types.insert(
                key.clone(),
                ValueShape::Record {
                    forms,
                    nullable: false,
                    merge: Merge::Replace,
                },
            );
            key
        };
        Some(ValueShape::List {
            item_rule,
            separator: separator.unwrap_or_default(),
            prefix: Vec::new(),
            suffix: Vec::new(),
            nullable,
            merge: Merge::Replace,
        })
    }

    fn symbol_records(
        &mut self,
        symbols: &[Symbol],
        fields: &BTreeMap<String, String>,
        active: &mut BTreeSet<String>,
        forced_label: Option<&str>,
    ) -> Option<Vec<RecordForm>> {
        let mut forms = vec![RecordForm { parts: Vec::new() }];
        let mut pending = Vec::new();
        for symbol in symbols {
            if let Some(text) = self.fixed(symbol) {
                if !text.is_empty() {
                    pending.push(text.to_owned());
                }
                continue;
            }
            let Symbol::Reference(reference) = symbol else {
                return None;
            };
            if self.epsilon(reference, &mut BTreeSet::new()) {
                continue;
            }
            let binding = self
                .registry
                .and_then(|registry| registry.binding(reference));
            let inline = binding.is_some_and(|binding| binding.expand)
                || (self
                    .grammar
                    .rules
                    .get(reference)
                    .is_some_and(|rule| rule.storage_type.is_none())
                    && !binding.is_some_and(|binding| {
                        binding.atomic
                            || matches!(
                                binding.shape,
                                Some(Shape::List | Shape::Flag | Shape::Body)
                            )
                    })
                    && !self.program_rules.contains(reference));
            if inline {
                if !active.insert(reference.clone()) {
                    return None;
                }
                let nested_fields = binding
                    .map(|binding| {
                        let mut result = fields.clone();
                        result.extend(binding.fields.clone());
                        result
                    })
                    .unwrap_or_else(|| fields.clone());
                let label = binding
                    .filter(|binding| binding.expand)
                    .and_then(|binding| binding.label.as_deref())
                    .or(forced_label);
                let mut nested = Vec::new();
                for production in &self.grammar.rules.get(reference)?.productions {
                    nested.extend(self.symbol_records(
                        &production.symbols,
                        &nested_fields,
                        active,
                        label,
                    )?);
                }
                active.remove(reference);
                append_literals(&mut forms, &mut pending);
                forms = product(forms, nested);
                continue;
            }
            self.infer(reference);
            let is_body = matches!(self.types.get(reference), Some(ValueShape::Body { .. }));
            let explicit_label = binding
                .and_then(|binding| fields.get(&binding.id))
                .or_else(|| fields.get(reference))
                .map(String::as_str);
            let name = explicit_label.or(forced_label).map_or_else(
                || {
                    let keyword = pending
                        .iter()
                        .filter(|text| !punctuation(text))
                        .map(String::as_str)
                        .collect::<Vec<_>>();
                    if !is_body && !keyword.is_empty() {
                        keyword.join("-")
                    } else {
                        self.label(reference, fields)
                    }
                },
                str::to_owned,
            );
            let optional = (is_body || !pending.iter().any(|text| !punctuation(text)))
                && self.nullable(reference, &mut BTreeSet::new());
            append_literals(&mut forms, &mut pending);
            let part = if is_body {
                RecordPart::Body {
                    name,
                    rule: reference.clone(),
                    optional,
                }
            } else {
                RecordPart::Field {
                    name,
                    rule: reference.clone(),
                    optional,
                }
            };
            for form in &mut forms {
                form.parts.push(part.clone());
            }
        }
        append_literals(&mut forms, &mut pending);
        if forms.iter().any(|form| duplicate_fields(&form.parts)) {
            return None;
        }
        Some(forms)
    }

    fn normalize_projection_blocks(&self, forms: &mut Vec<RecordForm>) {
        let mut removed = None;
        let mut nullable_scopes = BTreeMap::new();
        for form in forms.iter() {
            for (position, parts) in form.parts.windows(3).enumerate() {
                let [
                    RecordPart::Literal { text: open },
                    RecordPart::Spread { scope },
                    RecordPart::Literal { text: close },
                ] = parts
                else {
                    continue;
                };
                if open != "{" || close != "}" {
                    continue;
                }
                let nullable = nullable_scopes.entry(scope.as_str()).or_insert_with(|| {
                    scope
                        .strip_suffix("[]")
                        .is_some_and(|rule| self.nullable(rule, &mut BTreeSet::new()))
                });
                if !*nullable {
                    continue;
                }
                for (index, candidate) in forms.iter().enumerate() {
                    if candidate.parts.len() + 3 == form.parts.len()
                        && candidate.parts[..position] == form.parts[..position]
                        && candidate.parts[position..] == form.parts[position + 3..]
                    {
                        removed.get_or_insert_with(|| vec![false; forms.len()])[index] = true;
                    }
                }
            }
        }
        drop(nullable_scopes);
        let Some(removed) = removed else {
            return;
        };
        // Typed records denote an explicit block, and exact nodes keep its omitted production.
        let mut index = 0;
        forms.retain(|_| {
            let keep = !removed[index];
            index += 1;
            keep
        });
    }

    fn projection_records(
        &mut self,
        parts: &[Part],
        fields: &BTreeMap<String, String>,
        namespace: &str,
    ) -> Option<Vec<RecordForm>> {
        let mut forms = vec![RecordForm { parts: Vec::new() }];
        let mut pending = Vec::new();
        for (position, part) in parts.iter().enumerate() {
            match part {
                Part::Literal { text } => pending.push(text.clone()),
                Part::Value { rule, .. } => {
                    let binding = self.registry.and_then(|registry| registry.binding(rule));
                    if let Some(binding) = binding.filter(|binding| binding.expand) {
                        let mut nested = Vec::new();
                        let mut nested_fields = fields.clone();
                        nested_fields.extend(binding.fields.clone());
                        let forced = binding.label.as_deref();
                        for production in &self.grammar.rules.get(rule)?.productions {
                            nested.extend(self.symbol_records(
                                &production.symbols,
                                &nested_fields,
                                &mut BTreeSet::from([rule.clone()]),
                                forced,
                            )?);
                        }
                        append_literals(&mut forms, &mut pending);
                        forms = product(forms, nested);
                        continue;
                    }
                    self.infer(rule);
                    if matches!(self.types.get(rule), Some(ValueShape::Body { .. })) {
                        self.flush_flags(&mut forms, &mut pending, namespace, position);
                        for form in &mut forms {
                            form.parts.push(RecordPart::Body {
                                name: self.label(rule, fields),
                                rule: rule.clone(),
                                optional: self.nullable(rule, &mut BTreeSet::new()),
                            });
                        }
                        continue;
                    }
                    let keyword = pending
                        .iter()
                        .filter(|text| !punctuation(text))
                        .cloned()
                        .collect::<Vec<_>>();
                    let name = if keyword.is_empty() {
                        self.label(rule, fields)
                    } else {
                        keyword.join("-")
                    };
                    append_literals(&mut forms, &mut pending);
                    let mut choices = vec![RecordForm {
                        parts: vec![RecordPart::Field {
                            name,
                            rule: rule.clone(),
                            optional: keyword.is_empty()
                                && self.nullable(rule, &mut BTreeSet::new()),
                        }],
                    }];
                    if let Some(ValueShape::List {
                        item_rule,
                        prefix,
                        suffix,
                        ..
                    }) = self.types.get(rule)
                        && prefix.is_empty()
                        && suffix.is_empty()
                        && let Some(ValueShape::Record {
                            forms: item_forms, ..
                        }) = self.types.get(item_rule)
                    {
                        choices.extend(item_forms.clone());
                    }
                    forms = product(forms, choices);
                }
                Part::Options { scope } => {
                    self.flush_flags(&mut forms, &mut pending, namespace, position);
                    for form in &mut forms {
                        form.parts.push(RecordPart::Spread {
                            scope: scope.clone(),
                        });
                    }
                }
                Part::Block { scope } => {
                    self.flush_flags(&mut forms, &mut pending, namespace, position);
                    for form in &mut forms {
                        form.parts.extend([
                            RecordPart::Literal { text: "{".into() },
                            RecordPart::Spread {
                                scope: scope.clone(),
                            },
                            RecordPart::Literal { text: "}".into() },
                        ]);
                    }
                }
                Part::Body { rule } => {
                    self.infer(rule);
                    self.flush_flags(&mut forms, &mut pending, namespace, position);
                    for form in &mut forms {
                        form.parts.push(RecordPart::Body {
                            name: registry::role_field("body"),
                            rule: rule.clone(),
                            optional: false,
                        });
                    }
                }
                Part::Declaration { .. } => return None,
            }
        }
        self.flush_flags(&mut forms, &mut pending, namespace, parts.len());
        if forms.iter().any(|form| duplicate_fields(&form.parts)) {
            return None;
        }
        Some(forms)
    }

    fn flush_flags(
        &mut self,
        forms: &mut [RecordForm],
        pending: &mut Vec<String>,
        namespace: &str,
        position: usize,
    ) {
        let first = pending.iter().position(|text| !punctuation(text));
        let last = pending.iter().rposition(|text| !punctuation(text));
        if let (Some(first), Some(last)) = (first, last) {
            for form in forms.iter_mut() {
                form.parts.extend(
                    pending[..first]
                        .iter()
                        .cloned()
                        .map(|text| RecordPart::Literal { text }),
                );
            }
            let tokens = pending[first..=last].to_vec();
            let name = tokens.join("-");
            let key = format!("${namespace}:flag:{position}:{name}");
            self.types.insert(
                key.clone(),
                ValueShape::Enum {
                    values: BTreeMap::from([("true".into(), tokens)]),
                    nullable: false,
                },
            );
            for form in forms.iter_mut() {
                form.parts.push(RecordPart::Field {
                    name: name.clone(),
                    rule: key.clone(),
                    optional: false,
                });
                form.parts.extend(
                    pending[last + 1..]
                        .iter()
                        .cloned()
                        .map(|text| RecordPart::Literal { text }),
                );
            }
            pending.clear();
        } else {
            append_literals(forms, pending);
        }
    }
}

fn append_literals(forms: &mut [RecordForm], pending: &mut Vec<String>) {
    for form in forms {
        form.parts.extend(
            pending
                .iter()
                .cloned()
                .map(|text| RecordPart::Literal { text }),
        );
    }
    pending.clear();
}

fn product(prefixes: Vec<RecordForm>, suffixes: Vec<RecordForm>) -> Vec<RecordForm> {
    let mut result = Vec::with_capacity(prefixes.len() * suffixes.len());
    for prefix in prefixes {
        for suffix in &suffixes {
            let mut parts = Vec::with_capacity(prefix.parts.len() + suffix.parts.len());
            parts.extend_from_slice(&prefix.parts);
            parts.extend_from_slice(&suffix.parts);
            result.push(RecordForm { parts });
        }
    }
    result
}

fn duplicate_fields(parts: &[RecordPart]) -> bool {
    let mut names = BTreeSet::new();
    parts.iter().any(|part| match part {
        RecordPart::Field { name, .. } | RecordPart::Body { name, .. } => !names.insert(name),
        _ => false,
    })
}

fn dedup_records(forms: &mut Vec<RecordForm>) {
    let mut seen = BTreeSet::new();
    forms.retain(|form| seen.insert(form.clone()));
}

fn header(grammar: &Grammar, spellings: &BTreeMap<String, String>, rule: &str) -> Option<Header> {
    let productions = &grammar.rules.get(rule)?.productions;
    let names = productions
        .iter()
        .filter_map(|production| match production.symbols.as_slice() {
            [Symbol::Reference(name)]
                if grammar
                    .rules
                    .get(name)
                    .and_then(|rule| rule.storage_type.as_deref())
                    .is_some_and(|tag| {
                        registry::storage_role(tag) == Some(StorageRole::Symbol)
                    }) =>
            {
                Some(name.clone())
            }
            _ => None,
        })
        .collect::<BTreeSet<_>>();
    let name_rule = names.first()?.clone();
    if names.len() != 1 {
        return None;
    }
    let mut from = None;
    for production in productions {
        let symbols = if matches!(production.symbols.first(), Some(Symbol::Reference(name)) if name == &name_rule)
        {
            &production.symbols[1..]
        } else {
            &production.symbols
        };
        if symbols.is_empty() {
            continue;
        }
        let (last, prefix) = symbols.split_last()?;
        let Symbol::Reference(from_rule) = last else {
            return None;
        };
        if !grammar
            .tokens
            .get(from_rule)
            .and_then(|token| token.storage_type.as_deref())
            .is_some_and(|tag| registry::storage_role(tag) == Some(StorageRole::Symbol))
        {
            return None;
        }
        let from_prefix = prefix
            .iter()
            .map(|symbol| registry::fixed(grammar, spellings, symbol).map(str::to_owned))
            .collect::<Option<Vec<_>>>()?;
        if from_prefix.is_empty() {
            return None;
        }
        let candidate = (from_rule.clone(), from_prefix);
        if from.as_ref().is_some_and(|from| from != &candidate) {
            return None;
        }
        from = Some(candidate);
    }
    let (from_rule, from_prefix) = from?;
    Some(Header {
        name_rule,
        from_rule: Some(from_rule),
        from_prefix,
        field: registry::definition().header_field.clone(),
        modifiers: Vec::new(),
    })
}

fn normalize_named_headers(forms: &mut Vec<Form>, values: &Values<'_>) {
    let Some(registry) = values.registry else {
        return;
    };
    for form in forms.iter_mut() {
        let prefix = leading(&form.parts);
        let path = registry::canonical_path(&prefix, true);
        if path.len() < 2 {
            continue;
        }
        let name_index = prefix.len();
        let Some(Part::Value {
            rule: name_rule, ..
        }) = form.parts.get(name_index)
        else {
            continue;
        };
        // Only BIRD's defining symbol rule names a declaration. Lookups such as
        // `peer table rtable` reference an existing symbol and stay ordinary settings.
        if name_rule != &registry.bindings["symbol"].rule {
            continue;
        }
        let mut modifiers = Vec::new();
        let mut end = name_index + 1;
        while let Some(Part::Value { rule, .. }) = form.parts.get(end) {
            let Some(binding) = registry.binding(rule) else {
                break;
            };
            if binding.shape != Some(Shape::Flag) {
                break;
            }
            let Some(ValueShape::Enum {
                values: choices,
                nullable: true,
            }) = values.types.get(rule)
            else {
                break;
            };
            let Some(parts) = choices.get("true") else {
                break;
            };
            if parts.is_empty() || choices.get("false").is_none_or(|parts| !parts.is_empty()) {
                break;
            }
            modifiers.push(HeaderModifier {
                field: binding
                    .label
                    .clone()
                    .unwrap_or_else(|| rule.replace('_', "-")),
                parts: parts.clone(),
            });
            end += 1;
        }
        form.header = Some(Header {
            name_rule: name_rule.clone(),
            from_rule: None,
            from_prefix: Vec::new(),
            field: registry.definition.header_field.clone(),
            modifiers,
        });
        form.path = path;
        form.parts.drain(name_index + 1..end);
    }

    let mut bodyless = BTreeSet::new();
    for form in forms.iter().filter(|form| {
        form.header
            .as_ref()
            .is_some_and(|header| header.from_rule.is_none())
    }) {
        let name_end = leading(&form.parts).len() + 1;
        if !matches!(&form.parts[name_end..], [Part::Block { .. }]) {
            continue;
        }
        for (index, candidate) in forms.iter().enumerate() {
            if candidate.path == form.path
                && candidate.header == form.header
                && candidate.parts == form.parts[..name_end]
            {
                bodyless.insert(index);
            }
        }
    }
    let mut index = 0;
    forms.retain(|_| {
        let keep = !bodyless.contains(&index);
        index += 1;
        keep
    });
}

fn factor_enums(scope: &str, forms: &mut Vec<Form>, values: &mut Values<'_>) {
    let mut groups: BTreeMap<Vec<String>, Vec<usize>> = BTreeMap::new();
    for (index, form) in forms.iter().enumerate() {
        if form
            .parts
            .iter()
            .all(|part| matches!(part, Part::Literal { .. }))
        {
            let prefix = leading(&form.parts);
            if prefix.len() > 1 {
                groups
                    .entry(prefix[..prefix.len() - 1].to_vec())
                    .or_default()
                    .push(index);
            }
        }
    }
    let mut replaced = BTreeSet::new();
    let mut additions = Vec::new();
    for indices in groups.values().filter(|indices| indices.len() > 1) {
        let prefixes = indices
            .iter()
            .map(|index| leading(&forms[*index].parts))
            .collect::<Vec<_>>();
        let prefix = common_prefix(&prefixes);
        if prefix.is_empty() || prefixes.iter().any(|tokens| tokens.len() == prefix.len()) {
            continue;
        }
        let suffix = &forms[indices[0]].parts[prefixes[0].len()..];
        if indices
            .iter()
            .zip(&prefixes)
            .any(|(index, keywords)| forms[*index].parts[keywords.len()..] != *suffix)
        {
            continue;
        }
        let key = format!("${scope}:enum:{}", prefix.join("-"));
        let choices = prefixes
            .iter()
            .map(|tokens| {
                let tokens = tokens[prefix.len()..].to_vec();
                (tokens.join("-"), tokens)
            })
            .collect();
        values.types.insert(
            key.clone(),
            ValueShape::Enum {
                values: choices,
                nullable: false,
            },
        );
        let mut parts = prefix
            .into_iter()
            .map(|text| Part::Literal { text })
            .collect::<Vec<_>>();
        parts.push(Part::Value {
            rule: key.clone(),
            value_kind: "typed".into(),
            value_type: Some(key),
        });
        parts.extend_from_slice(suffix);
        additions.push(Form {
            parts,
            path: Vec::new(),
            header: None,
        });
        replaced.extend(indices.iter().copied());
    }
    let mut index = 0;
    forms.retain(|_| {
        let keep = !replaced.contains(&index);
        index += 1;
        keep
    });
    forms.extend(additions);
}

pub fn compile(
    grammar: &Grammar,
    keywords: &[Keyword],
    registry: Option<&Registry>,
    schema: &mut Schema,
) {
    let mut values = Values {
        grammar,
        spellings: registry::spellings(grammar, keywords),
        registry,
        program_rules: &schema.program_rules,
        types: BTreeMap::new(),
        active: BTreeSet::new(),
    };
    for name in grammar.tokens.keys().chain(grammar.rules.keys()) {
        values.infer(name);
    }
    let protocol_header = registry
        .and_then(|registry| registry.bindings.get("protocol.header"))
        .and_then(|binding| header(grammar, &values.spellings, &binding.rule));
    for (scope, forms) in &mut schema.scopes {
        normalize_named_headers(forms, &values);
        factor_enums(scope, forms, &mut values);
        if let Some(registry) = registry {
            for projection in &registry.definition.projections {
                project(scope, forms, projection, registry, &mut values);
            }
            project_positional(scope, forms, &mut values);
        }
        assign_paths(scope, forms, registry, protocol_header.as_ref());
    }
    schema.value_types = values.types;
}

fn project(
    scope: &str,
    forms: &mut Vec<Form>,
    projection: &registry::Projection,
    registry: &Registry,
    values: &mut Values<'_>,
) {
    if projection.scope.as_ref().is_some_and(|id| {
        registry
            .bindings
            .get(id)
            .is_none_or(|binding| scope != format!("{}[]", binding.rule))
    }) {
        return;
    }
    let mut selected = Vec::new();
    let mut records = Vec::new();
    let mut prefix = None;
    let mut suffix = None;
    for (index, form) in forms.iter().enumerate() {
        let keywords = leading(&form.parts);
        if !projection.selectors.contains(&keywords) {
            continue;
        }
        if !projection.contains.is_empty()
            && !form.parts.iter().any(|part| match part {
                Part::Value { rule, .. } => projection.contains.iter().any(|id| {
                    registry
                        .bindings
                        .get(id)
                        .is_some_and(|binding| &binding.rule == rule)
                }),
                _ => false,
            })
        {
            continue;
        }
        let prefix_size = projection.selectors.iter().map(Vec::len).min().unwrap_or(0);
        let end = if matches!(form.parts.last(), Some(Part::Literal { text }) if text == ";") {
            form.parts.len() - 1
        } else {
            form.parts.len()
        };
        let parts = &form.parts[prefix_size..end];
        if let Some(mut projected) = values.projection_records(
            parts,
            &projection.fields,
            &format!("{}:{scope}", projection.id),
        ) {
            if projection.collection {
                for record in &mut projected {
                    let mut parts = form.parts[..prefix_size]
                        .iter()
                        .map(|part| {
                            let Part::Literal { text } = part else {
                                unreachable!()
                            };
                            RecordPart::Literal { text: text.clone() }
                        })
                        .collect::<Vec<_>>();
                    parts.append(&mut record.parts);
                    parts.extend(form.parts[end..].iter().map(|part| {
                        let Part::Literal { text } = part else {
                            unreachable!()
                        };
                        RecordPart::Literal { text: text.clone() }
                    }));
                    record.parts = parts;
                }
            }
            records.extend(projected);
            selected.push(index);
            prefix.get_or_insert_with(|| form.parts[..prefix_size].to_vec());
            suffix.get_or_insert_with(|| form.parts[end..].to_vec());
        }
    }
    if selected.is_empty() {
        return;
    }
    values.normalize_projection_blocks(&mut records);
    dedup_records(&mut records);
    let item = format!("$projection:{}:{scope}:item", projection.id);
    let key = format!("$projection:{}:{scope}", projection.id);
    let shape = ValueShape::Record {
        forms: records,
        nullable: false,
        merge: projection.merge,
    };
    if projection.collection {
        values.types.insert(item.clone(), shape);
        values.types.insert(
            key.clone(),
            ValueShape::List {
                item_rule: item,
                separator: Vec::new(),
                prefix: Vec::new(),
                suffix: Vec::new(),
                nullable: true,
                merge: Merge::Append,
            },
        );
    } else {
        values.types.insert(key.clone(), shape);
    }
    let mut parts = if projection.collection {
        Vec::new()
    } else {
        prefix.unwrap_or_default()
    };
    parts.push(Part::Value {
        rule: key.clone(),
        value_kind: "typed".into(),
        value_type: Some(key),
    });
    if !projection.collection {
        parts.extend(suffix.unwrap_or_default());
    }
    let path = registry::canonical_path(
        &projection.selectors[0][..projection.selectors.iter().map(Vec::len).min().unwrap_or(0)],
        false,
    );
    let first = selected[0];
    let mut index = 0;
    forms.retain(|_| {
        let keep = !selected.contains(&index);
        index += 1;
        keep
    });
    forms.insert(
        first,
        Form {
            parts,
            path,
            header: None,
        },
    );
}

// A statement with several positional values has no single-value form, so it becomes a record named
// by the keyword before each value or by the value's registry label. Single-value forms on the same
// path stay as they are. A form whose fields cannot be named uniquely keeps only its exact form, and
// `router inspect` lists it.
fn project_positional(scope: &str, forms: &mut Vec<Form>, values: &mut Values<'_>) {
    let mut groups: BTreeMap<Vec<String>, Vec<usize>> = BTreeMap::new();
    for (index, form) in forms.iter().enumerate() {
        let keywords = leading(&form.parts);
        let tail = statement_tail(&form.parts, keywords.len());
        let slots = tail
            .iter()
            .filter(|part| !matches!(part, Part::Literal { .. }))
            .count();
        if form.header.is_none() && !keywords.is_empty() && slots > 1 && !named_entry(tail) {
            groups.entry(keywords).or_default().push(index);
        }
    }
    let mut replacements = BTreeMap::new();
    let mut removed = BTreeSet::new();
    for (keywords, indexes) in groups {
        let key = format!("$positional:{scope}:{}", keywords.join("-"));
        let mut records = Vec::new();
        let mut indexes = indexes;
        indexes.retain(|&index| {
            let tail = statement_tail(&forms[index].parts, keywords.len());
            values
                .projection_records(tail, &BTreeMap::new(), &key)
                .map(|projected| records.extend(projected))
                .is_some()
        });
        if indexes.is_empty() {
            continue;
        }
        values.normalize_projection_blocks(&mut records);
        dedup_records(&mut records);
        values.types.insert(
            key.clone(),
            ValueShape::Record {
                forms: records,
                nullable: false,
                merge: Merge::Replace,
            },
        );
        let first = &forms[indexes[0]];
        let mut parts = first.parts[..keywords.len()].to_vec();
        parts.push(Part::Value {
            rule: key.clone(),
            value_kind: "typed".into(),
            value_type: Some(key),
        });
        parts.extend(
            first
                .parts
                .last()
                .filter(|part| matches!(part, Part::Literal { text } if text == ";"))
                .cloned(),
        );
        replacements.insert(
            indexes[0],
            Form {
                parts,
                path: registry::canonical_path(&keywords, false),
                header: None,
            },
        );
        removed.extend(indexes);
    }
    let mut rebuilt = Vec::with_capacity(forms.len());
    for (index, form) in forms.drain(..).enumerate() {
        if let Some(replacement) = replacements.remove(&index) {
            rebuilt.push(replacement);
        } else if !removed.contains(&index) {
            rebuilt.push(form);
        }
    }
    *forms = rebuilt;
}

// Settings a user can write that still need exact grammar nodes, as `scope path` for a statement with
// unnamed positional values and `scope path -> rule` for a value whose every form is exact.
pub(crate) fn exact_settings(schema: &Schema) -> Vec<String> {
    let mut found = BTreeSet::new();
    for (scope, forms) in &schema.scopes {
        for form in forms {
            let keywords = leading(&form.parts);
            let tail = statement_tail(&form.parts, keywords.len());
            let mut slots = tail
                .iter()
                .filter(|part| !matches!(part, Part::Literal { .. }))
                .collect::<Vec<_>>();
            if form.header.is_some() || named_entry(tail) {
                slots.remove(0);
            }
            let path = form.path.join(".");
            if slots.len() > 1 {
                found.insert(format!("{scope} {path}"));
            }
            for slot in slots {
                if let Part::Value {
                    rule, value_type, ..
                } = slot
                {
                    let rule = value_type.as_ref().unwrap_or(rule);
                    for exact in exact_rules(&schema.value_types, rule, &mut BTreeSet::new()) {
                        found.insert(format!("{scope} {path} -> {exact}"));
                    }
                }
            }
        }
    }
    found.into_iter().collect()
}

fn exact_rules(
    types: &BTreeMap<String, ValueShape>,
    rule: &str,
    seen: &mut BTreeSet<String>,
) -> BTreeSet<String> {
    // `seen` holds the rules on the current path, so recursion through a rule stops without
    // hiding that rule from sibling branches
    if !seen.insert(rule.to_owned()) {
        return BTreeSet::new();
    }
    let result = exact_shape(types, rule, seen);
    seen.remove(rule);
    result
}

fn exact_shape(
    types: &BTreeMap<String, ValueShape>,
    rule: &str,
    seen: &mut BTreeSet<String>,
) -> BTreeSet<String> {
    let union = |sets: Vec<BTreeSet<String>>| {
        if !sets.is_empty() && sets.iter().all(|set| !set.is_empty()) {
            sets.into_iter().flatten().collect()
        } else {
            BTreeSet::new()
        }
    };
    match types.get(rule) {
        Some(ValueShape::Exact { .. }) => BTreeSet::from([rule.to_owned()]),
        Some(ValueShape::Choice { alternatives, .. }) => union(
            alternatives
                .iter()
                .map(|alternative| exact_rules(types, alternative, seen))
                .collect(),
        ),
        Some(ValueShape::List { item_rule, .. }) => exact_rules(types, item_rule, seen),
        Some(ValueShape::Record { forms, .. }) => union(
            forms
                .iter()
                .map(|form| {
                    form.parts
                        .iter()
                        .filter_map(|part| match part {
                            RecordPart::Field {
                                rule,
                                optional: false,
                                ..
                            } => Some(exact_rules(types, rule, seen)),
                            _ => None,
                        })
                        .flatten()
                        .collect()
                })
                .collect(),
        ),
        _ => BTreeSet::new(),
    }
}

fn statement_tail(parts: &[Part], keywords: usize) -> &[Part] {
    let end = if matches!(parts.last(), Some(Part::Literal { text }) if text == ";") {
        parts.len() - 1
    } else {
        parts.len()
    };
    &parts[keywords.min(end)..end]
}

// The runtime names an entry by its first value when a block, body, declaration or `=` follows it.
fn named_entry(tail: &[Part]) -> bool {
    matches!(tail.first(), Some(Part::Value { .. }))
        && tail[1..].iter().any(|part| {
            matches!(
                part,
                Part::Block { .. } | Part::Body { .. } | Part::Declaration { .. }
            ) || matches!(part, Part::Literal { text } if text == "=")
        })
}

fn assign_paths(
    scope: &str,
    forms: &mut [Form],
    registry: Option<&Registry>,
    protocol_header: Option<&Header>,
) {
    for form in forms {
        let prefix = leading(&form.parts);
        let rest = &form.parts[prefix.len()..];
        let named = matches!(rest.first(), Some(Part::Value { value_kind, .. }) if value_kind == "symbol")
            && rest[1..].iter().any(|part| {
                matches!(
                    part,
                    Part::Block { .. } | Part::Body { .. } | Part::Declaration { .. }
                ) || matches!(part, Part::Literal { text } if text == "=")
            });
        if form.path.is_empty() {
            form.path = registry::canonical_path(&prefix, named);
        }
        if let Some(registry) = registry
            && let Some(field) = registry
                .fields
                .values()
                .find(|field| field.scope == scope && field.syntax == prefix)
        {
            form.path = field.path.clone();
        }
        if let Some(registry) = registry
            && form.parts.iter().any(|part| matches!(part, Part::Value { rule, .. } if rule == &registry.bindings["protocol.header"].rule)) {
            form.header = protocol_header.cloned();
        }
        for part in &mut form.parts {
            if let Part::Value {
                rule, value_type, ..
            } = part
            {
                *value_type = Some(
                    if registry
                        .is_some_and(|registry| rule == &registry.bindings["protocol.header"].rule)
                    {
                        protocol_header
                            .map_or_else(|| rule.clone(), |header| header.name_rule.clone())
                    } else {
                        rule.clone()
                    },
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::grammar::{Location, parse};

    fn keywords(names: &[&str]) -> Vec<Keyword> {
        names
            .iter()
            .map(|name| Keyword {
                spelling: name.to_lowercase(),
                token: (*name).into(),
                source: Location {
                    file: "test.Y".into(),
                    line: 1,
                },
            })
            .collect()
    }

    fn value_compiler<'a>(
        grammar: &'a Grammar,
        names: &[&str],
        program_rules: &'a BTreeSet<String>,
    ) -> Values<'a> {
        Values {
            grammar,
            spellings: registry::spellings(grammar, &keywords(names)),
            registry: None,
            program_rules,
            types: BTreeMap::new(),
            active: BTreeSet::new(),
        }
    }

    #[test]
    fn keyword_runs_have_one_canonical_key_but_namespace_segments_stay_distinct() {
        let grammar = parse("%union { int i; }\n%token END HOLD TIME NUM\n%type <i> expr\n%start config\n%%\nconfig: entries END; entries: | entries conf; conf: HOLD TIME expr ';'; expr: NUM;\n%%").unwrap();
        let schema = crate::surface::compile(&grammar, &keywords(&["HOLD", "TIME"]));
        assert!(
            schema.scopes[&schema.root]
                .iter()
                .any(|form| form.path == ["hold-time"])
        );
        assert!(
            !schema.scopes[&schema.root]
                .iter()
                .any(|form| form.path == ["hold", "time"])
        );
    }

    #[test]
    fn right_recursive_data_lists_keep_the_source_separator() {
        let grammar = parse("%token END TEXT\n%start config\n%%\nconfig: names END; names: TEXT | TEXT ',' names;\n%%").unwrap();
        let schema = crate::surface::compile(&grammar, &[]);
        assert!(
            matches!(&schema.value_types["names"], ValueShape::List { item_rule, separator, nullable: false, merge, .. } if item_rule == "TEXT" && separator == &[","] && *merge == Merge::Replace)
        );
    }

    #[test]
    fn incompatible_recursive_list_delimiters_remain_exact() {
        let grammar = parse("%token END TEXT\n%start config\n%%\nconfig: names END; names: TEXT | names ',' TEXT | names ';' TEXT;\n%%").unwrap();
        let schema = crate::surface::compile(&grammar, &[]);
        assert!(matches!(
            schema.value_types["names"],
            ValueShape::Exact { .. }
        ));
    }

    #[test]
    fn inherited_protocol_headers_capture_template_or_protocol_references() {
        let grammar = parse("%union { void *s; }\n%token END FROM KNOWN WORD\n%type <s> symbol\n%token <s> PARENT\n%start config\n%%\nconfig: proto_name END; symbol: WORD; proto_name: | symbol | FROM PARENT | symbol FROM PARENT;\n%%").unwrap();
        let spellings = registry::spellings(&grammar, &keywords(&["FROM"]));
        let header = header(&grammar, &spellings, "proto_name").unwrap();
        assert_eq!(header.name_rule, "symbol");
        assert_eq!(header.from_rule.as_deref(), Some("PARENT"));
        assert_eq!(header.from_prefix, vec!["from"]);
    }

    #[test]
    fn duration_bare_syntax_and_unit_aliases_follow_source_alternatives() {
        let grammar = parse("%union { int i; long time; }\n%token END NUM S MS\n%type <i> expr\n%type <time> suffixed optional\n%start config\n%%\nconfig: suffixed END | optional END; expr: NUM; units: S | MS; suffixed: expr units; optional: expr | expr S;\n%%").unwrap();
        let program_rules = BTreeSet::new();
        let values = value_compiler(&grammar, &["S", "MS"], &program_rules);
        let ValueShape::Primitive { bare, units, .. } =
            values.primitive("suffixed", Representation::Duration)
        else {
            panic!("expected a source-derived duration");
        };
        assert_eq!(bare, Some(false));
        assert_eq!(
            units,
            BTreeMap::from([
                ("ms".into(), vec!["ms".into()]),
                ("s".into(), vec!["s".into()]),
            ])
        );
        assert!(matches!(
            values.primitive("optional", Representation::Duration),
            ValueShape::Primitive {
                bare: Some(true),
                ..
            }
        ));
    }

    #[test]
    fn prefix_families_follow_lexical_wrappers_but_not_mixed_alternatives() {
        let grammar = parse("%union { int ip4; int ip6; int net; }\n%token END NUM\n%token <ip4> IP4\n%token <ip6> IP6\n%type <net> prefix4 prefix6 mixed\n%start config\n%%\nconfig: mixed END; prefix4: IP4 '/' NUM; v6_slash: IP6 '/'; prefix6: v6_slash NUM; mixed: prefix4 | prefix6;\n%%").unwrap();
        let program_rules = BTreeSet::new();
        let values = value_compiler(&grammar, &[], &program_rules);
        for (rule, expected) in [
            ("prefix4", Some("ipv4")),
            ("prefix6", Some("ipv6")),
            ("mixed", None),
        ] {
            let ValueShape::Primitive { family, .. } =
                values.primitive(rule, Representation::Prefix)
            else {
                panic!("expected a source-derived prefix");
            };
            assert_eq!(family.as_deref(), expected, "{rule}");
        }
    }

    #[test]
    fn explicit_interface_fields_distinguish_symbol_and_text_alternatives() {
        let grammar = parse("%union { void *s; char *t; }\n%token END DEV\n%token <s> WORD\n%token <t> TEXT\n%type <s> symbol\n%type <t> text\n%start config\n%%\nconfig: iface END; iface: '%' symbol | DEV text; symbol: WORD; text: TEXT;\n%%").unwrap();
        let program_rules = BTreeSet::new();
        let mut values = value_compiler(&grammar, &["DEV"], &program_rules);
        let fields = BTreeMap::from([
            ("symbol".into(), "interface-symbol".into()),
            ("text".into(), "interface".into()),
        ]);
        for (production, expected) in grammar.rules["iface"]
            .productions
            .iter()
            .zip(["interface-symbol", "interface"])
        {
            let forms = values
                .symbol_records(
                    &production.symbols,
                    &fields,
                    &mut BTreeSet::new(),
                    Some("interface"),
                )
                .unwrap();
            let names = forms[0]
                .parts
                .iter()
                .filter_map(|part| match part {
                    RecordPart::Field { name, .. } => Some(name.as_str()),
                    _ => None,
                })
                .collect::<Vec<_>>();
            assert_eq!(names, [expected]);
        }
    }

    #[test]
    fn expression_wrappers_reject_competing_native_delimiters() {
        let grammar = parse("%token END NUM WORD\n%start config\n%%\nconfig: reference END; term: NUM; symbol: WORD; reference: symbol | '(' term ')'; ambiguous: '(' term ')' | '[' term ']';\n%%").unwrap();
        let program_rules = BTreeSet::new();
        let values = value_compiler(&grammar, &[], &program_rules);
        assert_eq!(
            values.expression_wrapper("reference", "term"),
            Some((vec!["(".into()], vec![")".into()]))
        );
        assert_eq!(values.expression_wrapper("ambiguous", "term"), None);
    }

    fn projection_grammar() -> Grammar {
        parse("%union { int i; char *t; void *fl; }\n%token END NUM\n%token <t> TEXT\n%type <t> pattern\n%type <i> exclude item\n%type <fl> route_body\n%start config\n%%\nconfig: declaration END | required END | route_body END;\ndeclaration: patterns optional_block;\npatterns: item | patterns ',' item;\nitem: exclude pattern | exclude pattern '@' NUM;\nexclude: | '-'; pattern: TEXT;\noptional_block: | '{' options '}';\noptions: | options option ';'; required: option ';'; option: NUM;\nroute_body: | '{' native '}'; native: NUM;\n%%").unwrap()
    }

    fn projected_value(rule: &str) -> Part {
        Part::Value {
            rule: rule.into(),
            value_kind: "typed".into(),
            value_type: None,
        }
    }

    #[test]
    fn singleton_list_records_keep_pattern_order_and_block_options() {
        let grammar = projection_grammar();
        let program_rules = BTreeSet::new();
        let mut values = value_compiler(&grammar, &[], &program_rules);
        values.infer("patterns");
        let original = values.types.clone();
        let parts = [
            projected_value("patterns"),
            Part::Block {
                scope: "options[]".into(),
            },
        ];
        let forms = values
            .projection_records(&parts, &BTreeMap::new(), "test")
            .unwrap();
        assert!(matches!(
            &values.types["patterns"],
            ValueShape::List { item_rule, separator, .. }
                if item_rule == "item" && separator == &[","]
        ));
        assert_eq!(values.types, original);
        assert_eq!(forms.len(), 3);
        assert!(matches!(
            forms[0].parts.as_slice(),
            [
                RecordPart::Field { name, rule, .. },
                RecordPart::Literal { text: open },
                RecordPart::Spread { scope },
                RecordPart::Literal { text: close },
            ] if name == "patterns" && rule == "patterns"
                && open == "{" && scope == "options[]" && close == "}"
        ));
        assert!(matches!(
            forms[1].parts.as_slice(),
            [
                RecordPart::Field { name: exclude, optional: true, .. },
                RecordPart::Field { name: pattern, optional: false, .. },
                RecordPart::Literal { text: open },
                RecordPart::Spread { scope },
                RecordPart::Literal { text: close },
            ] if exclude == "exclude" && pattern == "pattern"
                && open == "{" && scope == "options[]" && close == "}"
        ));
        assert!(
            forms[2]
                .parts
                .contains(&RecordPart::Literal { text: "@".into() })
        );
    }

    #[test]
    fn nullable_projection_blocks_have_one_explicit_empty_representation() {
        let grammar = projection_grammar();
        let program_rules = BTreeSet::new();
        let mut values = value_compiler(&grammar, &[], &program_rules);
        let mut forms = values
            .projection_records(&[projected_value("patterns")], &BTreeMap::new(), "test")
            .unwrap();
        let blocks = values
            .projection_records(
                &[
                    projected_value("patterns"),
                    Part::Block {
                        scope: "options[]".into(),
                    },
                ],
                &BTreeMap::new(),
                "test",
            )
            .unwrap();
        forms.extend(blocks.clone());
        values.normalize_projection_blocks(&mut forms);
        assert_eq!(forms, blocks);
        assert_eq!(grammar.rules["optional_block"].productions.len(), 2);
    }

    #[test]
    fn required_blocks_and_distinct_projection_syntax_stay_available() {
        let grammar = projection_grammar();
        let program_rules = BTreeSet::new();
        let mut values = value_compiler(&grammar, &[], &program_rules);
        let mut forms = values
            .projection_records(&[projected_value("patterns")], &BTreeMap::new(), "test")
            .unwrap();
        forms.extend(
            values
                .projection_records(
                    &[
                        projected_value("patterns"),
                        Part::Block {
                            scope: "required[]".into(),
                        },
                    ],
                    &BTreeMap::new(),
                    "test",
                )
                .unwrap(),
        );
        forms.extend(
            values
                .projection_records(
                    &[
                        projected_value("patterns"),
                        Part::Literal {
                            text: "alternative".into(),
                        },
                        Part::Block {
                            scope: "options[]".into(),
                        },
                    ],
                    &BTreeMap::new(),
                    "test",
                )
                .unwrap(),
        );
        let original = forms.clone();
        values.normalize_projection_blocks(&mut forms);
        assert_eq!(forms, original);
    }

    #[test]
    fn projected_route_bodies_remain_native_text_with_source_braces() {
        let grammar = projection_grammar();
        let program_rules = BTreeSet::from(["native".into()]);
        let mut values = value_compiler(&grammar, &[], &program_rules);
        let mut forms = values
            .projection_records(
                &[projected_value("patterns"), projected_value("route_body")],
                &BTreeMap::new(),
                "test",
            )
            .unwrap();
        let original = forms.clone();
        values.normalize_projection_blocks(&mut forms);
        assert_eq!(forms, original);
        assert!(forms.iter().all(|form| matches!(
            form.parts.last(),
            Some(RecordPart::Body { name, rule, optional: true })
                if name == "route-body" && rule == "route_body"
        )));
        assert!(matches!(
            &values.types["route_body"],
            ValueShape::Body { roles, nullable: true }
                if matches!(roles.as_slice(), [DeclarationRole::Body { prefix, suffix, .. }]
                    if prefix == &["{"] && suffix == &["}"])
        ));
    }
}
