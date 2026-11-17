use super::{Naming, RecordPart, ValueShape, leading, named_entry, statement_tail};
use crate::surface::{Form, Part, Schema};
use std::collections::{BTreeMap, BTreeSet};

// a setting path the nix runtime accepts, with what it expects there
// `<name>` stands for a declaration or entry name and `*` for a list item, as in NixOS option docs
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Setting {
    pub loc: Vec<String>,
    pub types: BTreeSet<String>,
    // the scopes whose forms declare this path
    pub scopes: BTreeSet<String>,
    // a block whose settings are listed once under another path, such as a template's under its protocol
    pub same_as: Option<Vec<String>>,
    // the keywords of the statement that declares this path, empty for a record field
    pub keywords: Vec<String>,
}

// every setting reachable from the root, through blocks, record fields, list items and spreads
// within one kind of root declaration, such as BGP protocols and templates, which open the same block,
// each scope is listed under the first path that reaches it in grammar order and the others point there
// mirrors formInfo and describeSetting in lib/router/bird/runtime.nix
pub(crate) fn settings(schema: &Schema) -> Vec<Setting> {
    walk(schema).found.into_values().collect()
}

// where the names of reachable settings come from
pub(crate) struct Names {
    // the `[[labels]]` ids that name a field some setting reaches
    pub labels: BTreeSet<String>,
    // fields that only their own grammar symbol or punctuation names, by record and field name,
    // with the first setting path that reaches each
    pub unnamed: BTreeMap<(String, String), Vec<String>>,
}

pub(crate) fn names(schema: &Schema) -> Names {
    let walk = walk(schema);
    Names {
        labels: walk.labels,
        unnamed: walk.unnamed,
    }
}

fn walk(schema: &Schema) -> Walk<'_> {
    let mut walk = Walk {
        schema,
        found: BTreeMap::new(),
        documented: BTreeMap::new(),
        declaration: schema.root.clone(),
        values: BTreeSet::new(),
        labels: BTreeSet::new(),
        unnamed: BTreeMap::new(),
    };
    walk.scope(&schema.root, &[]);
    walk
}

struct Walk<'a> {
    schema: &'a Schema,
    found: BTreeMap<Vec<String>, Setting>,
    // where each scope's settings are listed, per root declaration block
    documented: BTreeMap<(String, String), Vec<String>>,
    // the block the current root declaration opens
    declaration: String,
    // the value types on the current path, which stops recursion without hiding siblings
    values: BTreeSet<String>,
    labels: BTreeSet<String>,
    unnamed: BTreeMap<(String, String), Vec<String>>,
}

