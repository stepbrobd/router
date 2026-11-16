use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt;

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Location {
    pub file: String,
    pub line: usize,
}

#[derive(Debug)]
pub struct Error {
    pub file: String,
    // None when the failure belongs to the whole file, such as a read error or a missing manifest.
    pub line: Option<usize>,
    pub message: String,
}

impl Error {
    pub(crate) fn at(source: Location, message: impl Into<String>) -> Self {
        Self {
            file: source.file,
            line: Some(source.line),
            message: message.into(),
        }
    }

    pub(crate) fn in_file(file: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            file: file.into(),
            line: None,
            message: message.into(),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.line {
            Some(line) => write!(f, "{}:{line}: {}", self.file, self.message),
            None => write!(f, "{}: {}", self.file, self.message),
        }
    }
}
impl std::error::Error for Error {}

#[derive(Clone, Debug, Serialize)]
pub struct Action {
    pub position: usize,
    pub source: Location,
    pub storage: Vec<String>,
    pub symbol_classes: Vec<String>,
    // `lhs = $n` assignments, which tie a C field to the value at Bison position n
    #[serde(skip)]
    pub assignments: Vec<(String, usize)>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum Symbol {
    Reference(String),
    Literal(String),
}

#[derive(Clone, Debug, Serialize)]
pub struct Production {
    pub symbols: Vec<Symbol>,
    pub precedence: Option<Symbol>,
    pub actions: Vec<Action>,
    pub source: Location,
}

#[derive(Clone, Debug, Serialize)]
pub struct Rule {
    pub storage_type: Option<String>,
    pub productions: Vec<Production>,
    pub source: Location,
}

#[derive(Clone, Debug, Serialize)]
pub struct Token {
    pub storage_type: Option<String>,
    pub source: Location,
    pub configuration_reachable: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct Declaration {
    pub directive: String,
    pub value: String,
    pub source: Location,
}

#[derive(Clone, Debug, Serialize)]
pub struct Grammar {
    pub start: String,
    pub configuration_start: String,
    pub rules: BTreeMap<String, Rule>,
    pub tokens: BTreeMap<String, Token>,
    pub declarations: Vec<Declaration>,
    pub semantic_storage: String,
    pub excluded_cli_rules: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Kind {
    Word(String),
    Quoted(String),
    Action(String),
    Directive(String),
    Punct(char),
    Newline,
    Section,
}

#[derive(Clone, Debug)]
struct Lexeme {
    kind: Kind,
    source: Location,
}

struct Lexer<'a> {
    input: &'a str,
    position: usize,
    source: Location,
    at_line_start: bool,
}

impl<'a> Lexer<'a> {
    fn new(input: &'a str, file: &str) -> Self {
        Self {
            input,
            position: 0,
            source: Location {
                file: file.into(),
                line: 1,
            },
            at_line_start: true,
        }
    }

    fn error(&self, message: impl Into<String>) -> Error {
        Error::at(self.source.clone(), message)
    }

    fn byte(&self) -> Option<u8> {
        self.input.as_bytes().get(self.position).copied()
    }

    fn starts(&self, value: &str) -> bool {
        self.input.as_bytes()[self.position..].starts_with(value.as_bytes())
    }

    fn advance(&mut self) -> Option<u8> {
        let byte = self.byte()?;
        self.position += 1;
        if byte == b'\n' {
            self.source.line += 1;
            self.at_line_start = true;
        } else if !byte.is_ascii_whitespace() {
            self.at_line_start = false;
        }
        Some(byte)
    }

    fn quoted(&mut self) -> Result<String, Error> {
        let quote = self.advance().unwrap();
        let mut result = String::new();
        loop {
            match self.advance() {
                Some(byte) if byte == quote => return Ok(result),
                Some(b'\\') => match self.advance() {
                    Some(b'n') => result.push('\n'),
                    Some(b'r') => result.push('\r'),
                    Some(b't') => result.push('\t'),
                    Some(byte) => result.push(char::from(byte)),
                    None => return Err(self.error("unterminated escape in quoted string")),
                },
                Some(byte) => result.push(char::from(byte)),
                None => return Err(self.error("unterminated quoted string")),
            }
        }
    }

