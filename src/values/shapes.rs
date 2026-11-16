use super::records::dedup_records;
use super::{RecordPart, ValueShape, Values, common_prefix};
use crate::grammar::{Rule, Symbol, Token};
use crate::registry::{self, BindingDefinition, Merge, Representation, Shape, StorageRole};
use crate::surface::DeclarationRole;
use std::collections::{BTreeMap, BTreeSet};

impl Values<'_> {
    pub(super) fn nullable(&self, name: &str, active: &mut BTreeSet<String>) -> bool {
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

    pub(super) fn epsilon(&self, name: &str, active: &mut BTreeSet<String>) -> bool {
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

    pub(super) fn fixed<'a>(&'a self, symbol: &'a Symbol) -> Option<&'a str> {
        registry::fixed(self.grammar, &self.spellings, symbol)
    }

    pub(super) fn label(&self, name: &str, fields: &BTreeMap<String, String>) -> String {
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

    pub(super) fn infer(&mut self, name: &str) {
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

    // a registry flag renders its keyword sequence for true and nothing for false
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

    // a rule with stored semantics becomes an enum, a record or a choice between its alternatives
    // a production without a typed reading makes it an exact node
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
        for (number, production) in rule.productions.iter().enumerate() {
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
            } else if let Some(forms) = self.symbol_records(
                &production.symbols,
                Some((name, number)),
                &fields,
                &mut BTreeSet::from([name.into()]),
                None,
            ) {
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
                None,
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
}

#[cfg(test)]
mod tests {
    use super::super::fixtures::value_compiler;
    use super::*;
    use crate::grammar::parse;

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
}