impl Walk<'_> {
    fn emit(&mut self, loc: Vec<String>, kind: String, scope: &str) -> &mut Setting {
        let setting = self.found.entry(loc.clone()).or_insert_with(|| Setting {
            loc,
            ..Setting::default()
        });
        setting.types.insert(kind);
        setting.scopes.insert(scope.to_owned());
        setting
    }

    fn scope(&mut self, scope: &str, prefix: &[String]) {
        let key = (self.declaration.clone(), scope.to_owned());
        if let Some(first) = self.documented.get(&key) {
            if first != prefix
                && let Some(setting) = self.found.get_mut(prefix)
            {
                setting.same_as = Some(first.clone());
            }
            return;
        }
        self.documented.insert(key, prefix.to_vec());
        for form in &self.schema.scopes[scope] {
            self.form(scope, form, prefix);
        }
    }

    fn form(&mut self, scope: &str, form: &Form, prefix: &[String]) {
        let keywords = leading(&form.parts);
        let rest = statement_tail(&form.parts, keywords.len());
        let named = form.header.is_some() || form.named || named_entry(rest);
        if form.path.is_empty() && !named {
            return;
        }
        let mut loc = [prefix, form.path.as_slice()].concat();
        if named {
            loc.push("<name>".into());
        }
        let tail = if named { &rest[1..] } else { rest };
        let parts = tail
            .iter()
            .filter(|part| !matches!(part, Part::Literal { .. }))
            .collect::<Vec<_>>();
        let kind = match parts.first() {
            None => "true".into(),
            Some(Part::Value {
                rule, value_type, ..
            }) => describe(
                &self.schema.value_types,
                0,
                value_type.as_ref().unwrap_or(rule),
            ),
            Some(Part::Block { .. } | Part::Options { .. }) => {
                "an attribute set of settings".into()
            }
            Some(Part::Body { .. }) => "native BIRD text".into(),
            Some(Part::Declaration { .. }) => "a declaration record".into(),
            Some(Part::Literal { .. }) => unreachable!(),
        };
        let setting = self.emit(loc.clone(), kind, scope);
        if setting.keywords.is_empty() {
            setting.keywords = keywords;
        }
        if let Some(header) = &form.header {
            if header.from_rule.is_some() {
                self.emit(child(&loc, &header.field), "symbol".into(), scope);
            }
            for modifier in &header.modifiers {
                self.emit(child(&loc, &modifier.field), "true".into(), scope);
            }
        }
        for part in parts {
            match part {
                Part::Block { scope: block } | Part::Options { scope: block }
                    if scope == self.schema.root =>
                {
                    self.declaration = block.clone();
                    self.scope(block, &loc);
                    self.declaration = scope.to_owned();
                }
                Part::Block { scope } | Part::Options { scope } => self.scope(scope, &loc),
                Part::Value {
                    rule, value_type, ..
                } => self.value(scope, value_type.as_ref().unwrap_or(rule), &loc),
                _ => {}
            }
        }
    }

    // the fields, items and spread scopes inside a value, which are settings of their own
    fn value(&mut self, scope: &str, rule: &str, loc: &[String]) {
        let types = &self.schema.value_types;
        if !self.values.insert(rule.to_owned()) {
            return;
        }
        match types.get(rule) {
            Some(ValueShape::Record { forms, .. }) => {
                for part in forms.iter().flat_map(|form| &form.parts) {
                    if let RecordPart::Field { name, naming, .. }
                    | RecordPart::Body { name, naming, .. } = part
                    {
                        if let Naming::Label(id) = naming {
                            self.labels.insert(id.clone());
                        }
                        if *naming == Naming::Fallback
                            || !name.chars().any(|c| c.is_ascii_alphanumeric())
                        {
                            self.unnamed
                                .entry((rule.to_owned(), name.clone()))
                                .or_insert_with(|| child(loc, name));
                        }
                    }
                    match part {
                        RecordPart::Field { name, rule, .. } => {
                            let field = child(loc, name);
                            self.emit(field.clone(), describe(types, 0, rule), scope);
                            self.value(scope, rule, &field);
                        }
                        RecordPart::Body { name, .. } => {
                            self.emit(child(loc, name), "native BIRD text".into(), scope);
                        }
                        RecordPart::Spread { scope } => self.scope(scope, loc),
                        RecordPart::Literal { .. } => {}
                    }
                }
            }
            Some(ValueShape::List { item_rule, .. }) => {
                self.value(scope, item_rule, &child(loc, "*"));
            }
            Some(ValueShape::Choice { alternatives, .. }) => {
                for alternative in alternatives {
                    self.value(scope, alternative, loc);
                }
            }
            _ => {}
        }
        self.values.remove(rule);
    }
}

fn child(loc: &[String], name: &str) -> Vec<String> {
    let mut loc = loc.to_vec();
    loc.push(name.to_owned());
    loc
}

// the runtime's describeValue, which names the expected value in its errors
fn describe(types: &BTreeMap<String, ValueShape>, depth: usize, name: &str) -> String {
    match &types[name] {
        ValueShape::Primitive { representation, .. } => serde_json::to_value(representation)
            .ok()
            .and_then(|value| value.as_str().map(str::to_owned))
            .unwrap_or_default(),
        ValueShape::Enum { values, .. } => format!(
            "one of {}",
            values.keys().cloned().collect::<Vec<_>>().join(", ")
        ),
        ValueShape::Record { forms, .. } => {
            let mut fields = Vec::new();
            for part in forms.iter().flat_map(|form| &form.parts) {
                if let RecordPart::Field { name, .. } | RecordPart::Body { name, .. } = part
                    && !fields.contains(name)
                {
                    fields.push(name.clone());
                }
            }
            format!("{{ {} }}", fields.join(", "))
        }
        ValueShape::List { item_rule, .. } if depth <= 1 => {
            format!("[ {} ]", describe(types, depth + 1, item_rule))
        }
        ValueShape::List { .. } => "a list".into(),
        ValueShape::Choice { alternatives, .. } if depth <= 1 => {
            let mut texts = Vec::new();
            for alternative in alternatives {
                let text = describe(types, depth + 1, alternative);
                if !texts.contains(&text) {
                    texts.push(text);
                }
            }
            texts.join(" or ")
        }
        ValueShape::Choice { .. } => "one of several forms".into(),
        ValueShape::Body { .. } => "native BIRD text".into(),
        ValueShape::Constructor { id, .. } => format!("bird.{id} [ ... ]"),
        ValueShape::Exact { rule, .. } => format!("an exact {{ _rule = \"{rule}\"; }} node"),
    }
}

