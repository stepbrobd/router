use super::{RecordPart, ValueShape, leading, named_entry};
use crate::grammar::{Grammar, Location};
use crate::surface::{Part, Schema};
use std::collections::{BTreeMap, BTreeSet};

// settings the nix runtime cannot write from attributes, one line per form
// mirrors formInfo, matchForm and renderTail in lib/router/bird/runtime.nix
// a form needs a path or a captured name, at most one part after the name,
// and no exact shape behind any alternative of its values
pub(crate) fn unaddressable(grammar: &Grammar, schema: &Schema) -> Vec<String> {
    let mut found = BTreeSet::new();
    for (scope, forms) in &schema.scopes {
        for form in forms {
            if matches!(form.parts.as_slice(), [Part::Literal { text }] if text == ";") {
                continue;
            }
            let keywords = leading(&form.parts);
            let rest = &form.parts[keywords.len()..];
            let named = form.header.is_some() || named_entry(rest);
            let tail = if named { &rest[1..] } else { rest };
            let slots = tail
                .iter()
                .filter(|part| !matches!(part, Part::Literal { .. }))
                .count();
            let setting = format!("{scope} {}", form.path.join("."));
            if form.path.is_empty() && !named {
                found.insert(format!("{setting}: no setting path"));
            }
            if slots > 1 {
                found.insert(format!("{setting}: {slots} parts after the setting name"));
            }
            for part in &form.parts {
                if let Part::Value {
                    rule, value_type, ..
                } = part
                {
                    let rule = value_type.as_ref().unwrap_or(rule);
                    for exact in exact_rules(&schema.value_types, rule, &mut BTreeSet::new()) {
                        found.insert(format!(
                            "{setting}: exact {exact}{}",
                            origin(grammar, &exact)
                        ));
                    }
                }
            }
        }
    }
    found.into_iter().collect()
}

fn origin(grammar: &Grammar, name: &str) -> String {
    let source: Option<&Location> = grammar
        .rules
        .get(name)
        .map(|rule| &rule.source)
        .or_else(|| grammar.tokens.get(name).map(|token| &token.source));
    source.map_or_else(String::new, |source| {
        format!(" ({}:{})", source.file, source.line)
    })
}

// every exact shape reachable through any alternative, record field or list item
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
    let result = match types.get(rule) {
        Some(ValueShape::Exact { .. }) => BTreeSet::from([rule.to_owned()]),
        Some(ValueShape::Choice { alternatives, .. }) => alternatives
            .iter()
            .flat_map(|alternative| exact_rules(types, alternative, seen))
            .collect(),
        Some(ValueShape::List { item_rule, .. }) => exact_rules(types, item_rule, seen),
        Some(ValueShape::Record { forms, .. }) => forms
            .iter()
            .flat_map(|form| &form.parts)
            .filter_map(|part| match part {
                RecordPart::Field { rule, .. } => Some(rule),
                _ => None,
            })
            .flat_map(|rule| exact_rules(types, rule, seen))
            .collect(),
        _ => BTreeSet::new(),
    };
    seen.remove(rule);
    result
}

#[cfg(test)]
mod tests {
    use super::super::fixtures::keywords;
    use super::*;
    use crate::grammar::parse;

    #[test]
    fn unnamed_values_keyless_statements_and_any_exact_alternative_are_unaddressable() {
        let grammar = parse("%union { int i; }\n%token END SETTLE HOLD KIND PICK\n%token <i> NUM\n%type <i> expr mode other either some\n%start config\n%%\nconfig: entries END; entries: | entries conf;\nconf: SETTLE expr expr ';' | HOLD expr ';' | KIND either ';' | PICK some ';' | expr ';';\nexpr: NUM;\nmode: NUM NUM;\nother: NUM NUM NUM;\neither: mode | other;\nsome: mode | expr;\n%%").unwrap();
        let schema =
            crate::surface::compile(&grammar, &keywords(&["SETTLE", "HOLD", "KIND", "PICK"]));
        let scope = &schema.root;
        assert_eq!(
            unaddressable(&grammar, &schema),
            [
                format!("{scope} : no setting path"),
                format!("{scope} kind: exact mode (<m4-output>:10)"),
                format!("{scope} kind: exact other (<m4-output>:11)"),
                format!("{scope} pick: exact mode (<m4-output>:10)"),
                format!("{scope} settle: 2 parts after the setting name"),
            ]
        );
    }
}
