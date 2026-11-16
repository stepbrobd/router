use super::{RecordPart, ValueShape, leading, named_entry, statement_tail};
use crate::surface::{Part, Schema};
use std::collections::{BTreeMap, BTreeSet};

// settings a user can write that still need exact grammar nodes
// `scope path` for a statement with unnamed positional values
// `scope path -> rule` for a value whose every form is exact
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
    // `seen` holds the rules on the current path
    // so recursion stops at a repeated rule without hiding it from sibling branches
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

#[cfg(test)]
mod tests {
    use super::super::fixtures::keywords;
    use super::*;
    use crate::grammar::parse;

    #[test]
    fn unnamed_positional_values_and_all_exact_alternatives_need_exact_nodes() {
        let grammar = parse("%union { int i; }\n%token END SETTLE HOLD MODE KIND PICK\n%token <i> NUM\n%type <i> expr mode other either some\n%start config\n%%\nconfig: entries END; entries: | entries conf;\nconf: SETTLE expr expr ';' | HOLD expr ';' | MODE mode ';' | KIND either ';' | PICK some ';';\nexpr: NUM;\nmode: NUM NUM;\nother: NUM NUM NUM;\neither: mode | other;\nsome: mode | expr;\n%%").unwrap();
        let schema = crate::surface::compile(
            &grammar,
            &keywords(&["SETTLE", "HOLD", "MODE", "KIND", "PICK"]),
        );
        let scope = &schema.root;
        assert_eq!(
            exact_settings(&schema),
            [
                format!("{scope} kind -> mode"),
                format!("{scope} kind -> other"),
                format!("{scope} mode -> mode"),
                format!("{scope} settle"),
            ]
        );
    }
}