#[cfg(test)]
mod tests {
    use super::super::fixtures::keywords;
    use super::*;
    use crate::grammar::parse;

    fn pair_schema() -> Schema {
        let grammar = parse("%union { int i; }\n%token END LIMIT\n%token <i> NUM\n%type <i> expr pair\n%start config\n%%\nconfig: entries END; entries: | entries conf;\nconf: LIMIT pair ';';\npair: expr '/' expr;\nexpr: NUM;\n%%").unwrap();
        crate::surface::compile(&grammar, &keywords(&["LIMIT"]))
    }

    fn name_field(schema: &mut Schema, record: &str, field: &str, given: Naming) {
        let Some(ValueShape::Record { forms, .. }) = schema.value_types.get_mut(record) else {
            panic!("expected a record {record}");
        };
        for part in forms.iter_mut().flat_map(|form| &mut form.parts) {
            if let RecordPart::Field { name, naming, .. } = part
                && name == field
            {
                *naming = given.clone();
            }
        }
    }

    #[test]
    fn names_collect_the_labels_reachable_settings_use() {
        let mut schema = pair_schema();
        assert_eq!(names(&schema).labels, BTreeSet::new());
        name_field(
            &mut schema,
            "pair",
            "expr",
            Naming::Label("pair.low".into()),
        );
        schema.value_types.insert(
            "$unreachable".into(),
            ValueShape::Record {
                forms: vec![super::super::RecordForm {
                    parts: vec![RecordPart::Field {
                        name: "low".into(),
                        rule: "expr".into(),
                        optional: false,
                        naming: Naming::Label("stale".into()),
                    }],
                }],
                nullable: false,
                merge: crate::registry::Merge::Replace,
            },
        );
        assert_eq!(
            names(&schema).labels,
            BTreeSet::from(["pair.low".to_owned()])
        );
    }

    #[test]
    fn names_report_fields_named_after_their_symbol_or_punctuation() {
        let mut schema = pair_schema();
        let unnamed = names(&schema).unnamed;
        assert_eq!(
            unnamed.keys().cloned().collect::<Vec<_>>(),
            [
                ("pair".to_owned(), "/".to_owned()),
                ("pair".to_owned(), "expr".to_owned()),
            ]
        );
        assert_eq!(unnamed[&("pair".into(), "expr".into())], ["limit", "expr"]);
        name_field(
            &mut schema,
            "pair",
            "expr",
            Naming::Label("pair.low".into()),
        );
        assert_eq!(
            names(&schema).unnamed.keys().cloned().collect::<Vec<_>>(),
            [("pair".to_owned(), "/".to_owned())]
        );
    }

    #[test]
    fn settings_follow_blocks_names_records_and_lists() {
        let grammar = parse("%union { int i; }\n%token END PROTOCOL DEMO HOLD TIME NETWORKS HIDDEN\n%token <i> NUM\n%type <i> expr\n%start config\n%%\nconfig: entries END; entries: | entries conf;\nconf: PROTOCOL DEMO expr '{' opts '}';\nopts: | opts opt ';';\nopt: HOLD TIME expr | NETWORKS '{' nets '}';\nnets: | nets net;\nnet: expr ';' | expr HIDDEN ';';\nexpr: NUM;\n%%").unwrap();
        let schema = crate::surface::compile(
            &grammar,
            &keywords(&["PROTOCOL", "DEMO", "HOLD", "TIME", "NETWORKS", "HIDDEN"]),
        );
        let found = settings(&schema)
            .into_iter()
            .map(|setting| (setting.loc.join("."), setting.types))
            .collect::<BTreeMap<_, _>>();
        assert_eq!(
            found.keys().map(String::as_str).collect::<Vec<_>>(),
            [
                "protocol-demo.<name>",
                "protocol-demo.<name>.hold-time",
                "protocol-demo.<name>.networks",
                "protocol-demo.<name>.networks.*.expr",
                "protocol-demo.<name>.networks.*.hidden",
            ]
        );
        assert_eq!(
            found["protocol-demo.<name>"],
            BTreeSet::from(["an attribute set of settings".into()])
        );
        assert_eq!(
            found["protocol-demo.<name>.networks.*.hidden"],
            BTreeSet::from(["one of true".into()])
        );
    }
}
