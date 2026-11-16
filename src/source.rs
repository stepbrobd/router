use crate::grammar::{Error, Location};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Clone, Debug, Serialize)]
pub struct SourceFile {
    pub path: String,
    pub sha256: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct Source {
    pub version: String,
    pub fingerprint: String,
    pub fingerprint_algorithm: &'static str,
    pub target: &'static str,
    pub license: &'static str,
    pub attribution: &'static str,
    pub grammar_inputs: Vec<String>,
    pub files: Vec<SourceFile>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Keyword {
    pub spelling: String,
    pub token: String,
    pub source: Location,
}

#[derive(Clone, Debug, Serialize)]
pub struct Include {
    pub keyword: &'static str,
    pub argument: &'static str,
    pub source: Location,
    pub expanded_by: &'static str,
    pub compiler_reads_targets: bool,
}

pub struct Assembly {
    pub source: Source,
    pub parser: String,
    pub keywords: Vec<Keyword>,
    pub include: Include,
    pub facts: BTreeMap<String, String>,
    // identifiers in conf/cf-lex.l, which name every non-keyword token the lexer can emit
    pub lexer_words: BTreeSet<String>,
}

fn error(file: &str, line: usize, message: impl Into<String>) -> Error {
    Error::at(
        Location {
            file: file.into(),
            line,
        },
        message,
    )
}

fn load(
    root: &Path,
    relative: &str,
    files: &mut BTreeMap<String, String>,
) -> Result<String, Error> {
    let text = fs::read_to_string(root.join(relative))
        .map_err(|e| Error::in_file(relative, e.to_string()))?;
    files.insert(relative.into(), fingerprint(text.as_bytes()));
    Ok(text)
}

fn fingerprint(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn logical_lines(text: &str) -> Vec<(usize, String)> {
    let mut result = Vec::new();
    let mut line = String::new();
    let mut start = 1;
    for (index, part) in text.lines().enumerate() {
        if line.is_empty() {
            start = index + 1;
        }
        if let Some(part) = part.strip_suffix('\\') {
            line.push_str(part);
            line.push(' ');
        } else {
            line.push_str(part);
            result.push((start, std::mem::take(&mut line)));
        }
    }
    if !line.is_empty() {
        result.push((start, line));
    }
    result
}

fn expand_shell(
    value: &str,
    variables: &BTreeMap<String, String>,
    file: &str,
    line: usize,
) -> Result<String, Error> {
    let mut result = String::new();
    let mut rest = value;
    while let Some(offset) = rest.find('$') {
        result.push_str(&rest[..offset]);
        rest = &rest[offset + 1..];
        let count = rest
            .bytes()
            .take_while(|b| b.is_ascii_alphanumeric() || *b == b'_')
            .count();
        let name = &rest[..count];
        let replacement = variables.get(name).ok_or_else(|| {
            error(
                file,
                line,
                format!(
                    "unsupported build variable ${name}, cannot determine Linux grammar inputs"
                ),
            )
        })?;
        result.push_str(replacement);
        rest = &rest[count..];
    }
    result.push_str(rest);
    Ok(result)
}

fn make_text(line: &str) -> &str {
    line.split('#').next().unwrap_or("").trim()
}

fn manifest_inputs(
    dir: &str,
    lines: &[(usize, String)],
    local: &str,
    file: &str,
) -> Result<Vec<String>, Error> {
    let mut result = Vec::new();
    let mut conditions = 0_usize;
    for (line, raw) in lines {
        let text = make_text(raw);
        if ["ifdef ", "ifndef ", "ifeq ", "ifneq ", "ifeq(", "ifneq("]
            .iter()
            .any(|prefix| text.starts_with(prefix))
        {
            conditions += 1;
            continue;
        }
        if text == "endif" {
            conditions = conditions
                .checked_sub(1)
                .ok_or_else(|| error(file, *line, "unmatched Make endif"))?;
            continue;
        }
        if text == "else" || text.starts_with("else ") {
            if conditions == 0 {
                return Err(error(file, *line, "unmatched Make else"));
            }
            continue;
        }
        if text.starts_with("cf-local =") || text.starts_with("conf-y-targets :=") {
            if conditions != 0 {
                return Err(error(
                    file,
                    *line,
                    "conditional grammar manifests require an explicit build profile",
                ));
            }
            continue;
        }
        let dependencies = if text == "$(cf-local)" {
            Some(local)
        } else if let Some(dependencies) = text.strip_prefix("$(conf-y-targets):") {
            Some(dependencies)
        } else {
            if text.contains("cf-local")
                || (text.contains("conf-y-targets") && !text.contains("$(M4)"))
            {
                return Err(error(
                    file,
                    *line,
                    "unsupported grammar manifest statement, refusing to omit inputs",
                ));
            }
            None
        };
        if let Some(dependencies) = dependencies {
            if conditions != 0 {
                return Err(error(
                    file,
                    *line,
                    "conditional grammar dependencies require an explicit build profile",
                ));
            }
            for input in dependencies.split_whitespace() {
                let Some(input) = input.strip_prefix("$(s)") else {
                    return Err(error(
                        file,
                        *line,
                        format!("unsupported grammar dependency {input}"),
                    ));
                };
                if !input.ends_with(".Y") {
                    return Err(error(
                        file,
                        *line,
                        format!("unsupported grammar dependency {input}"),
                    ));
                }
                result.push(if dir.is_empty() {
                    input.into()
                } else {
                    format!("{dir}/{input}")
                });
            }
        }
    }
    if conditions != 0 {
        return Err(error(
            file,
            lines.last().map_or(1, |entry| entry.0),
            "unterminated Make conditional",
        ));
    }
    Ok(result)
}

fn manifests(root: &Path, files: &mut BTreeMap<String, String>) -> Result<Vec<String>, Error> {
    let configure = load(root, "configure.ac", files)?;
    let mut linux = false;
    let mut variables = BTreeMap::new();
    let mut protocols = None;
    for (line, raw) in logical_lines(&configure) {
        let text = raw.trim();
        if text == "linux*)" {
            linux = true;
            continue;
        }
        if linux && text == ";;" {
            linux = false;
        }
        if linux
            && let Some((name, value)) = text.split_once('=')
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
        {
            variables.insert(name.to_owned(), value.trim_matches('"').to_owned());
        }
        if let Some(value) = text
            .strip_prefix("all_protocols=\"")
            .and_then(|s| s.strip_suffix('"'))
        {
            protocols = Some(expand_shell(value, &variables, "configure.ac", line)?);
        }
    }
    let protocols = protocols.ok_or_else(|| {
        Error::in_file(
            "configure.ac",
            "missing literal all_protocols build manifest",
        )
    })?;
    let sysdep = load(root, "sysdep/cf/linux.h", files)?;
    let linked = sysdep
        .lines()
        .filter_map(|line| line.strip_prefix("Link: "))
        .flat_map(str::split_whitespace)
        .collect::<Vec<_>>();
    if linked.is_empty() {
        return Err(Error::in_file(
            "sysdep/cf/linux.h",
            "missing Link: build manifest",
        ));
    }
    let makefile = load(root, "Makefile.in", files)?;
    let root_lines = logical_lines(&makefile);
    let dirs = root_lines
        .iter()
        .find_map(|(line, text)| {
            make_text(text)
                .strip_prefix("dirs := ")
                .map(|value| (*line, value.to_owned()))
        })
        .ok_or_else(|| Error::in_file("Makefile.in", "missing dirs build manifest"))?;
    let local_definitions = root_lines
        .iter()
        .filter_map(|(line, text)| {
            make_text(text)
                .strip_prefix("cf-local =")
                .map(|value| (*line, value.trim()))
        })
        .collect::<Vec<_>>();
    let [(local_line, local)] = local_definitions.as_slice() else {
        return Err(Error::in_file(
            "Makefile.in",
            "expected one cf-local grammar dependency definition",
        ));
    };
    let local = local.strip_prefix("$(conf-y-targets):").ok_or_else(|| {
        error(
            "Makefile.in",
            *local_line,
            "unsupported cf-local grammar dependency definition",
        )
    })?;
    let expanded = dirs
        .1
        .replace(
            "$(addprefix proto/,$(protocols))",
            &protocols
                .split_whitespace()
                .map(|name| format!("proto/{name}"))
                .collect::<Vec<_>>()
                .join(" "),
        )
        .replace("@sysdep_dirs@", &linked.join(" "));
    if expanded.contains('$') || expanded.contains('@') {
        return Err(error(
            "Makefile.in",
            dirs.0,
            "unsupported dirs expression, refusing to mix build targets",
        ));
    }
    let mut grammar = manifest_inputs("", &root_lines, local, "Makefile.in")?;
    let mut seen = grammar.iter().cloned().collect::<BTreeSet<_>>();
    for dir in expanded.split_whitespace() {
        let path = format!("{dir}/Makefile");
        let manifest = load(root, &path, files)?;
        for input in manifest_inputs(dir, &logical_lines(&manifest), local, &path)? {
            if seen.insert(input.clone()) {
                grammar.push(input);
            }
        }
    }
    if grammar.is_empty() {
        return Err(error(
            "Makefile.in",
            dirs.0,
            "build manifest selects no grammar inputs",
        ));
    }
    Ok(grammar)
}

fn assemble(root: &Path, generator: &str, inputs: &[String]) -> Result<String, Error> {
    let executable = std::env::var_os("M4").unwrap_or_else(|| "m4".into());
    let output = Command::new(executable)
        .current_dir(root)
        .args(["--fatal-warnings", "-s", "-P", generator])
        .args(inputs)
        .output()
        .map_err(|e| {
            Error::in_file(
                generator,
                format!("cannot execute GNU m4: {e}, provide m4 on PATH or set M4"),
            )
        })?;
    if !output.status.success() {
        return Err(Error::in_file(
            generator,
            format!(
                "GNU m4 assembly failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        ));
    }
    String::from_utf8(output.stdout)
        .map_err(|e| Error::in_file(generator, format!("m4 emitted invalid UTF-8: {e}")))
}

fn keywords(input: &str) -> Result<Vec<Keyword>, Error> {
    let mut source = Location {
        file: "conf/gen_keywords.m4".into(),
        line: 1,
    };
    let mut result = Vec::new();
    for line in input.lines() {
        if let Some(value) = line.strip_prefix("#line ") {
            let (number, file) = value.split_once(' ').unwrap_or((value, ""));
            source.line = number
                .parse()
                .map_err(|_| error(&source.file, source.line, "invalid keyword #line directive"))?;
            if !file.is_empty() {
                source.file = file.trim_matches('"').into();
            }
            continue;
        }
        let text = line.trim();
        if let Some(rest) = text.strip_prefix("{ \"") {
            let Some((spelling, rest)) = rest.split_once("\",") else {
                return Err(error(
                    &source.file,
                    source.line,
                    "unsupported keyword initializer",
                ));
            };
            let token = rest
                .trim()
                .strip_suffix("},")
                .or_else(|| rest.trim().strip_suffix('}'))
                .ok_or_else(|| error(&source.file, source.line, "unsupported keyword initializer"))?
                .trim();
            result.push(Keyword {
                spelling: spelling.into(),
                token: token.into(),
                source: source.clone(),
            });
        }
        source.line += 1;
    }
    if result.is_empty() {
        return Err(Error::in_file(
            "conf/gen_keywords.m4",
            "m4 emitted no keyword inventory",
        ));
    }
    Ok(result)
}

fn lexer_keywords(input: &str) -> Vec<Keyword> {
    let lines = input.lines().collect::<Vec<_>>();
    let mut section = 0;
    let mut result = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        if *line == "%%" {
            section += 1;
            continue;
        }
        if section != 1 || line.starts_with(char::is_whitespace) {
            continue;
        }
        let Some((pattern, action)) = line.split_once(char::is_whitespace) else {
            continue;
        };
        let eof = pattern.starts_with("<INITIAL") && pattern.ends_with("<<EOF>>");
        let spelling = if eof {
            Some(String::new())
        } else {
            let mut chars = pattern.chars();
            let mut spelling = String::new();
            let mut literal = true;
            while let Some(character) = chars.next() {
                if character == '\\' {
                    if let Some(character) = chars.next() {
                        spelling.push(character);
                    } else {
                        literal = false;
                        break;
                    }
                } else if character.is_ascii_alphanumeric() || matches!(character, '_' | ':') {
                    spelling.push(character);
                } else {
                    literal = false;
                    break;
                }
            }
            literal.then_some(spelling)
        };
        let Some(spelling) = spelling else {
            continue;
        };
        let mut action = action.to_owned();
        if action.trim() == "{" {
            for line in &lines[index + 1..] {
                action.push('\n');
                action.push_str(line);
                if line.trim() == "}" {
                    break;
                }
            }
        }
        let Some((_, returned)) = action.split_once("return ") else {
            continue;
        };
        let Some((token, _)) = returned.split_once(';') else {
            continue;
        };
        let token = token.trim();
        if token.is_empty()
            || !token
                .bytes()
                .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
        {
            continue;
        }
        result.push(Keyword {
            spelling,
            token: token.into(),
            source: Location {
                file: "conf/cf-lex.l".into(),
                line: index + 1,
            },
        });
    }
    result
}

pub fn read(root: &Path) -> Result<Assembly, Error> {
    let root: PathBuf = root
        .canonicalize()
        .map_err(|e| Error::in_file(root.display().to_string(), e.to_string()))?;
    let mut files = BTreeMap::new();
    let inputs = manifests(&root, &mut files)?;
    let mut facts = BTreeMap::new();
    for path in &inputs {
        facts.insert(path.clone(), load(&root, path, &mut files)?);
    }
    let directories = inputs
        .iter()
        .filter_map(|path| Path::new(path).parent())
        .collect::<BTreeSet<_>>();
    for directory in directories {
        let entries = fs::read_dir(root.join(directory))
            .map_err(|e| Error::in_file(directory.display().to_string(), e.to_string()))?;
        let mut paths = entries
            .map(|entry| entry.map(|entry| directory.join(entry.file_name())))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| Error::in_file(directory.display().to_string(), e.to_string()))?;
        paths.sort();
        for path in paths {
            if path.extension().is_some_and(|extension| extension == "c") {
                let relative = path.to_string_lossy().into_owned();
                facts.insert(relative.clone(), load(&root, &relative, &mut files)?);
            }
        }
    }
    for path in ["conf/gen_parser.m4", "conf/gen_keywords.m4"] {
        load(&root, path, &mut files)?;
    }
    let lexer = load(&root, "conf/cf-lex.l", &mut files)?;
    let include_line = lexer
        .lines()
        .position(|line| line.starts_with("^{WHITE}*include{WHITE}*\\\""))
        .ok_or_else(|| {
            Error::in_file(
                "conf/cf-lex.l",
                "unsupported include lexer rule, expected a line-anchored quoted include",
            )
        })?
        + 1;
    if !lexer.contains("cf_include(start, end-start)") || !lexer.contains("<INCLUDE>") {
        return Err(error(
            "conf/cf-lex.l",
            include_line,
            "unsupported include lexer implementation",
        ));
    }
    let version = load(&root, "VERSION", &mut files)?.trim().to_owned();
    let parser = assemble(&root, "conf/gen_parser.m4", &inputs)?;
    let keyword_text = assemble(&root, "conf/gen_keywords.m4", &inputs)?;
    let mut keywords = keywords(&keyword_text)?;
    keywords.extend(lexer_keywords(&lexer));
    let mut combined = Sha256::new();
    let source_files = files
        .into_iter()
        .map(|(path, digest)| {
            combined.update(path.as_bytes());
            combined.update([0]);
            combined.update(digest.as_bytes());
            combined.update([0]);
            SourceFile {
                path,
                sha256: digest,
            }
        })
        .collect();
    Ok(Assembly {
        source: Source {
            version,
            fingerprint: format!("{:x}", combined.finalize()),
            fingerprint_algorithm: "sha256",
            target: "linux",
            license: "GPL-2.0-or-later",
            attribution: "BIRD Internet Routing Daemon contributors. Grammar and semantic declarations derive from upstream source, and C actions stay upstream.",
            grammar_inputs: inputs,
            files: source_files,
        },
        parser,
        keywords,
        facts,
        lexer_words: lexer
            .split(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
            .filter(|word| !word.is_empty())
            .map(str::to_owned)
            .collect(),
        include: Include {
            keyword: "include",
            argument: "nonempty double-quoted filename or glob, terminated by semicolon",
            source: Location {
                file: "conf/cf-lex.l".into(),
                line: include_line,
            },
            expanded_by: "BIRD lexer at configuration-check/runtime, never by router",
            compiler_reads_targets: false,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_variables_are_explicit_not_shell_evaluated() {
        let vars = BTreeMap::from([("proto_bridge".into(), "bridge".into())]);
        assert_eq!(
            expand_shell("bgp $proto_bridge ospf", &vars, "configure.ac", 1).unwrap(),
            "bgp bridge ospf"
        );
        assert!(expand_shell("$unknown", &vars, "configure.ac", 12).is_err());
    }

    #[test]
    fn make_comments_do_not_remove_protocol_grammar() {
        let lines = logical_lines("$(cf-local) # protocol grammar\n");
        let inputs =
            manifest_inputs("proto/bgp", &lines, "$(s)config.Y", "proto/bgp/Makefile").unwrap();
        assert_eq!(inputs, vec!["proto/bgp/config.Y"]);
    }

    #[test]
    fn unhandled_and_conditional_grammar_dependencies_fail_closed() {
        let unsupported = manifest_inputs(
            "proto/bgp",
            &logical_lines("$(cf-local) extra\n"),
            "$(s)config.Y",
            "proto/bgp/Makefile",
        )
        .unwrap_err();
        assert_eq!(unsupported.file, "proto/bgp/Makefile");
        assert!(unsupported.message.contains("unsupported grammar manifest"));
        let conditional = manifest_inputs(
            "proto/bgp",
            &logical_lines("ifdef OPTIONAL\n$(cf-local)\nendif\n"),
            "$(s)config.Y",
            "proto/bgp/Makefile",
        )
        .unwrap_err();
        assert!(
            conditional
                .message
                .contains("conditional grammar dependencies")
        );
    }

    #[test]
    fn keyword_provenance_survives_m4_diversions() {
        let inventory = keywords("#line 19 \"proto/new/config.Y\"\n{ \"new_option\", NEW_OPTION },\n{ \"origin_igp\", -((T_ENUM_ORIGIN<<16) | ORIGIN_IGP) },\n").unwrap();
        assert_eq!(inventory[0].source.line, 19);
        assert_eq!(inventory[1].spelling, "origin_igp");
        assert!(inventory[1].token.starts_with("-(("));
    }

    #[test]
    fn literal_lexer_rules_derive_operators_without_promoting_regexes() {
        let inventory = lexer_keywords(
            "%%\n\\!\\= return NEQ;\n\\[\\= return PO;\n[A-Z]+ return WORD;\nelse: {\n return ELSECOL;\n}\n%%\n",
        );
        let tokens = inventory
            .iter()
            .map(|keyword| (keyword.token.as_str(), keyword.spelling.as_str()))
            .collect::<BTreeMap<_, _>>();
        assert_eq!(tokens["NEQ"], "!=");
        assert_eq!(tokens["PO"], "[=");
        assert_eq!(tokens["ELSECOL"], "else:");
        assert!(!tokens.contains_key("WORD"));
    }
}
