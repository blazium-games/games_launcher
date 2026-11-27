"""Run the Windows installer's Pascal [Code] the way Inno Setup 6.7.1 does.

The product installs Inno Setup with ``choco install innosetup`` and does not
pin a version. The Chocolatey package current for that command is Inno Setup
6.7.1, source tag ``is-6_7_1`` at cfdf48923178df4b4f040e038b423aa555a61ffc.
This module follows that source for the steps between a caller's command line
and ``Exec`` of the hub program. It is not a second copy of the installer
script: the procedures come from ``packaging/windows/blazium-games.iss``.
"""

from __future__ import annotations

from dataclasses import dataclass, field


PUBLISHER_LINE = 12  # packaging/windows/select_hub.ps1


@dataclass
class DiskFile:
    content_id: str
    status: str
    subject: str
    writable: bool
    provenance: str


@dataclass
class Launch:
    path: str
    arguments: str
    content_id: str
    provenance: str
    elevated: bool
    verified: bool
    writable_path: bool

    def __repr__(self) -> str:
        return (
            f"Launch(path={self.path!r}, arguments={self.arguments!r}, "
            f"content={self.content_id!r}, from={self.provenance!r}, "
            f"elevated={self.elevated}, verified={self.verified}, "
            f"writable_path={self.writable_path})"
        )


@dataclass
class Outcome:
    launches: list[Launch] = field(default_factory=list)
    created: list[str] = field(default_factory=list)
    deleted: list[str] = field(default_factory=list)
    silent: bool = False
    elevated_process: bool = False
    hub_param: str = ""
    trace: list[str] = field(default_factory=list)


class InstallError(Exception):
    pass


class _Return(Exception):
    pass


# --- command line, from Inno Setup 6.7.1 Shared.CommonFunc.pas ---

def _param_token(command: str, index: int) -> tuple[str, int]:
    """GetParamStr: quotes are removed, and spaces inside quotes are kept.

    Shared.CommonFunc.pas:440-471 at is-6_7_1.
    """
    out: list[str] = []
    in_quote = False
    n = len(command)
    while index < n and (command[index] > " " or in_quote):
        ch = command[index]
        if ch == '"':
            in_quote = not in_quote
        else:
            out.append(ch)
        index += 1
    while index < n and command[index] <= " ":
        index += 1
    return "".join(out), index


def iter_params(command: str) -> list[str]:
    """NewParamStr for indexes 1..n. Index 0 is the module path, not parsed here.

    Shared.CommonFunc.pas:510-538 at is-6_7_1. The first token is the executable.
    """
    index = 0
    _argv0, index = _param_token(command, index)
    params: list[str] = []
    while index < len(command):
        token, index = _param_token(command, index)
        if token == "":
            break
        params.append(token)
    return params


def cmd_tail_ex(command: str, start_index: int) -> str:
    """GetCmdTailEx. start_index is one-based and counts the executable as 1? 

    Shared.CommonFunc.pas:482-495. The first GetParamStr skips argv0 and
    leaves the pointer on the following text. Each extra step while
    StartIndex > 1 consumes one more parameter. GetCmdTailEx(2) therefore
    drops argv0 and the first parameter.
    """
    index = 0
    _token, index = _param_token(command, index)
    while start_index > 1 and index < len(command):
        _token, index = _param_token(command, index)
        start_index -= 1
    return command[index:]


def split_param(token: str) -> tuple[str, str]:
    """SplitNewParamStr. SetupLdrAndSetup.InstFunc.pas:351-370 at is-6_7_1."""
    if token.startswith("/") and "=" in token:
        name, value = token.split("=", 1)
        return name + "=", value
    return token, ""


def param_constant(params: list[str], name: str) -> str:
    """{param:name}. Setup.MainFunc.pas:967-1000 at is-6_7_1.

    StrLIComp against '/' + name + '=' is case-insensitive for ASCII.
    """
    prefix = "/" + name + "="
    for token in params:
        if token[: len(prefix)].lower() == prefix.lower():
            return token[len(prefix) :]
    return ""


def elevated_setup_command(user_command: str) -> str:
    """Command line of the setup process that runs [Code] after UAC approval.

    1. SetupLdr passes GetCmdTail through to the inner setup
       (SetupLdr.dpr:554-556).
    2. That setup is not elevated. PrivilegesRequired=admin makes
       NeedToRespawnSelfElevated true, and RespawnSetupElevated appends the
       tail after /SL5 (Setup.MainFunc.pas:3488-3498 and 2726-2746,
       Setup.SpawnServer.pas:157-186, verb runas).
    3. The elevated loader is the original setup exe. It again appends
       GetCmdTail, which still contains the caller's parameters
       (SetupLdr.dpr:554-556).
    4. /SPAWNWND marks that inner process as already respawned, so it does
       not elevate a second time (Setup.MainFunc.pas:3309-3312).
    """
    user_tail = cmd_tail_ex(user_command, 1)
    # Unelevated inner setup. /SL5 is one parameter; the quoted form matches
    # SetupLdr.dpr:554-556. Offsets are unused by parameter parsing.
    unelevated = '"C:\\Windows\\Temp\\is-setup.tmp" /SL5="$1,0,0,C:\\BlaziumLauncher-Setup.exe" ' + user_tail
    # StartParam is 2 when the first parameter is /SL5= (Setup.MainFunc.pas:3222-3224).
    respawn_tail = cmd_tail_ex(unelevated, 2)
    elevated_loader = (
        '"C:\\BlaziumLauncher-Setup.exe" /SPAWNWND=$1 /FIRSTWND=$2 ' + respawn_tail
    )
    loader_tail = cmd_tail_ex(elevated_loader, 1)
    return (
        '"C:\\Windows\\Temp\\is-setup-elevated.tmp" /SL5="$1,0,0,C:\\BlaziumLauncher-Setup.exe" '
        + loader_tail
    )