    fn comment(&mut self) -> Result<(), Error> {
        if self.starts("//") {
            loop {
                while self.byte().is_some_and(|byte| byte != b'\n') {
                    self.advance();
                }
                let continued =
                    self.position > 0 && self.input.as_bytes()[self.position - 1] == b'\\';
                if !continued || self.byte().is_none() {
                    break;
                }
                self.advance();
            }
        } else {
            self.advance();
            self.advance();
            while !self.starts("*/") {
                if self.advance().is_none() {
                    return Err(self.error("unterminated C comment"));
                }
            }
            self.advance();
            self.advance();
        }
        Ok(())
    }

    // C actions are opaque. Only braces outside strings and comments affect nesting.
    fn action(&mut self, prologue: bool) -> Result<String, Error> {
        let start = self.position;
        self.advance();
        if prologue {
            self.advance();
        }
        let mut depth = 1;
        while self.byte().is_some() {
            if prologue && self.starts("%}") {
                self.advance();
                self.advance();
                return Ok(self.input[start..self.position].to_owned());
            }
            if self.starts("/*") || self.starts("//") {
                self.comment()?;
            } else {
                match self.byte().unwrap() {
                    b'\'' | b'"' => {
                        self.quoted()?;
                    }
                    b'{' if !prologue => {
                        depth += 1;
                        self.advance();
                    }
                    b'}' if !prologue => {
                        depth -= 1;
                        self.advance();
                        if depth == 0 {
                            return Ok(self.input[start..self.position].to_owned());
                        }
                    }
                    _ => {
                        self.advance();
                    }
                }
            }
        }
        Err(self.error("unterminated C action"))
    }

    fn sync_line(&mut self) -> Result<bool, Error> {
        if !self.at_line_start || !self.starts("#line ") {
            return Ok(false);
        }
        let end = self.input[self.position..]
            .find('\n')
            .map_or(self.input.len(), |n| self.position + n);
        let directive = &self.input[self.position + 6..end];
        let split = directive
            .find(char::is_whitespace)
            .unwrap_or(directive.len());
        let line = directive[..split]
            .parse::<usize>()
            .map_err(|_| self.error("invalid m4 #line directive"))?;
        let file = directive[split..].trim();
        if !file.is_empty() {
            self.source.file = file
                .strip_prefix('"')
                .and_then(|s| s.strip_suffix('"'))
                .ok_or_else(|| self.error("invalid m4 #line filename"))?
                .to_owned();
        }
        self.position = end;
        if self.byte().is_some() {
            self.position += 1;
        }
        self.source.line = line;
        self.at_line_start = true;
        Ok(true)
    }

