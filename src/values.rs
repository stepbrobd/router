mod addressable;
mod forms;
mod records;
mod shapes;

pub(crate) use addressable::unaddressable;

use crate::grammar::Grammar;
use crate::registry::{self, Merge, Registry, Representation};
use crate::source::Keyword;
use crate::surface::{DeclarationRole, Part, Schema};
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
        .and_then(|binding| forms::header(grammar, &values.spellings, &binding.rule));
    for (scope, forms) in &mut schema.scopes {
        forms::normalize_named_headers(forms, &values);
        forms::factor_enums(scope, forms, &mut values);
        if let Some(registry) = registry {
            for projection in &registry.definition.projections {
                forms::project(scope, forms, projection, registry, &mut values);
            }
            forms::project_positional(scope, forms, &mut values);
        }
        forms::assign_paths(scope, forms, registry, protocol_header.as_ref());
    }
    schema.value_types = values.types;
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

fn statement_tail(parts: &[Part], keywords: usize) -> &[Part] {
    let end = if matches!(parts.last(), Some(Part::Literal { text }) if text == ";") {
        parts.len() - 1
    } else {
        parts.len()
    };
    &parts[keywords.min(end)..end]
}

// the runtime names an entry by its first value when a block, body, declaration or `=` follows it
fn named_entry(tail: &[Part]) -> bool {
    matches!(tail.first(), Some(Part::Value { .. }))
        && tail[1..].iter().any(|part| {
            matches!(
                part,
                Part::Block { .. } | Part::Body { .. } | Part::Declaration { .. }
            ) || matches!(part, Part::Literal { text } if text == "=")
        })
}

fn retain_indexed<T>(items: &mut Vec<T>, mut keep: impl FnMut(usize) -> bool) {
    let mut index = 0;
    items.retain(|_| {
        let kept = keep(index);
        index += 1;
        kept
    });
}

#[cfg(test)]
mod fixtures {
    use super::Values;
    use crate::grammar::{Grammar, Location};
    use crate::registry;
    use crate::source::Keyword;
    use std::collections::{BTreeMap, BTreeSet};

    pub(super) fn keywords(names: &[&str]) -> Vec<Keyword> {
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

    pub(super) fn value_compiler<'a>(
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
}