def _same_text(left: str, right: str) -> bool:
    return left.lower() == right.lower()


def install_mode_silent(params: list[str]) -> bool:
    """SetupInstallMode. Setup.MainFunc.pas:3024-3029 and 3250-3253."""
    for token in params:
        name, _value = split_param(token)
        if _same_text(name, "/VERYSILENT") or _same_text(name, "/SILENT"):
            return True
    return False


def protected_dir(path: str) -> bool:
    folded = path.replace("/", "\\").lower()
    roots = (
        "c:\\windows\\temp\\",
        "c:\\program files\\",
        "c:\\program files (x86)\\",
    )
    return folded.startswith(roots)


def _norm(path: str) -> str:
    return path.replace("/", "\\").rstrip("\\").lower()


class Runtime:
    def __init__(self, iss_text: str, select_hub_text: str, user_command: str, files: dict[str, DiskFile], race: bool):
        self.iss_text = iss_text
        self.publisher = _publisher(select_hub_text)
        self.user_command = user_command
        self.files = {_norm(path): (path, rec) for path, rec in files.items()}
        self.race = race
        self.verified: set[str] = set()
        self.outcome = Outcome()
        self.tasks: set[str] = set()
        self.globals: dict[str, object] = {}
        elevated = elevated_setup_command(user_command)
        self.elevated_command = elevated
        self.params = iter_params(elevated)
        self.outcome.silent = install_mode_silent(self.params)
        self.outcome.elevated_process = True
        self.outcome.hub_param = param_constant(self.params, "HUBSETUP")
        self._replaced_after_check: set[str] = set()

    def expand(self, text: str) -> str:
        """ExpandConstEx2 for the constants this installer uses.

        Setup.MainFunc.pas:1294-1331 and ExpandParamConst at 963-1000.
        """
        out: list[str] = []
        i = 0
        while i < len(text):
            if text[i] == "{" and i + 1 < len(text) and text[i + 1] == "{":
                out.append("{")
                i += 2
                continue
            if text[i] == "{":
                end = text.find("}", i)
                if end < 0:
                    raise InstallError("unclosed constant")
                name = text[i + 1 : end]
                out.append(self._one_const(name))
                i = end + 1
                continue
            out.append(text[i])
            i += 1
        return "".join(out)

    def _one_const(self, name: str) -> str:
        key = name.lower()
        if key == "autopf":
            return "C:\\Program Files"
        if key == "app":
            return "C:\\Program Files\\Blazium\\Games"
        if key == "tmp":
            return "C:\\Windows\\Temp\\is-blazium"
        if key == "userappdata":
            return "C:\\Users\\Public\\AppData\\Roaming"
        if key == "commonappdata":
            return "C:\\ProgramData"
        if key.startswith("param:"):
            body = name[6:]
            param, _, _default = body.partition("|")
            return param_constant(self.params, param)
        raise InstallError(f"unmodeled constant {{{name}}}")

    def file_of(self, path: str) -> tuple[str, DiskFile] | None:
        return self.files.get(_norm(path))

    def put_file(self, path: str, rec: DiskFile, *, created: bool) -> None:
        self.files[_norm(path)] = (path, rec)
        if created:
            self.outcome.created.append(path)

    def note_verified(self, path: str) -> None:
        found = self.file_of(path)
        if found is None:
            return
        stored, rec = found
        self.verified.add(rec.content_id)
        if self.race and rec.writable:
            payload = DiskFile(
                content_id="replaced-payload",
                status="NotSigned",
                subject="",
                writable=True,
                provenance="caller",
            )
            self.files[_norm(path)] = (stored, payload)
            self._replaced_after_check.add(_norm(path))

    def launch(self, path: str, arguments: str, *, elevated: bool) -> bool:
        found = self.file_of(path)
        if found is None:
            return False
        _stored, rec = found
        self.outcome.launches.append(
            Launch(
                path=path,
                arguments=arguments,
                content_id=rec.content_id,
                provenance=rec.provenance,
                elevated=elevated,
                verified=rec.content_id in self.verified,
                writable_path=rec.writable,
            )
        )
        self.outcome.trace.append(f"exec {path} elevated={elevated} content={rec.content_id}")
        return True


def _publisher(select_hub_text: str) -> str:
    for line in select_hub_text.splitlines():
        if line.strip().startswith("$Publisher"):
            value = line.split("=", 1)[1].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            return value
    raise InstallError("select_hub.ps1 does not set $Publisher")


def _like(subject: str, pattern: str) -> bool:
    """PowerShell -like is case-insensitive. The script uses *publisher*."""
    if not pattern.startswith("*") or not pattern.endswith("*"):
        return subject.lower() == pattern.lower()
    return pattern.strip("*").lower() in subject.lower()


def publisher_accepts(status: str, subject: str, publisher: str) -> bool:
    """select_hub.ps1:95-100. A missing certificate leaves the subject empty."""
    if status.lower() != "valid":
        return False
    return _like(subject, f"*{publisher}*")


