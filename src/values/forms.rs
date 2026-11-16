use super::records::dedup_records;
use super::{
    RecordPart, ValueShape, Values, common_prefix, leading, named_entry, retain_indexed,
    statement_tail,
};
use crate::grammar::{Grammar, Symbol};
use crate::registry::{self, Merge, Registry, Shape, StorageRole};
use crate::surface::{Form, Header, HeaderModifier, Part};
use std::collections::{BTreeMap, BTreeSet};

pub(super) fn header(
    grammar: &Grammar,
    spellings: &BTreeMap<String, String>,
    rule: &str,
) -> Option<Header> {
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

pub(super) fn normalize_named_headers(forms: &mut Vec<Form>, values: &Values<'_>) {
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
        // only BIRD's defining symbol rule names a declaration
        // lookups such as `peer table rtable` reference an existing symbol and stay ordinary settings
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
    retain_indexed(forms, |index| !bodyless.contains(&index));
}

pub(super) fn factor_enums(scope: &str, forms: &mut Vec<Form>, values: &mut Values<'_>) {
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
    retain_indexed(forms, |index| !replaced.contains(&index));
    forms.extend(additions);
}

pub(super) fn project(
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
        // the keyword prefix and the closing `;` are literals by construction
        let literal = |part: &Part| {
            let Part::Literal { text } = part else {
                unreachable!()
            };
            RecordPart::Literal { text: text.clone() }
        };
        if let Some(mut projected) = values.projection_records(
            parts,
            &projection.fields,
            &format!("{}:{scope}", projection.id),
        ) {
            if projection.collection {
                for record in &mut projected {
                    let mut parts = form.parts[..prefix_size]
                        .iter()
                        .map(literal)
                        .collect::<Vec<_>>();
                    parts.append(&mut record.parts);
                    parts.extend(form.parts[end..].iter().map(literal));
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
    retain_indexed(forms, |index| !selected.contains(&index));
    forms.insert(
        first,
        Form {
            parts,
            path,
            header: None,
        },
    );
}

// a statement with several positional values becomes a record named by the keyword before each value or its registry label
// single-value forms on the same path stay as they are
// a form whose fields cannot be named uniquely keeps its exact form, which `router inspect` lists
pub(super) fn project_positional(scope: &str, forms: &mut Vec<Form>, values: &mut Values<'_>) {
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

pub(super) fn assign_paths(
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
    use super::super::fixtures::keywords;
    use super::*;
    use crate::grammar::parse;

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
    fn inherited_protocol_headers_capture_template_or_protocol_references() {
        let grammar = parse("%union { void *s; }\n%token END FROM KNOWN WORD\n%type <s> symbol\n%token <s> PARENT\n%start config\n%%\nconfig: proto_name END; symbol: WORD; proto_name: | symbol | FROM PARENT | symbol FROM PARENT;\n%%").unwrap();
        let spellings = registry::spellings(&grammar, &keywords(&["FROM"]));
        let header = header(&grammar, &spellings, "proto_name").unwrap();
        assert_eq!(header.name_rule, "symbol");
        assert_eq!(header.from_rule.as_deref(), Some("PARENT"));
        assert_eq!(header.from_prefix, vec!["from"]);
    }
}