    fn next(&mut self) -> Result<Option<Lexeme>, Error> {
        loop {
            if self.sync_line()? {
                continue;
            }
            if self.starts("/*") || self.starts("//") {
                self.comment()?;
                continue;
            }
            match self.byte() {
                Some(byte) if byte.is_ascii_whitespace() && byte != b'\n' => {
                    self.advance();
                }
                _ => break,
            }
        }
        let Some(byte) = self.byte() else {
            return Ok(None);
        };
        let source = self.source.clone();
        let kind = if self.starts("%%") {
            self.advance();
            self.advance();
            Kind::Section
        } else if self.starts("%{") {
            Kind::Action(self.action(true)?)
        } else if byte == b'{' {
            Kind::Action(self.action(false)?)
        } else if byte == b'\'' || byte == b'"' {
            Kind::Quoted(self.quoted()?)
        } else if byte == b'\n' {
            self.advance();
            Kind::Newline
        } else if byte == b'%' {
            self.advance();
            let start = self.position;
            while self
                .byte()
                .is_some_and(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            {
                self.advance();
            }
            if start == self.position {
                return Err(self.error("unexpected '%' outside C action"));
            }
            Kind::Directive(self.input[start..self.position].into())
        } else if byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'$' {
            let start = self.position;
            while self.byte().is_some_and(|b| {
                b.is_ascii_alphanumeric() || matches!(b, b'_' | b'$' | b'.' | b'-')
            }) {
                self.advance();
            }
            Kind::Word(self.input[start..self.position].into())
        } else if b":;|<>,=[]".contains(&byte) {
            self.advance();
            Kind::Punct(char::from(byte))
        } else {
            return Err(self.error(format!("unsupported grammar syntax {:?}", char::from(byte))));
        };
        Ok(Some(Lexeme { kind, source }))
    }
}

fn annotation(action: &str, position: usize, source: Location) -> Action {
    let bytes = action.as_bytes();
    let mut storage = BTreeSet::new();
    let mut assignments = Vec::new();
    let mut classes = BTreeSet::new();
    let mut lexer = Lexer::new(action, &source.file);
    // Inspect identifiers only outside comments and strings, and never ship upstream C actions.
    while let Some(byte) = lexer.byte() {
        if lexer.starts("/*") || lexer.starts("//") {
            let _ = lexer.comment();
            continue;
        }
        if byte == b'\'' || byte == b'"' {
            let _ = lexer.quoted();
            continue;
        }
        if byte.is_ascii_alphabetic() || byte == b'_' || byte == b'$' {
            let start = lexer.position;
            lexer.advance();
            while lexer
                .byte()
                .is_some_and(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'$'))
            {
                lexer.advance();
            }
            let word = &action[start..lexer.position];
            if word.starts_with("SYM_") {
                classes.insert(word.to_owned());
            }
        } else if byte == b'='
            && bytes.get(lexer.position + 1) != Some(&b'=')
            && lexer
                .position
                .checked_sub(1)
                .is_none_or(|n| !b"=!<>".contains(&bytes[n]))
        {
            let end = lexer.position;
            let mut start = end;
            while start > 0 && bytes[start - 1].is_ascii_whitespace() {
                start -= 1;
            }
            let lhs_end = start;
            while start > 0
                && (bytes[start - 1].is_ascii_alphanumeric()
                    || b"_$><.-[]".contains(&bytes[start - 1]))
            {
                start -= 1;
            }
            if start < lhs_end {
                let lhs = &action[start..lhs_end];
                storage.insert(lhs.to_owned());
                if let Some(position) = positional_value(&action[end + 1..]) {
                    assignments.push((lhs.to_owned(), position));
                }
            }
            lexer.advance();
        } else {
            lexer.advance();
        }
    }
    Action {
        position,
        source,
        storage: storage.into_iter().collect(),
        symbol_classes: classes.into_iter().collect(),
        assignments,
    }
}

// `$n` alone up to the end of the assignment, as in `cfg->low = $3;`
fn positional_value(rhs: &str) -> Option<usize> {
    let rhs = rhs.trim_start().strip_prefix('$')?;
    let digits = rhs.find(|c: char| !c.is_ascii_digit()).unwrap_or(rhs.len());
    if digits == 0 || !rhs[digits..].trim_start().starts_with([';', ',', ')', '}']) {
        return None;
    }
    rhs[..digits].parse().ok()
}

pub fn parse(input: &str) -> Result<Grammar, Error> {
    parse_lexed(input, &|_| true)
}

// `lexed` tells whether BIRD's lexer can emit a declared token
// a production that needs a token it never emits is dead, such as a placeholder that a protocol overrides
pub fn parse_lexed(input: &str, lexed: &dyn Fn(&str) -> bool) -> Result<Grammar, Error> {
    let mut lexer = Lexer::new(input, "<m4-output>");
    let mut lexemes = Vec::new();
    // The epilogue is C, not grammar. Do not lex it as grammar syntax.
    let mut sections = 0;
    while let Some(token) = lexer.next()? {
        if token.kind == Kind::Section {
            sections += 1;
        }
        lexemes.push(token);
        if sections == 2 {
            break;
        }
    }
    let mut grammar = Grammar {
        start: String::new(),
        configuration_start: String::new(),
        rules: BTreeMap::new(),
        tokens: BTreeMap::new(),
        declarations: Vec::new(),
        semantic_storage: String::new(),
        excluded_cli_rules: Vec::new(),
    };
    let mut types = BTreeMap::new();
    let mut index = 0;
    while index < lexemes.len() && lexemes[index].kind != Kind::Section {
        let token = &lexemes[index];
        match &token.kind {
            Kind::Newline | Kind::Action(_) => {
                index += 1;
            }
            Kind::Directive(directive) => {
                let source = token.source.clone();
                index += 1;
                let start = index;
                while index < lexemes.len()
                    && !matches!(lexemes[index].kind, Kind::Newline | Kind::Section)
                {
                    index += 1;
                }
                let args = &lexemes[start..index];
                let mut tag = None;
                let mut names = Vec::new();
                let mut cursor = 0;
                while cursor < args.len() {
                    if args[cursor].kind == Kind::Punct('<') {
                        let Some(Lexeme {
                            kind: Kind::Word(name),
                            ..
                        }) = args.get(cursor + 1)
                        else {
                            return Err(Error::at(source.clone(), "expected semantic storage tag"));
                        };
                        if args.get(cursor + 2).map(|v| &v.kind) != Some(&Kind::Punct('>')) {
                            return Err(Error::at(
                                source.clone(),
                                "unterminated semantic storage tag",
                            ));
                        }
                        tag = Some(name.clone());
                        cursor += 3;
                    } else {
                        match &args[cursor].kind {
                            Kind::Word(name) => names.push(name.clone()),
                            Kind::Quoted(name) => names.push(format!("'{name}'")),
                            Kind::Action(body) if directive == "union" => {
                                grammar.semantic_storage = body.clone()
                            }
                            other => {
                                return Err(Error::at(
                                    args[cursor].source.clone(),
                                    format!("unsupported %{directive} argument: {other:?}"),
                                ));
                            }
                        }
                        cursor += 1;
                    }
                }
                match directive.as_str() {
                    "token" | "left" | "right" | "nonassoc" | "precedence" => {
                        for name in &names {
                            if !name.starts_with('\'') && !name.bytes().all(|b| b.is_ascii_digit())
                            {
                                let token = grammar.tokens.entry(name.clone()).or_insert(Token {
                                    storage_type: tag.clone(),
                                    source: source.clone(),
                                    configuration_reachable: false,
                                });
                                if token.storage_type.is_none() {
                                    token.storage_type = tag.clone();
                                }
                            }
                        }
                    }
                    "type" | "nterm" => {
                        for name in &names {
                            types.insert(name.clone(), tag.clone());
                        }
                    }
                    "start" if names.len() == 1 => grammar.start = names[0].clone(),
                    "union" | "expect" | "expect-rr" | "debug" | "locations" | "verbose"
                    | "define" => {}
                    _ => {
                        return Err(Error::at(
                            source,
                            format!("unsupported Bison declaration %{directive}"),
                        ));
                    }
                }
                grammar.declarations.push(Declaration {
                    directive: directive.clone(),
                    value: names.join(" "),
                    source,
                });
            }
            _ => {
                return Err(Error::at(
                    token.source.clone(),
                    "expected Bison declaration or %%",
                ));
            }
        }
    }
    if index == lexemes.len() {
        return Err(lexer.error("missing grammar section (%%)"));
    }
    index += 1;
    let mut current: Option<String> = None;
    while index < lexemes.len() && lexemes[index].kind != Kind::Section {
        if lexemes[index].kind == Kind::Newline {
            index += 1;
            continue;
        }
        if current.is_none() && lexemes[index].kind == Kind::Punct(';') {
            index += 1;
            continue;
        }
        let token = &lexemes[index];
        let mut opened_rule = false;
        if let Kind::Word(name) = &token.kind {
            if lexemes.get(index + 1).map(|v| &v.kind) == Some(&Kind::Punct(':')) {
                current = Some(name.clone());
                grammar.rules.entry(name.clone()).or_insert(Rule {
                    storage_type: types.get(name).cloned().flatten(),
                    productions: Vec::new(),
                    source: token.source.clone(),
                });
                index += 2;
                opened_rule = true;
            } else if current.is_none() {
                return Err(Error::at(
                    token.source.clone(),
                    "expected rule name followed by ':'",
                ));
            }
        }
        if !opened_rule
            && lexemes
                .get(index)
                .is_some_and(|v| v.kind == Kind::Punct('|'))
        {
            index += 1;
        }
        let Some(name) = current.clone() else {
            return Err(Error::at(token.source.clone(), "production without a rule"));
        };
        let mut production = Production {
            symbols: Vec::new(),
            precedence: None,
            actions: Vec::new(),
            source: lexemes.get(index).unwrap_or(token).source.clone(),
        };
        loop {
            let Some(next) = lexemes.get(index) else {
                return Err(lexer.error("unterminated grammar production"));
            };
            if matches!(next.kind, Kind::Punct(';' | '|') | Kind::Section) {
                break;
            }
            if let Kind::Word(_) = &next.kind
                && lexemes.get(index + 1).map(|v| &v.kind) == Some(&Kind::Punct(':'))
            {
                break;
            }
            match &next.kind {
                Kind::Word(value) => production.symbols.push(Symbol::Reference(value.clone())),
                Kind::Quoted(value) => production.symbols.push(Symbol::Literal(value.clone())),
                Kind::Action(value) => production.actions.push(annotation(
                    value,
                    production.symbols.len(),
                    next.source.clone(),
                )),
                Kind::Newline => {}
                Kind::Directive(value) if value == "empty" => {}
                Kind::Directive(value) if value == "prec" => {
                    index += 1;
                    let Some(value) = lexemes.get(index) else {
                        return Err(lexer.error("missing %prec token"));
                    };
                    production.precedence = Some(match &value.kind {
                        Kind::Word(name) => Symbol::Reference(name.clone()),
                        Kind::Quoted(name) => Symbol::Literal(name.clone()),
                        _ => {
                            return Err(Error::at(value.source.clone(), "expected %prec token"));
                        }
                    });
                }
                other => {
                    return Err(Error::at(
                        next.source.clone(),
                        format!("unsupported production syntax {other:?}"),
                    ));
                }
            }
            index += 1;
        }
        grammar
            .rules
            .get_mut(&name)
            .unwrap()
            .productions
            .push(production);
        if lexemes
            .get(index)
            .is_some_and(|v| v.kind == Kind::Punct(';'))
        {
            current = None;
            index += 1;
        }
    }
    if grammar.start.is_empty() {
        return Err(lexer.error("missing %start declaration"));
    }
    for rule in grammar.rules.values() {
        for production in &rule.productions {
            for symbol in &production.symbols {
                if let Symbol::Reference(name) = symbol
                    && !grammar.rules.contains_key(name)
                    && !grammar.tokens.contains_key(name)
                {
                    return Err(Error::at(
                        production.source.clone(),
                        format!("undefined grammar symbol {name}"),
                    ));
                }
            }
        }
    }
    for (name, rule) in &mut grammar.rules {
        rule.productions.retain(|production| {
            !production.symbols.iter().any(|symbol| {
                matches!(symbol, Symbol::Reference(token) if grammar.tokens.contains_key(token) && !lexed(token))
            })
        });
        if rule.productions.is_empty() {
            return Err(Error::at(
                rule.source.clone(),
                format!("every production of {name} needs a token the lexer never emits"),
            ));
        }
    }
    // CLI is a separate entry alternative, never a configuration construct.
    let start = grammar
        .rules
        .get_mut(&grammar.start)
        .ok_or_else(|| lexer.error("%start rule is undefined"))?;
    start.productions.retain(|production| {
        !production
            .symbols
            .iter()
            .any(|symbol| matches!(symbol, Symbol::Reference(name) if name == "CLI_MARKER"))
    });
    if start.productions.is_empty() {
        return Err(lexer.error("no configuration entry alternative"));
    }
    grammar.configuration_start = grammar.start.clone();
    let mut reached = BTreeSet::new();
    let mut pending = VecDeque::from([grammar.configuration_start.clone()]);
    while let Some(name) = pending.pop_front() {
        if !reached.insert(name.clone()) {
            continue;
        }
        for production in &grammar.rules[&name].productions {
            for symbol in &production.symbols {
                if let Symbol::Reference(next) = symbol
                    && grammar.rules.contains_key(next)
                {
                    pending.push_back(next.clone());
                }
            }
        }
    }
    grammar.excluded_cli_rules = grammar
        .rules
        .keys()
        .filter(|name| !reached.contains(*name))
        .cloned()
        .collect();
    grammar.rules.retain(|name, _| reached.contains(name));
    for rule in grammar.rules.values() {
        for production in &rule.productions {
            for symbol in &production.symbols {
                if let Symbol::Reference(name) = symbol
                    && let Some(token) = grammar.tokens.get_mut(name)
                {
                    token.configuration_reachable = true;
                }
            }
        }
    }
    let mut productive = BTreeSet::new();
    loop {
        let before = productive.len();
        for (name, rule) in &grammar.rules {
            if rule.productions.iter().any(|production| {
                production.symbols.iter().all(|symbol| match symbol {
                    Symbol::Literal(_) => true,
                    Symbol::Reference(reference) => {
                        grammar.tokens.contains_key(reference) || productive.contains(reference)
                    }
                })
            }) {
                productive.insert(name.clone());
            }
        }
        if productive.len() == before {
            break;
        }
    }
    if let Some((name, rule)) = grammar
        .rules
        .iter()
        .find(|(name, _)| !productive.contains(*name))
    {
        return Err(Error::at(
            rule.source.clone(),
            format!(
                "nonproductive recursive grammar rule {name}, no finite configuration can derive it"
            ),
        ));
    }
    Ok(grammar)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn actions_ignore_braces_in_comments_and_strings() {
        let grammar = parse("%token END WORD\n%start config\n%%\nconfig: entries END { return 0; };\nentries: | entries item;\nitem: WORD { const char *s = \"}\\\"{\"; /* } */ // {\n cfg->value = f((struct value) { .x = '}' }); };\n%%\ninvalid C @").unwrap();
        let action = &grammar.rules["item"].productions[0].actions[0];
        assert!(action.storage.contains(&"cfg->value".to_owned()));
        assert_eq!(grammar.rules["entries"].productions.len(), 2);
    }

    #[test]
    fn assignments_record_the_bison_position_they_read() {
        let grammar = parse("%token END NUM\n%start config\n%%\nconfig: NUM NUM END { cfg->low = $1; cfg->high = $2 ; cfg->sum = $1 + $2; cfg->ptr = $$; };\n%%").unwrap();
        let action = &grammar.rules["config"].productions[0].actions[0];
        assert_eq!(
            action.assignments,
            [("cfg->low".to_owned(), 1), ("cfg->high".to_owned(), 2)]
        );
    }

    #[test]
    fn productions_needing_a_token_the_lexer_never_emits_are_dropped() {
        let input = "%token END BFD INVALID_TOKEN\n%start config\n%%\nconfig: opts END;\nopts: '{' INVALID_TOKEN '}' | '{' BFD '}';\n%%";
        let grammar = parse_lexed(input, &|token| token != "INVALID_TOKEN").unwrap();
        assert_eq!(grammar.rules["opts"].productions.len(), 1);
        assert_eq!(
            grammar.rules["opts"].productions[0].symbols[1],
            Symbol::Reference("BFD".into())
        );
        let error = parse_lexed(input, &|token| token == "END").unwrap_err();
        assert!(error.message.contains("every production of opts"));
    }

    #[test]
    fn sync_lines_report_original_source() {
        let error = parse("#line 41 \"proto/new/config.Y\"\n%start config\n%%\nconfig: @;\n%%")
            .unwrap_err();
        assert_eq!(error.file, "proto/new/config.Y");
        assert_eq!(error.line, Some(43));
        assert!(error.message.contains("unsupported grammar syntax"));
    }

    #[test]
    fn cli_reachability_is_separate_from_configuration() {
        let grammar = parse("%token END CLI_MARKER SHOW X\n%start config\n%%\nconfig: entries END | CLI_MARKER cli_cmd;\nentries: | entries item;\nitem: X;\ncli_cmd: SHOW;\n%%").unwrap();
        assert!(grammar.rules.contains_key("item"));
        assert!(!grammar.rules.contains_key("cli_cmd"));
        assert!(grammar.excluded_cli_rules.contains(&"cli_cmd".into()));
    }

    #[test]
    fn utf8_comments_preserve_grammar_and_action_annotations() {
        let grammar = parse("%token END WORD\n%start config\n%%\n/* caf\u{e9} */ config: WORD END { /* caf\u{e9} */ cfg->value = 1; };\n%%").unwrap();
        let production = &grammar.rules["config"].productions[0];
        assert_eq!(
            production.symbols,
            vec![
                Symbol::Reference("WORD".into()),
                Symbol::Reference("END".into())
            ]
        );
        assert!(
            production.actions[0]
                .storage
                .contains(&"cfg->value".to_owned())
        );
    }
    #[test]
    fn unknown_syntax_fails_instead_of_dropping_productions() {
        assert!(
            parse("%start config\n%%\nconfig: entries;\nentries: %dprec 1;\n%%")
                .unwrap_err()
                .message
                .contains("unsupported")
        );
    }

    #[test]
    fn all_configuration_start_alternatives_are_preserved() {
        let grammar = parse("%token END X Y\n%start config\n%%\nconfig: entries END | extension END; entries: | entries X; extension: Y;\n%%").unwrap();
        assert!(grammar.rules.contains_key("extension"));
        assert!(grammar.tokens["Y"].configuration_reachable);
    }

    #[test]
    fn nonproductive_recursion_is_a_source_error() {
        let error = parse("%start config\n%%\nconfig: loop; loop: config;\n%%").unwrap_err();
        assert!(error.message.contains("nonproductive recursive"));
    }

    #[test]
    fn empty_macro_separators_do_not_create_productions() {
        let grammar = parse("%token END\n%start config\n%%\nconfig: END; ; ;\n%%").unwrap();
        assert_eq!(
            grammar.rules["config"].productions[0].symbols,
            vec![Symbol::Reference("END".into())]
        );
    }
}