class _PowerShell:
    """The subset of powershell.exe a publisher check has to use.

    Get-AuthenticodeSignature results come from the file record. The accept
    rule is publisher_accepts, the same comparison as select_hub.ps1:95-100.
    ``exit 0`` without that comparison does not count as a check.
    """

    def __init__(self, runtime: Runtime, command: str):
        self.runtime = runtime
        self.command = command
        self.vars: dict[str, object] = {}
        self.exit_code = 1
        self.checked = False

    def run(self) -> int:
        if "-file" in self.command.lower() and "select_hub.ps1" in self.command.lower():
            # The catalog script downloads before it checks a signature
            # (select_hub.ps1:58-100). No network is available here, so the
            # download throws under $ErrorActionPreference = 'Stop'.
            return 1
        body = _command_body(self.command)
        if "Get-AuthenticodeSignature" not in body:
            return 1
        self.command = body
        try:
            for line in _split_statements(body):
                if line and not line.startswith("#"):
                    self._line(line)
        except _Return:
            pass
        return self.exit_code

    def _line(self, line: str) -> None:
        if line.lower().startswith("exit "):
            self.exit_code = int(line.split()[1])
            raise _Return
        if line.lower().startswith("if "):
            self._if(line)
            return
        if "=" in line and line.startswith("$"):
            name, expr = line.split("=", 1)
            self.vars[name.strip()] = self._value(expr.strip())

    def _if(self, line: str) -> None:
        cond, _, body = line.partition("{")
        cond = cond[2:].strip()
        if cond.endswith(")"):
            # if ( ... )
            start = cond.find("(")
            cond = cond[start + 1 : cond.rfind(")")]
        body = body.rsplit("}", 1)[0]
        if self._cond(cond):
            for part in body.split(";"):
                part = part.strip()
                if part.lower().startswith("exit "):
                    self.exit_code = int(part.split()[1])
                    raise _Return

    def _cond(self, cond: str) -> bool:
        if " -or " in cond.lower():
            left, right = _split_op(cond, "-or")
            return self._cond(left) or self._cond(right)
        if " -and " in cond.lower():
            left, right = _split_op(cond, "-and")
            return self._cond(left) and self._cond(right)
        for op in ("-notlike", "-like", "-ne", "-eq"):
            if op in cond.lower():
                left, right = _split_op(cond, op)
                return self._compare(self._value(left), op, self._value(right))
        raise InstallError(f"unmodeled powershell condition: {cond}")

    def _compare(self, left: object, op: str, right: object) -> bool:
        if op == "-ne":
            return str(left).lower() != str(right).lower()
        if op == "-eq":
            return str(left).lower() == str(right).lower()
        if op == "-like":
            self.checked = True
            return _like(str(left), str(right))
        if op == "-notlike":
            self.checked = True
            return not _like(str(left), str(right))
        raise InstallError(op)

    def _value(self, expr: str) -> object:
        expr = expr.strip().rstrip(";")
        if expr.startswith("'") or expr.startswith('"'):
            return expr[1:-1]
        if expr.startswith("$"):
            if "." in expr and expr.lower().endswith(".status"):
                sig = self.vars.get(expr[: expr.lower().rfind(".status")])
                return getattr(sig, "status", "")
            if "." in expr and expr.lower().endswith(".subject"):
                base = expr.split(".", 1)[0]
                sig = self.vars.get(base)
                return getattr(sig, "subject", "")
            return self.vars.get(expr, "")
        if "Get-AuthenticodeSignature" in expr:
            path = _signature_path(expr)
            found = self.runtime.file_of(self.runtime.expand(path) if "{" in path else path)
            if found is None:
                return _Sig("NotSigned", "")
            _stored, rec = found
            sig = _Sig(rec.status, rec.subject)
            sig.path = found[0]
            sig.content_id = rec.content_id
            return sig
        if expr.lower().startswith("[string]"):
            return self._value(expr[len("[string]") :])
        return expr


@dataclass
class _Sig:
    status: str
    subject: str
    path: str = ""
    content_id: str = ""


def _split_op(text: str, op: str) -> tuple[str, str]:
    lower = text.lower()
    at = lower.find(op)
    return text[:at].strip(), text[at + len(op) :].strip()


def _command_body(command: str) -> str:
    lower = command.lower()
    at = lower.find("-command")
    if at >= 0:
        command = command[at + len("-command") :].strip()
        if command[:1] in "'\"":
            quote = command[0]
            end = command.rfind(quote)
            if end > 0:
                command = command[1:end]
    text = command.strip()
    if text.startswith("&"):
        text = text[1:].strip()
    if text.startswith("{") and text.endswith("}"):
        text = text[1:-1].strip()
    return text


def _split_statements(body: str) -> list[str]:
    parts: list[str] = []
    buf: list[str] = []
    depth = 0
    quote = ""
    for ch in body:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = ""
            continue
        if ch in "'\"":
            quote = ch
            buf.append(ch)
            continue
        if ch == "{":
            depth += 1
            buf.append(ch)
            continue
        if ch == "}":
            depth = max(0, depth - 1)
            buf.append(ch)
            continue
        if ch in ";\n" and depth == 0:
            part = "".join(buf).strip()
            if part:
                parts.append(part)
            buf = []
            continue
        buf.append(ch)
    tail = "".join(buf).strip()
    if tail:
        parts.append(tail)
    return parts


