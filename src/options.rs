use crate::Inventory;
use crate::grammar::{Location, Symbol};
use crate::values::{Setting, settings};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet, VecDeque};

// the NixOS options.json entry that nuschtos search indexes
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OptionDoc {
    pub declarations: Vec<String>,
    pub description: String,
    pub loc: Vec<String>,
    pub read_only: bool,
    pub r#type: String,
}

pub struct Options {
    pub options: BTreeMap<String, OptionDoc>,
    pub undocumented: usize,
}

// one entry of BIRD's manual, `<tag><label id="ID">syntax</tag>` and the text after it
#[derive(Debug, PartialEq, Eq)]
struct Entry {
    syntax: String,
    text: String,
}

// every setting with its expected value, the manual entry its path matches and its grammar rule
// `source_url` is where the grammar files are browsable, such as a GitHub blob URL at the pinned commit
pub fn options(inventory: &Inventory, sgml: &str, source_url: &str) -> Options {
    let manual = manual(sgml);
    let mut options = BTreeMap::new();
    let mut undocumented = 0;
    let include = Setting {
        loc: vec![inventory.lexer_include.keyword.to_owned()],
        types: BTreeSet::from(["[ filename or glob ]".into()]),
        scopes: BTreeSet::new(),
        same_as: None,
        keywords: Vec::new(),
    };
    for setting in settings(&inventory.schema).into_iter().chain([include]) {
        let entry = lookup(&manual, &setting.loc);
        // a field such as `log.filename` points at the nearest setting the manual describes
        let parent = || {
            (1..setting.loc.len()).rev().find_map(|end| {
                let loc = &setting.loc[..end];
                lookup(&manual, loc).map(|entry| (loc, entry))
            })
        };
        let mut description = match (entry, entry.is_none().then(parent).flatten()) {
            (Some(entry), _) => format!("{}\n\n{}", entry.syntax, entry.text),
            (None, Some((loc, entry))) => {
                format!("Part of `{}`, {}.", loc.join("."), entry.syntax)
            }
            (None, None) => {
                undocumented += 1;
                String::new()
            }
        };
        if let Some(first) = &setting.same_as {
            description.push_str(&format!(
                "\n\nTakes the settings listed under `{}`.",
                first.join(".")
            ));
        }
        let sources = match declaration(inventory, &setting) {
            Some(source) => vec![source],
            None => setting
                .scopes
                .iter()
                .filter_map(|scope| {
                    let rule = scope.strip_suffix("[]").unwrap_or(scope);
                    inventory.grammar.rules.get(rule).map(|rule| &rule.source)
                })
                .collect(),
        };
        for source in sources {
            description.push_str(&format!(
                "\n\nGrammar: [{}:{}]({source_url}{}#L{})",
                source.file, source.line, source.file, source.line
            ));
        }
        options.insert(
            setting.loc.join("."),
            OptionDoc {
                declarations: vec!["lib/router/bird/module.nix".into()],
                description: description.trim().to_owned(),
                loc: setting.loc,
                read_only: false,
                r#type: setting.types.into_iter().collect::<Vec<_>>().join(" or "),
            },
        );
    }
    Options {
        options,
        undocumented,
    }
}

