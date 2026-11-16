use super::{RecordForm, RecordPart, ValueShape, Values, punctuation, retain_indexed};
use crate::grammar::Symbol;
use crate::registry::{self, Shape};
use crate::surface::Part;
use std::collections::{BTreeMap, BTreeSet};

impl Values<'_> {
    // `origin` is the rule and production number `symbols` come from, which selects registry labels
    pub(super) fn symbol_records(
        &mut self,
        symbols: &[Symbol],
        origin: Option<(&str, usize)>,
        fields: &BTreeMap<String, String>,
        active: &mut BTreeSet<String>,
        forced_label: Option<&str>,
    ) -> Option<Vec<RecordForm>> {
        let mut forms = vec![RecordForm { parts: Vec::new() }];
        let mut pending = Vec::new();
        let mut closed = None;
        for (index, symbol) in symbols.iter().enumerate() {
            if closed == Some(index) {
                continue;
            }
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
            if let Some(close) = self.statement_block(symbols, index, &pending) {
                pending.pop();
                let name = self
                    .keyword_name(&pending)
                    .unwrap_or_else(|| self.label(reference, fields));
                append_literals(&mut forms, &mut pending);
                let part = RecordPart::Field {
                    name,
                    rule: format!("$block:{reference}[]"),
                    optional: false,
                };
                for form in &mut forms {
                    form.parts.push(part.clone());
                }
                closed = Some(close);
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
                                Some(Shape::List | Shape::Flag | Shape::Body | Shape::Text)
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
                for (number, production) in self
                    .grammar
                    .rules
                    .get(reference)?
                    .productions
                    .iter()
                    .enumerate()
                {
                    nested.extend(self.symbol_records(
                        &production.symbols,
                        Some((reference, number)),
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
            let slot_label = origin.and_then(|(rule, number)| {
                self.registry
                    .and_then(|registry| registry.slot_label(rule, number, index))
            });
            let explicit_label = slot_label.or_else(|| {
                binding
                    .and_then(|binding| fields.get(&binding.id))
                    .or_else(|| fields.get(reference))
                    .map(String::as_str)
            });
            let name = explicit_label.or(forced_label).map_or_else(
                || {
                    self.keyword_name(&pending)
                        .filter(|_| !is_body)
                        .unwrap_or_else(|| self.label(reference, fields))
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

    fn keyword_name(&self, pending: &[String]) -> Option<String> {
        let keyword = pending
            .iter()
            .filter(|text| !punctuation(text))
            .map(String::as_str)
            .collect::<Vec<_>>();
        (!keyword.is_empty()).then(|| keyword.join("-"))
    }

    // `'{' X '}'` where X repeats statements, such as `flow4 { dst 10.0.0.0/8; }`, holds the
    // scope of X as a record, and returns the position of the closing brace
    fn statement_block(
        &mut self,
        symbols: &[Symbol],
        index: usize,
        pending: &[String],
    ) -> Option<usize> {
        let Symbol::Reference(reference) = &symbols[index] else {
            return None;
        };
        let close = index + 1;
        if pending.last().map(String::as_str) != Some("{")
            || symbols.get(close).and_then(|symbol| self.fixed(symbol)) != Some("}")
            || self.grammar.rules.get(reference)?.storage_type.is_some()
        {
            return None;
        }
        let scope = format!("{reference}[]");
        let key = format!("$block:{scope}");
        if !self.types.contains_key(&key) {
            let scopes = crate::surface::statement_scopes(
                self.grammar,
                &self.spellings,
                self.registry,
                reference,
            )?;
            self.scopes.extend(scopes);
            self.types.insert(
                key,
                ValueShape::Record {
                    forms: vec![RecordForm {
                        parts: vec![
                            RecordPart::Literal { text: "{".into() },
                            RecordPart::Spread { scope },
                            RecordPart::Literal { text: "}".into() },
                        ],
                    }],
                    nullable: false,
                    merge: registry::Merge::Replace,
                },
            );
        }
        Some(close)
    }

    pub(super) fn normalize_projection_blocks(&self, forms: &mut Vec<RecordForm>) {
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
        // typed records denote an explicit block
        // exact nodes keep its omitted production
        retain_indexed(forms, |index| !removed[index]);
    }

    pub(super) fn projection_records(
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
                Part::Value { rule, label, .. } => {
                    let binding = self.registry.and_then(|registry| registry.binding(rule));
                    if let Some(binding) = binding.filter(|binding| binding.expand) {
                        let mut nested = Vec::new();
                        let mut nested_fields = fields.clone();
                        nested_fields.extend(binding.fields.clone());
                        let forced = binding.label.as_deref();
                        for (number, production) in
                            self.grammar.rules.get(rule)?.productions.iter().enumerate()
                        {
                            nested.extend(self.symbol_records(
                                &production.symbols,
                                Some((rule, number)),
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
                    let name = if let Some(label) = label {
                        label.clone()
                    } else if keyword.is_empty() {
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

pub(super) fn dedup_records(forms: &mut Vec<RecordForm>) {
    let mut seen = BTreeSet::new();
    forms.retain(|form| seen.insert(form.clone()));
}

#[cfg(test)]
mod tests {
    use super::super::fixtures::value_compiler;
    use super::*;
    use crate::grammar::{Grammar, parse};
    use crate::surface::DeclarationRole;

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
                    None,
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

    fn projection_grammar() -> Grammar {
        parse("%union { int i; char *t; void *fl; }\n%token END NUM\n%token <t> TEXT\n%type <t> pattern\n%type <i> exclude item\n%type <fl> route_body\n%start config\n%%\nconfig: declaration END | required END | route_body END;\ndeclaration: patterns optional_block;\npatterns: item | patterns ',' item;\nitem: exclude pattern | exclude pattern '@' NUM;\nexclude: | '-'; pattern: TEXT;\noptional_block: | '{' options '}';\noptions: | options option ';'; required: option ';'; option: NUM;\nroute_body: | '{' native '}'; native: NUM;\n%%").unwrap()
    }

    fn projected_value(rule: &str) -> Part {
        Part::Value {
            rule: rule.into(),
            value_kind: "typed".into(),
            value_type: None,
            label: None,
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

    #[test]
    fn a_braced_statement_list_in_a_value_is_a_field_holding_its_scope() {
        let grammar = parse("%union { int i; }\n%token END FLOW DST PROTO\n%token <i> NUM\n%type <i> expr flow\n%start config\n%%\nconfig: entries END; entries: | entries conf;\nconf: DST flow ';';\nflow: FLOW '{' opts '}';\nopts: | opts item ';';\nitem: DST expr | PROTO expr;\nexpr: NUM;\n%%").unwrap();
        let schema = crate::surface::compile(
            &grammar,
            &crate::values::fixtures::keywords(&["FLOW", "DST", "PROTO"]),
        );
        assert_eq!(
            schema.value_types["flow"],
            ValueShape::Record {
                forms: vec![RecordForm {
                    parts: vec![
                        RecordPart::Literal {
                            text: "flow".into()
                        },
                        RecordPart::Field {
                            name: "flow".into(),
                            rule: "$block:opts[]".into(),
                            optional: false,
                        },
                    ],
                }],
                nullable: false,
                merge: crate::registry::Merge::Replace,
            }
        );
        assert!(matches!(
            &schema.value_types["$block:opts[]"],
            ValueShape::Record { forms, .. } if forms[0].parts.contains(&RecordPart::Spread { scope: "opts[]".into() })
        ));
        let paths = schema.scopes["opts[]"]
            .iter()
            .map(|form| form.path.join("."))
            .collect::<Vec<_>>();
        assert_eq!(paths, ["dst", "proto"]);
        assert!(crate::values::unaddressable(&grammar, &schema).is_empty());
    }
}