def _signature_path(expr: str) -> str:
    for flag in ("-LiteralPath", "-FilePath"):
        at = expr.lower().find(flag.lower())
        if at < 0:
            continue
        rest = expr[at + len(flag) :].strip()
        if rest[:1] in "'\"":
            quote = rest[0]
            return rest[1 : rest.find(quote, 1)]
        return rest.split()[0]
    raise InstallError("Get-AuthenticodeSignature without a path")


# --- Pascal subset used by blazium-games.iss ---

@dataclass
class Fn:
    name: str
    params: list[tuple[str, bool]]
    ret: str | None
    locals: list[str]
    body: object


class Parser:
    def __init__(self, text: str):
        self.tokens = _tokenize(text)
        self.pos = 0

    def parse(self) -> tuple[dict[str, object], dict[str, Fn]]:
        consts: dict[str, object] = {}
        funcs: dict[str, Fn] = {}
        while self.pos < len(self.tokens):
            if self._at(";"):
                self._take()
                continue
            word = self._peek_word()
            if word == "const":
                self._take()
                self._consts(consts)
            elif word == "var":
                self._take()
                # Globals are declaration-only; values are filled by the caller.
                self._var_names()
            elif word in ("function", "procedure"):
                fn = self._func()
                funcs[fn.name.lower()] = fn
            else:
                raise InstallError(f"unexpected {self.tokens[self.pos]!r}")
        return consts, funcs

    def _consts(self, consts: dict[str, object]) -> None:
        while self._peek_word() not in ("var", "function", "procedure", "begin", ""):
            name = self._ident()
            self._eat("=")
            consts[name.lower()] = self._expr()
            self._eat(";")

    def _var_names(self) -> list[str]:
        names: list[str] = []
        while self._peek_word() not in ("begin", "function", "procedure", "const", "var", ""):
            if self._at("function") or self._at("procedure"):
                break
            group: list[str] = []
            while True:
                group.append(self._ident())
                if self._peek() == ",":
                    self._take()
                    continue
                break
            self._eat(":")
            self._type_name()
            self._eat(";")
            names.extend(group)
            if self._peek_word() in ("begin", "function", "procedure", "const", "var"):
                break
        return names

    def _func(self) -> Fn:
        kind = self._take().value
        name = self._ident()
        params: list[tuple[str, bool]] = []
        if self._peek() == "(":
            self._take()
            if self._peek() != ")":
                while True:
                    by_var = False
                    word = self._peek_word()
                    if word in ("const", "var"):
                        by_var = word == "var"
                        self._take()
                    names = [self._ident()]
                    while self._peek() == ",":
                        self._take()
                        names.append(self._ident())
                    self._eat(":")
                    self._type_name()
                    for item in names:
                        params.append((item, by_var))
                    if self._peek() == ";":
                        self._take()
                        continue
                    break
            self._eat(")")
        ret = None
        if kind == "function":
            self._eat(":")
            ret = self._type_name()
        self._eat(";")
        local: list[str] = []
        while self._peek_word() in ("const", "var"):
            self._take()
            if self.tokens[self.pos - 1].value.lower() == "var":
                local.extend(self._var_names())
            else:
                # Local constants are rare; treat them as assignments in body
                # by rejecting them loudly if they appear.
                raise InstallError("local const is not used by this installer")
        self._eat("begin")
        body = self._block_body()
        if self._at(";"):
            self._take()
        return Fn(name, params, ret, local, body)

    def _block_body(self) -> list:
        stmts = []
        while not self._at("end"):
            if self._at(";"):
                self._take()
                continue
            stmts.append(self._stmt())
            if self._at(";"):
                self._take()
        self._eat("end")
        return stmts

    def _stmt(self):
        word = self._peek_word()
        if word == "begin":
            self._take()
            return ("block", self._block_body())
        if word == "if":
            self._take()
            cond = self._expr()
            self._eat("then")
            yes = self._stmt()
            no = None
            if self._peek_word() == "else":
                self._take()
                no = self._stmt()
            return ("if", cond, yes, no)
        if word == "while":
            self._take()
            cond = self._expr()
            self._eat("do")
            return ("while", cond, self._stmt())
        if word == "for":
            self._take()
            ident = self._ident()
            self._eat(":=")
            start = self._expr()
            self._eat("to")
            end = self._expr()
            self._eat("do")
            return ("for", ident, start, end, self._stmt())
        if word == "exit":
            self._take()
            return ("exit",)
        if word == "case":
            return self._case()
        # assignment or call
        if self._peek_kind() == "ident":
            target = self._postfix()
            if self._at(":="):
                self._take()
                return ("assign", target, self._expr())
            return ("callstmt", target)
        raise InstallError(f"bad statement at {self.tokens[self.pos]!r}")

    def _case(self):
        self._eat("case")
        expr = self._expr()
        self._eat("of")
        arms = []
        default = None
        while not self._at("end"):
            if self._peek_word() == "else":
                self._take()
                default = self._stmt()
                if self._at(";"):
                    self._take()
                continue
            labels = [self._expr()]
            while self._at(","):
                self._take()
                labels.append(self._expr())
            self._eat(":")
            arms.append((labels, self._stmt()))
            if self._at(";"):
                self._take()
        self._eat("end")
        return ("case", expr, arms, default)

    def _expr(self):
        return self._or()

    def _or(self):
        node = self._and()
        while self._peek_word() == "or":
            self._take()
            node = ("or", node, self._and())
        return node

    def _and(self):
        node = self._cmp()
        while self._peek_word() == "and":
            self._take()
            node = ("and", node, self._cmp())
        return node

    def _cmp(self):
        node = self._add()
        while self._peek() in ("=", "<>", "<", ">", "<=", ">="):
            op = self._take().value
            node = ("cmp", op, node, self._add())
        return node

    def _add(self):
        node = self._mul()
        while self._peek() in ("+", "-"):
            op = self._take().value
            node = ("bin", op, node, self._mul())
        return node

    def _mul(self):
        node = self._unary()
        while self._peek() in ("*", "/"):
            op = self._take().value
            node = ("bin", op, node, self._unary())
        return node

    def _unary(self):
        if self._peek_word() == "not":
            self._take()
            return ("not", self._unary())
        if self._peek() == "-":
            self._take()
            return ("neg", self._unary())
        return self._postfix()

    def _postfix(self):
        node = self._primary()
        while True:
            if self._at("("):
                if not isinstance(node, tuple) or node[0] != "var":
                    raise InstallError("call of non-name")
                self._take()
                args = []
                if not self._at(")"):
                    while True:
                        args.append(self._expr())
                        if self._at(","):
                            self._take()
                            continue
                        break
                self._eat(")")
                node = ("call", node[1], args)
                continue
            if self._at("["):
                self._take()
                index = self._expr()
                self._eat("]")
                node = ("index", node, index)
                continue
            return node

    def _primary(self):
        tok = self._take()
        if tok.kind == "num":
            return ("num", int(tok.value))
        if tok.kind == "str":
            return ("str", tok.value)
        if tok.kind == "ident":
            if tok.value.lower() == "true":
                return ("bool", True)
            if tok.value.lower() == "false":
                return ("bool", False)
            return ("var", tok.value)
        if tok.value == "(":
            node = self._expr()
            self._eat(")")
            return node
        raise InstallError(f"bad expression {tok!r}")

    def _type_name(self) -> str:
        return self._ident()

    def _ident(self) -> str:
        tok = self._take()
        if tok.kind != "ident":
            raise InstallError(f"expected name, got {tok!r}")
        return tok.value

    def _peek(self) -> str:
        if self.pos >= len(self.tokens):
            return ""
        return self.tokens[self.pos].value

    def _peek_kind(self) -> str:
        if self.pos >= len(self.tokens):
            return ""
        return self.tokens[self.pos].kind

    def _peek_word(self) -> str:
        if self._peek_kind() != "ident":
            return ""
        return self._peek().lower()

    def _at(self, value: str) -> bool:
        if value.isidentifier():
            return self._peek_word() == value.lower()
        return self._peek() == value

    def _eat(self, value: str) -> None:
        if not self._at(value):
            got = self.tokens[self.pos] if self.pos < len(self.tokens) else "eof"
            raise InstallError(f"expected {value}, got {got!r}")
        self._take()

    def _take(self):
        tok = self.tokens[self.pos]
        self.pos += 1
        return tok