// the production holding the statement's keyword tokens in a row, in the rule nearest its scope
fn declaration<'a>(inventory: &'a Inventory, setting: &Setting) -> Option<&'a Location> {
    let grammar = &inventory.grammar;
    let tokens = setting
        .keywords
        .iter()
        .map(|spelling| {
            inventory
                .keywords
                .iter()
                .find(|keyword| &keyword.spelling == spelling)
                .map(|keyword| Symbol::Reference(keyword.token.clone()))
        })
        .collect::<Option<Vec<_>>>()?;
    if tokens.is_empty() {
        return None;
    }
    // `IMPORT` in `IMPORT TABLE bool` is the start of another setting
    let keyword = |symbol: Option<&Symbol>| matches!(symbol, Some(Symbol::Reference(name)) if inventory.keywords.iter().any(|keyword| &keyword.token == name));
    let declares = |symbols: &[Symbol]| {
        (0..=symbols.len().saturating_sub(tokens.len())).any(|start| {
            let end = start + tokens.len();
            symbols.get(start..end) == Some(tokens.as_slice())
                && !keyword(start.checked_sub(1).and_then(|before| symbols.get(before)))
                && !keyword(symbols.get(end))
        })
    };
    let scope = setting.scopes.first()?;
    let mut pending = VecDeque::from([scope.strip_suffix("[]").unwrap_or(scope)]);
    let mut seen = BTreeSet::new();
    while let Some(name) = pending.pop_front() {
        let Some(rule) = grammar.rules.get(name) else {
            continue;
        };
        if !seen.insert(name) {
            continue;
        }
        if let Some(production) = rule
            .productions
            .iter()
            .find(|production| declares(&production.symbols))
        {
            return Some(&production.source);
        }
        for production in &rule.productions {
            for symbol in &production.symbols {
                if let Symbol::Reference(next) = symbol {
                    pending.push_back(next);
                }
            }
        }
    }
    None
}

// manual ids are a context and the option's words, as in `bgp-hold-time`, `proto-import` and `static-route-weight`
fn lookup<'a>(manual: &'a BTreeMap<String, Entry>, loc: &[String]) -> Option<&'a Entry> {
    let words = |segments: &[String]| {
        segments
            .iter()
            .filter(|segment| !matches!(segment.as_str(), "<name>" | "*"))
            .cloned()
            .collect::<Vec<_>>()
    };
    let (mut contexts, mut segments) = match loc {
        [head, kind, ..] if head == "protocol" || head == "template" => {
            let name = loc
                .iter()
                .position(|segment| segment == "<name>")
                .map_or(loc.len(), |index| index + 1);
            let inner = &loc[name..];
            let mut contexts = Vec::new();
            if inner.iter().any(|segment| segment == "flow6") {
                contexts.push("flow6".to_owned());
            }
            if inner
                .iter()
                .any(|segment| segment == "flow4" || segment == "flow6")
            {
                contexts.push("flow".into());
            }
            contexts.push(if kind == "kernel" {
                "krt".into()
            } else {
                kind.clone()
            });
            contexts.extend(["proto", "channel", "mpls-channel"].map(str::to_owned));
            (contexts, words(inner))
        }
        [_, table, ..] if table == "table" => (vec!["rtable".into()], words(&loc[2..])),
        [head, ..] if head == "thread-group" || head == "mpls-domain" => (
            vec![head.clone(), head.split('-').next().unwrap().to_owned()],
            words(&loc[1..]),
        ),
        _ => (vec!["opt".into()], words(loc)),
    };
    // a declaration itself, such as `protocol.bgp.<name>`, is documented under its keyword
    if segments.is_empty() {
        contexts = vec!["opt".into()];
        segments = vec![loc[0].clone()];
        if loc.get(1).is_some_and(|segment| segment == "table") {
            segments = vec!["table".into()];
        }
    }
    let find = |key: &str| {
        contexts
            .iter()
            .find_map(|context| manual.get(&format!("{context}-{key}")))
    };
    (0..segments.len())
        .find_map(|start| find(&segments[start..].join("-")))
        .or_else(|| {
            // a setting named past its manual entry, such as `timeformat-route` under `opt-timeformat`
            let words = segments.last()?.split('-').collect::<Vec<_>>();
            (1..words.len())
                .rev()
                .find_map(|end| find(&words[..end].join("-")))
        })
}