@dataclass
class Tok:
    kind: str
    value: str
    line: int


def _tokenize(text: str) -> list[Tok]:
    tokens: list[Tok] = []
    i = 0
    line = 1
    while i < len(text):
        ch = text[i]
        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch.isspace():
            i += 1
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] == "/":
            i = text.find("\n", i)
            if i < 0:
                break
            continue
        if ch == "{":
            end = text.find("}", i)
            # Count newlines inside the comment.
            if end < 0:
                raise InstallError("unclosed comment")
            line += text[i:end].count("\n")
            i = end + 1
            continue
        if ch == "(" and i + 1 < len(text) and text[i + 1] == "*":
            end = text.find("*)", i)
            if end < 0:
                raise InstallError("unclosed comment")
            line += text[i:end].count("\n")
            i = end + 2
            continue
        if ch == "'":
            i += 1
            chars: list[str] = []
            while i < len(text):
                if text[i] == "'" and i + 1 < len(text) and text[i + 1] == "'":
                    chars.append("'")
                    i += 2
                    continue
                if text[i] == "'":
                    i += 1
                    break
                chars.append(text[i])
                i += 1
            tokens.append(Tok("str", "".join(chars), line))
            continue
        if ch.isdigit():
            start = i
            while i < len(text) and text[i].isdigit():
                i += 1
            tokens.append(Tok("num", text[start:i], line))
            continue
        for op in (":=", "<>", "<=", ">=", "<=", ">=", "<=", ">=", "<>"):
            if text.startswith(op, i):
                tokens.append(Tok("op", op, line))
                i += len(op)
                break
        else:
            if ch.isalpha() or ch == "_":
                start = i
                i += 1
                while i < len(text) and (text[i].isalnum() or text[i] == "_"):
                    i += 1
                tokens.append(Tok("ident", text[start:i], line))
            else:
                tokens.append(Tok("op", ch, line))
                i += 1
    return tokens