fn manual(sgml: &str) -> BTreeMap<String, Entry> {
    let mut entries = BTreeMap::new();
    for chunk in sgml.split("<tag><label id=\"").skip(1) {
        let Some((id, rest)) = chunk.split_once("\">") else {
            continue;
        };
        let Some((syntax, rest)) = rest.split_once("</tag>") else {
            continue;
        };
        let end = ["<tag>", "</descrip>", "<sect", "<chapt"]
            .iter()
            .filter_map(|marker| rest.find(marker))
            .min()
            .unwrap_or(rest.len());
        entries.entry(id.to_owned()).or_insert_with(|| Entry {
            syntax: markdown(syntax),
            text: markdown(&rest[..end]),
        });
    }
    entries
}

// LinuxDoc SGML to Markdown, for the subset BIRD's manual uses
fn markdown(sgml: &str) -> String {
    let mut out = String::new();
    let mut code = false;
    let mut rest = sgml;
    while let Some(start) = rest.find('<') {
        text(&mut out, &rest[..start], code);
        rest = &rest[start + 1..];
        let closing = rest.starts_with('/');
        let name_start = usize::from(closing);
        let name_len = rest[name_start..]
            .find(|c: char| !c.is_ascii_alphanumeric())
            .unwrap_or(rest.len() - name_start);
        let name = &rest[name_start..name_start + name_len];
        let after = &rest[name_start + name_len..];
        if name.is_empty() {
            out.push('<');
            continue;
        }
        // short form `<cf/text/`
        if !closing && let Some(short) = after.strip_prefix('/') {
            let (content, tail) = short.split_once('/').unwrap_or((short, ""));
            let content = decode(content);
            out.push_str(&match name {
                "cf" | "tt" | "file" => format!("`{content}`"),
                "m" | "it" | "em" => format!("*{content}*"),
                "bf" => format!("**{content}**"),
                _ => content,
            });
            rest = tail;
            continue;
        }
        let Some(close) = after.find('>') else {
            out.push('<');
            continue;
        };
        let attributes = &after[..close];
        rest = &after[close + 1..];
        let attribute = |key: &str| {
            let (_, value) = attributes.split_once(&format!("{key}=\""))?;
            value.split_once('"').map(|(value, _)| value.to_owned())
        };
        match (name, closing) {
            ("code" | "verb" | "tscreen", false) => {
                out.push_str("\n\n```\n");
                code = true;
            }
            ("code" | "verb" | "tscreen", true) => {
                out.truncate(out.trim_end().len());
                out.push_str("\n```\n\n");
                code = false;
            }
            ("cf" | "tt" | "file", _) => out.push('`'),
            ("m" | "it" | "em", _) => out.push('*'),
            ("bf", _) => out.push_str("**"),
            ("p" | "itemize" | "enum" | "descrip", _) => out.push_str("\n\n"),
            ("item", false) => out.push_str("\n- "),
            ("ref", false) => out.push_str(
                &attribute("name")
                    .or_else(|| attribute("id"))
                    .unwrap_or_default(),
            ),
            ("rfc", false) => out.push_str(&format!("RFC {}", attribute("id").unwrap_or_default())),
            ("htmlurl" | "url", false) => {
                let url = attribute("url").unwrap_or_default();
                let label = attribute("name").unwrap_or_else(|| url.clone());
                out.push_str(&format!("[{label}]({url})"));
            }
            ("label" | "tag" | "item" | "ref" | "rfc" | "htmlurl" | "url", _) => {}
            // placeholders such as `<number>` in syntax summaries
            (_, false) => out.push_str(&format!("*{name}*")),
            (_, true) => {}
        }
    }
    text(&mut out, rest, code);
    let mut result = String::new();
    let mut blank = 0;
    let mut fenced = false;
    for line in out.lines() {
        let fence = line.trim() == "```";
        // code keeps its lines, blank ones included
        if fenced && !fence {
            result.push('\n');
            result.push_str(line);
            continue;
        }
        let line = line.trim();
        if line.is_empty() {
            blank += 1;
            continue;
        }
        if !result.is_empty() {
            result.push_str(if blank > 0 && !fenced { "\n\n" } else { "\n" });
        }
        blank = 0;
        result.push_str(line);
        fenced ^= fence;
    }
    result
}