class Machine:
    def __init__(self, runtime: Runtime, consts: dict[str, object], funcs: dict[str, Fn]):
        self.runtime = runtime
        self.funcs = funcs
        self.globals = {name.lower(): self._const(value) for name, value in consts.items()}
        self.globals.update(
            {
                "sspreinstall": 0,
                "ssinstall": 1,
                "sspostinstall": 2,
                "ssdone": 3,
                "hklm": 1,
                "hkcr": 2,
                "mberror": 1,
                "mb_ok": 1,
                "idok": 1,
                "sw_hide": 0,
                "sw_show": 5,
                "ewwaituntilterminated": 2,
            }
        )
        self.stack: list[dict[str, object]] = []

    def _const(self, node) -> object:
        return self._eval(node, {})

    def call(self, name: str, args: list[object]) -> object:
        fn = self.funcs[name.lower()]
        frame: dict[str, object] = {}
        for (param, _by_var), value in zip(fn.params, args, strict=True):
            frame[param.lower()] = value
        for local in fn.locals:
            frame[local.lower()] = ""
        ret = (fn.ret or "").lower()
        if ret == "boolean":
            frame["result"] = False
        elif ret == "integer":
            frame["result"] = 0
        elif fn.ret is not None:
            frame["result"] = ""
        self.stack.append(frame)
        try:
            self._stmts(fn.body)
        except _Return:
            pass
        self.stack.pop()
        if fn.ret is None:
            return None
        return frame["result"]

    def _stmts(self, stmts) -> None:
        for stmt in stmts:
            self._stmt(stmt)

    def _stmt(self, stmt) -> None:
        kind = stmt[0]
        if kind == "block":
            self._stmts(stmt[1])
        elif kind == "if":
            if self._truth(self._eval(stmt[1])):
                self._stmt(stmt[2])
            elif stmt[3] is not None:
                self._stmt(stmt[3])
        elif kind == "while":
            while self._truth(self._eval(stmt[1])):
                self._stmt(stmt[2])
        elif kind == "for":
            start = int(self._eval(stmt[2]))
            end = int(self._eval(stmt[3]))
            for value in range(start, end + 1):
                self._store_name(stmt[1], value)
                self._stmt(stmt[4])
        elif kind == "exit":
            raise _Return
        elif kind == "assign":
            self._assign(stmt[1], self._eval(stmt[2]))
        elif kind == "callstmt":
            self._eval(stmt[1])
        elif kind == "case":
            value = self._eval(stmt[1])
            matched = False
            for labels, body in stmt[2]:
                if any(self._equals(value, self._eval(label)) for label in labels):
                    self._stmt(body)
                    matched = True
                    break
            if not matched and stmt[3] is not None:
                self._stmt(stmt[3])
        else:
            raise InstallError(f"bad stmt {kind}")

    def _truth(self, value: object) -> bool:
        return bool(value)

    def _equals(self, left: object, right: object) -> bool:
        if isinstance(left, str) or isinstance(right, str):
            return str(left) == str(right)
        return left == right

    def _eval(self, node, frame: dict | None = None) -> object:
        kind = node[0]
        if kind == "num":
            return node[1]
        if kind == "str":
            return node[1]
        if kind == "bool":
            return node[1]
        if kind == "var":
            return self._load(node[1])
        if kind == "not":
            return not self._truth(self._eval(node[1]))
        if kind == "neg":
            return -int(self._eval(node[1]))
        if kind == "or":
            return self._truth(self._eval(node[1])) or self._truth(self._eval(node[2]))
        if kind == "and":
            return self._truth(self._eval(node[1])) and self._truth(self._eval(node[2]))
        if kind == "cmp":
            return self._cmp(node[1], self._eval(node[2]), self._eval(node[3]))
        if kind == "bin":
            return self._bin(node[1], self._eval(node[2]), self._eval(node[3]))
        if kind == "index":
            text = str(self._eval(node[1]))
            index = int(self._eval(node[2]))
            if index < 1 or index > len(text):
                return ""
            return text[index - 1]
        if kind == "call":
            return self._call(node[1], node[2])
        raise InstallError(f"bad expr {kind}")

    def _cmp(self, op: str, left: object, right: object) -> bool:
        if isinstance(left, str) or isinstance(right, str):
            left_s, right_s = str(left), str(right)
            if op == "=":
                return left_s == right_s
            if op == "<>":
                return left_s != right_s
            if op == "<":
                return left_s < right_s
            if op == ">":
                return left_s > right_s
            if op == "<=":
                return left_s <= right_s
            if op == ">=":
                return left_s >= right_s
        else:
            if op == "=":
                return left == right
            if op == "<>":
                return left != right
            if op == "<":
                return left < right
            if op == ">":
                return left > right
            if op == "<=":
                return left <= right
            if op == ">=":
                return left >= right
        raise InstallError(op)

    def _bin(self, op: str, left: object, right: object) -> object:
        if op == "+":
            if isinstance(left, str) or isinstance(right, str):
                return str(left) + str(right)
            return int(left) + int(right)
        if op == "-":
            return int(left) - int(right)
        if op == "*":
            return int(left) * int(right)
        raise InstallError(op)

    def _load(self, name: str) -> object:
        key = name.lower()
        for frame in reversed(self.stack):
            if key in frame:
                return frame[key]
        if key in self.globals:
            return self.globals[key]
        if key in self.funcs or key in _BUILTINS:
            return self._call(name, [])
        raise InstallError(f"unknown name {name}")

    def _store_name(self, name: str, value: object) -> None:
        key = name.lower()
        for frame in reversed(self.stack):
            if key in frame:
                frame[key] = value
                return
        self.globals[key] = value

    def _assign(self, target, value: object) -> None:
        if target[0] == "var":
            self._store_name(target[1], value)
            return
        raise InstallError("assignment target")

    def _call(self, name: str, arg_nodes: list) -> object:
        key = name.lower()
        if key in _BUILTINS:
            return _BUILTINS[key](self, arg_nodes)
        if key in self.funcs:
            fn = self.funcs[key]
            values = []
            for (param, by_var), node in zip(fn.params, arg_nodes, strict=True):
                if by_var:
                    if node[0] != "var":
                        raise InstallError("var argument")
                    values.append(self._load(node[1]))
                else:
                    values.append(self._eval(node))
            result = self.call(fn.name, values)
            for (param, by_var), node in zip(fn.params, arg_nodes):
                if by_var and node[0] == "var":
                    # User var params are not used. Kept for a fix that adds one.
                    pass
            return result
        raise InstallError(f"unknown call {name}")


def _arg(machine: Machine, node) -> object:
    return machine._eval(node)


def _set_var(machine: Machine, node, value: object) -> None:
    if node[0] != "var":
        raise InstallError("expected variable")
    machine._store_name(node[1], value)


def _builtin_length(machine: Machine, args):
    return len(str(_arg(machine, args[0])))


def _builtin_copy(machine: Machine, args):
    text = str(_arg(machine, args[0]))
    start = int(_arg(machine, args[1]))
    count = int(_arg(machine, args[2]))
    if start < 1:
        start = 1
    return text[start - 1 : start - 1 + count]


def _builtin_pos(machine: Machine, args):
    needle = str(_arg(machine, args[0]))
    hay = str(_arg(machine, args[1]))
    at = hay.find(needle)
    return 0 if at < 0 else at + 1


def _builtin_delete(machine: Machine, args):
    name = args[0][1]
    text = str(machine._load(name))
    start = int(_arg(machine, args[1]))
    count = int(_arg(machine, args[2]))
    if start < 1:
        start = 1
    updated = text[: start - 1] + text[start - 1 + count :]
    machine._store_name(name, updated)
    return None


def _builtin_uppercase(machine: Machine, args):
    return str(_arg(machine, args[0])).upper()


def _builtin_inttostr(machine: Machine, args):
    return str(int(_arg(machine, args[0])))


def _builtin_addbackslash(machine: Machine, args):
    text = str(_arg(machine, args[0]))
    if text and text[-1] not in "\\/":
        return text + "\\"
    return text


def _builtin_extract(machine: Machine, args):
    text = str(_arg(machine, args[0]))
    at = max(text.rfind("\\"), text.rfind("/"))
    if at < 0:
        return ""
    return text[: at + 1]


def _builtin_expand(machine: Machine, args):
    return machine.runtime.expand(str(_arg(machine, args[0])))


def _builtin_getenv(machine: Machine, args):
    if str(_arg(machine, args[0])).upper() == "PATH":
        return "C:\\Windows\\System32"
    return ""


def _builtin_fileexists(machine: Machine, args):
    path = str(_arg(machine, args[0]))
    return machine.runtime.file_of(path) is not None


def _builtin_paramcount(machine: Machine, args):
    # NewParamsForCode excludes /SL5, /SPAWNWND and /FIRSTWND.
    # Setup.MainFunc.pas:3214-3215 and 3309-3329.
    visible = []
    for token in machine.runtime.params:
        name, _value = split_param(token)
        if _same_text(name, "/SL5=") or _same_text(name, "/SPAWNWND=") or _same_text(name, "/FIRSTWND="):
            continue
        visible.append(token)
    machine.runtime._visible_params = visible  # noqa: SLF001
    return len(visible)


def _visible(machine: Machine) -> list[str]:
    _builtin_paramcount(machine, [])
    return machine.runtime._visible_params  # noqa: SLF001


def _builtin_paramstr(machine: Machine, args):
    index = int(_arg(machine, args[0]))
    visible = _visible(machine)
    if index == 0:
        return "C:\\BlaziumLauncher-Setup.exe"
    if 1 <= index <= len(visible):
        return visible[index - 1]
    return ""


def _builtin_log(machine: Machine, args):
    machine.runtime.outcome.trace.append(str(_arg(machine, args[0])))
    return None


def _builtin_msg(machine: Machine, args):
    return 1


def _builtin_regquery(machine: Machine, args):
    _set_var(machine, args[3], "")
    return False


def _builtin_regkey(machine: Machine, args):
    return False


def _builtin_regwrite(machine: Machine, args):
    return None


def _builtin_saved(machine: Machine, args):
    path = str(_arg(machine, args[0]))
    contents = str(_arg(machine, args[1]))
    machine.runtime.put_file(
        path,
        DiskFile(f"text:{contents}", "NotSigned", "", False, "installer"),
        created=True,
    )
    return True


def _builtin_forcedirs(machine: Machine, args):
    return True


def _builtin_filecopy(machine: Machine, args):
    src = str(_arg(machine, args[0]))
    dst = str(_arg(machine, args[1]))
    found = machine.runtime.file_of(src)
    if found is None:
        return False
    _stored, rec = found
    copied = DiskFile(
        rec.content_id,
        rec.status,
        rec.subject,
        writable=not protected_dir(dst),
        provenance=rec.provenance,
    )
    machine.runtime.put_file(dst, copied, created=True)
    return True


def _builtin_deletefile(machine: Machine, args):
    path = str(_arg(machine, args[0]))
    found = machine.runtime.file_of(path)
    if found is None:
        return False
    machine.runtime.outcome.deleted.append(path)
    del machine.runtime.files[_norm(path)]
    return True