fn text(out: &mut String, text: &str, code: bool) {
    let text = decode(text);
    if code {
        // the code starts on the line after its fence
        let text = if out.ends_with("```\n") {
            text.trim_start_matches('\n')
        } else {
            &text
        };
        out.push_str(text);
        return;
    }
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        if !text.is_empty() && !out.ends_with([' ', '\n']) {
            out.push(' ');
        }
        return;
    }
    if text.starts_with(char::is_whitespace) && !out.ends_with([' ', '\n']) {
        out.push(' ');
    }
    out.push_str(&collapsed);
    if text.ends_with(char::is_whitespace) {
        out.push(' ');
    }
}

fn decode(text: &str) -> String {
    text.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&ndash;", "-")
        .replace("&tilde;", "~")
        .replace("&verbar;", "|")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manual_entries_become_markdown_keyed_by_label() {
        let entries = manual(
            "<descrip>\n\t<tag><label id=\"bgp-hold-time\">hold time <m/number/</tag>\n\tTime in seconds, see <ref id=\"bgp-keepalive\" name=\"keepalive time\"> and <rfc id=\"4271\">.\n\tUse <cf/hold time 30/ or <cf>off</cf>.<p>Default: 240.\n\n\t<tag><label id=\"proto-import\">import all | none</tag>\n\tImport filter, for example\n<code>\nimport all;\n</code>\n</descrip>",
        );
        assert_eq!(
            entries["bgp-hold-time"],
            Entry {
                syntax: "hold time *number*".into(),
                text: "Time in seconds, see keepalive time and RFC 4271. Use `hold time 30` or `off`.\n\nDefault: 240.".into(),
            }
        );
        assert_eq!(
            entries["proto-import"].text,
            "Import filter, for example\n\n```\nimport all;\n```"
        );
    }

    #[test]
    fn settings_find_their_entry_by_protocol_generic_and_root_context() {
        let entry = |text: &str| Entry {
            syntax: text.into(),
            text: String::new(),
        };
        let manual = BTreeMap::from([
            ("bgp-hold-time".to_owned(), entry("bgp")),
            ("proto-import".to_owned(), entry("import")),
            ("static-route-weight".to_owned(), entry("weight")),
            ("krt-learn".to_owned(), entry("learn")),
            ("opt-timeformat".to_owned(), entry("timeformat")),
            ("opt-protocol".to_owned(), entry("protocol")),
            ("rtable-sorted".to_owned(), entry("sorted")),
            ("flow-dst".to_owned(), entry("dst")),
        ]);
        let find = |path: &str| {
            let loc = path.split('.').map(str::to_owned).collect::<Vec<_>>();
            lookup(&manual, &loc).map(|entry| entry.syntax.clone())
        };
        assert_eq!(
            find("protocol.bgp.<name>.hold-time").as_deref(),
            Some("bgp")
        );
        assert_eq!(
            find("template.bgp.<name>.ipv4.import").as_deref(),
            Some("import")
        );
        assert_eq!(
            find("protocol.static.<name>.route.*.weight").as_deref(),
            Some("weight")
        );
        assert_eq!(
            find("protocol.kernel.<name>.learn").as_deref(),
            Some("learn")
        );
        assert_eq!(find("timeformat-route").as_deref(), Some("timeformat"));
        assert_eq!(find("protocol.bgp.<name>").as_deref(), Some("protocol"));
        assert_eq!(find("ipv4.table.<name>.sorted").as_deref(), Some("sorted"));
        assert_eq!(
            find("protocol.static.<name>.route.*.prefix.flow4.dst").as_deref(),
            Some("dst")
        );
        assert_eq!(find("protocol.bgp.<name>.neighbor"), None);
    }
}