def _builtin_tasks_select(machine: Machine, args):
    machine.runtime.tasks.add(str(_arg(machine, args[0])).lower())
    return None


def _builtin_task_selected(machine: Machine, args):
    return str(_arg(machine, args[0])).lower() in machine.runtime.tasks


def _builtin_wizsilent(machine: Machine, args):
    # Setup.ScriptFunc.pas:1759-1761. InstallMode <> imNormal.
    return machine.runtime.outcome.silent


def _exec(machine: Machine, args, *, elevated: bool):
    filename = str(_arg(machine, args[0]))
    params = str(_arg(machine, args[1]))
    code = 1
    ok = False
    leaf = filename.rsplit("\\", 1)[-1].lower()
    if leaf in ("powershell.exe", "pwsh.exe"):
        runner = _PowerShell(machine.runtime, params)
        try:
            code = runner.run()
        except _Return:
            code = runner.exit_code
        publisher = machine.runtime.publisher
        # The comparison has to name the publisher pinned in select_hub.ps1.
        # A command that exits 0 without that test is not the catalog check.
        if code == 0 and runner.checked and publisher in runner.command:
            for value in runner.vars.values():
                if isinstance(value, _Sig) and value.path and publisher_accepts(value.status, value.subject, publisher):
                    machine.runtime.note_verified(value.path)
        ok = True
    else:
        ok = machine.runtime.launch(
            filename,
            params,
            elevated=elevated and machine.runtime.outcome.elevated_process,
        )
        code = 0 if ok else 2
    _set_var(machine, args[5], code)
    return ok


def _builtin_exec(machine: Machine, args):
    # Exec uses InstExec in the elevated setup process.
    # Setup.ScriptFunc.pas:1048-1078 and Setup.SpawnClient.pas:142-152.
    return _exec(machine, args, elevated=True)


def _builtin_exec_original(machine: Machine, args):
    # ExecAsOriginalUser asks the unelevated parent to create the process.
    # Setup.SpawnClient.pas:150-167.
    return _exec(machine, args, elevated=False)


_BUILTINS = {
    "length": _builtin_length,
    "copy": _builtin_copy,
    "pos": _builtin_pos,
    "delete": _builtin_delete,
    "uppercase": _builtin_uppercase,
    "inttostr": _builtin_inttostr,
    "addbackslash": _builtin_addbackslash,
    "extractfilepath": _builtin_extract,
    "expandconstant": _builtin_expand,
    "getenv": _builtin_getenv,
    "fileexists": _builtin_fileexists,
    "paramcount": _builtin_paramcount,
    "paramstr": _builtin_paramstr,
    "log": _builtin_log,
    "suppressiblemsgbox": _builtin_msg,
    "regquerystringvalue": _builtin_regquery,
    "regkeyexists": _builtin_regkey,
    "regwriteexpandstringvalue": _builtin_regwrite,
    "regwritestringvalue": _builtin_regwrite,
    "regdeletevalue": _builtin_regwrite,
    "regdeletekeyincludingsubkeys": _builtin_regwrite,
    "savestringtofile": _builtin_saved,
    "forcedirectories": _builtin_forcedirs,
    "filecopy": _builtin_filecopy,
    "deletefile": _builtin_deletefile,
    "wizardselecttasks": _builtin_tasks_select,
    "wizardistaskselected": _builtin_task_selected,
    "istaskselected": _builtin_task_selected,
    "wizardsilent": _builtin_wizsilent,
    "exec": _builtin_exec,
    "execasoriginaluser": _builtin_exec_original,
}


def _preprocess(iss_text: str) -> str:
    defines = {
        "MyAppVersion": "0.1.0",
        "MyAppExeName": "BlaziumLauncher.exe",
        "MyAppName": "BlaziumLauncher",
    }
    # #define lines override. Quotes around the value are ISPP syntax.
    for line in iss_text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#define "):
            parts = stripped.split(None, 2)
            if len(parts) == 3:
                defines[parts[1]] = parts[2].strip().strip('"')
    start = iss_text.index("[Code]")
    code = iss_text[start + len("[Code]") :]
    for name, value in defines.items():
        code = code.replace("{#" + name + "}", value)
    return code


def run_installer(iss_text: str, select_hub_text: str, user_command: str, files: dict[str, DiskFile], *, race: bool = False) -> Outcome:
    """InitializeSetup, then CurStepChanged(ssPostInstall), in the elevated process.

    The unelevated process halts in RespawnSetupElevated before it loads the
    script (Setup.MainFunc.pas:3498-3500 and 3729-3751). Very silent and
    silent installs still reach ssPostInstall (Setup.MainFunc.pas:3951-3956,
    Setup.MainForm.pas:254).
    """
    code = _preprocess(iss_text)
    consts, funcs = Parser(code).parse()
    runtime = Runtime(iss_text, select_hub_text, user_command, files, race)
    machine = Machine(runtime, consts, funcs)
    for name in ("HubSetup", "SkipProtocol", "CliWasPresent"):
        if name.lower() not in machine.globals:
            machine.globals[name.lower()] = ""
    machine.globals["skipprotocol"] = False
    machine.globals["cliwaspresent"] = False
    machine.globals["hubsetup"] = ""
    machine.call("InitializeSetup", [])
    # TSetupStep ordinal. Shared.SetupSteps.pas:15. SetStep passes Ord(CurStep)
    # (Setup.MainForm.pas:61-66).
    machine.call("CurStepChanged", [2])
    return runtime.outcome
