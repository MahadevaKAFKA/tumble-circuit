#!/usr/bin/env python3
"""Offline Luau checker for Tumble Circuit.

Runs without Roblox Studio or any Luau toolchain:
  1. Parses every .luau/.lua file with a Luau grammar (Lua 5.1 + compound
     assignment, `continue`, if-expressions, generalised iteration). Syntax
     errors fail the run.
  2. Resolves every name against lexical scopes and reports
       - reads of globals that are not Roblox / Luau built-ins (typos),
       - writes to globals (accidental globals),
       - unused locals (warning only).
  3. Cross-checks module usage: `X.field` where X = require(...("Module"))
     must be a field the module actually defines.

Usage: python3 tools/luau_check.py src [more paths...]
Exit code 0 = clean, 1 = errors found.
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass, field

# --------------------------------------------------------------------------
# Known globals
# --------------------------------------------------------------------------

LUAU_GLOBALS = {
    "assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall",
    "print", "rawequal", "rawget", "rawlen", "rawset", "require", "select",
    "setmetatable", "tonumber", "tostring", "type", "typeof", "unpack",
    "xpcall", "gcinfo", "newproxy", "_G", "_VERSION",
    "math", "string", "table", "coroutine", "os", "debug", "utf8", "bit32",
    "buffer", "vector",
}

ROBLOX_GLOBALS = {
    "game", "workspace", "script", "plugin", "shared", "task", "warn", "tick",
    "time", "wait", "delay", "spawn", "elapsedTime", "settings", "UserSettings",
    "Enum", "Instance", "Vector3", "Vector2", "Vector3int16", "Vector2int16",
    "CFrame", "Color3", "ColorSequence", "ColorSequenceKeypoint", "NumberRange",
    "NumberSequence", "NumberSequenceKeypoint", "UDim", "UDim2", "Rect",
    "Region3", "Region3int16", "Ray", "RaycastParams", "OverlapParams",
    "PhysicalProperties", "TweenInfo", "BrickColor", "Axes", "Faces", "Font",
    "DateTime", "PathWaypoint", "Random", "CatalogSearchParams", "SharedTable",
    "DockWidgetPluginGuiInfo", "FloatCurveKey", "RotationCurveKey", "Content",
}

KNOWN_GLOBALS = LUAU_GLOBALS | ROBLOX_GLOBALS

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
}

COMPOUND_OPS = {"+=", "-=", "*=", "/=", "//=", "%=", "^=", "..="}


class LuauSyntaxError(Exception):
    def __init__(self, message: str, line: int):
        super().__init__(f"line {line}: {message}")
        self.line = line


# --------------------------------------------------------------------------
# Tokenizer
# --------------------------------------------------------------------------

@dataclass
class Token:
    kind: str  # name, keyword, number, string, op, eof
    value: str
    line: int


OPERATORS = sorted(
    [
        "...", "..=", "//=", "==", "~=", "<=", ">=", "//", "+=", "-=", "*=",
        "/=", "%=", "^=", "..", "::", "->", "+", "-", "*", "/", "%", "^", "#",
        "=", "<", ">", "(", ")", "{", "}", "[", "]", ";", ":", ",", ".", "&",
        "|", "?",
    ],
    key=len,
    reverse=True,
)

NUMBER_RE = re.compile(
    r"0[xX][0-9a-fA-F_]+|0[bB][01_]+|(?:[0-9][0-9_]*\.?[0-9_]*|\.[0-9][0-9_]*)(?:[eE][+-]?[0-9_]+)?"
)
NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def _long_bracket_level(src: str, i: int) -> int:
    """If src[i] starts `[==[`, return the level (number of '='), else -1."""
    if src[i] != "[":
        return -1
    j = i + 1
    while j < len(src) and src[j] == "=":
        j += 1
    if j < len(src) and src[j] == "[":
        return j - i - 1
    return -1


def tokenize(src: str) -> list[Token]:
    tokens: list[Token] = []
    i = 0
    line = 1
    n = len(src)
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r\f\v":
            i += 1
            continue
        if src.startswith("--", i):
            j = i + 2
            level = _long_bracket_level(src, j) if j < n else -1
            if level >= 0:
                close = "]" + "=" * level + "]"
                end = src.find(close, j)
                if end < 0:
                    raise LuauSyntaxError("unfinished long comment", line)
                line += src.count("\n", i, end)
                i = end + len(close)
            else:
                end = src.find("\n", i)
                i = n if end < 0 else end
            continue
        if c == "[":
            level = _long_bracket_level(src, i)
            if level >= 0:
                close = "]" + "=" * level + "]"
                start = i + level + 2
                end = src.find(close, start)
                if end < 0:
                    raise LuauSyntaxError("unfinished long string", line)
                value = src[start:end]
                tokens.append(Token("string", value, line))
                line += src.count("\n", i, end)
                i = end + len(close)
                continue
        if c in "\"'`":
            quote = c
            j = i + 1
            buf = []
            start_line = line
            while True:
                if j >= n:
                    raise LuauSyntaxError("unfinished string", start_line)
                ch = src[j]
                if ch == "\\":
                    if j + 1 < n and src[j + 1] == "\n":
                        line += 1
                    buf.append(src[j : j + 2])
                    j += 2
                    continue
                if ch == "\n":
                    if quote == "`":
                        line += 1
                        buf.append(ch)
                        j += 1
                        continue
                    raise LuauSyntaxError("unfinished string (newline)", start_line)
                if ch == quote:
                    break
                buf.append(ch)
                j += 1
            tokens.append(Token("string", "".join(buf), start_line))
            i = j + 1
            continue
        if c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit()):
            m = NUMBER_RE.match(src, i)
            if not m or not m.group(0):
                raise LuauSyntaxError("malformed number", line)
            tokens.append(Token("number", m.group(0), line))
            i = m.end()
            if i < n and (src[i].isalnum() or src[i] == "_"):
                raise LuauSyntaxError("malformed number", line)
            continue
        if c.isalpha() or c == "_":
            m = NAME_RE.match(src, i)
            word = m.group(0)
            tokens.append(Token("keyword" if word in KEYWORDS else "name", word, line))
            i = m.end()
            continue
        for op in OPERATORS:
            if src.startswith(op, i):
                tokens.append(Token("op", op, line))
                i += len(op)
                break
        else:
            raise LuauSyntaxError(f"unexpected character {c!r}", line)
    tokens.append(Token("eof", "<eof>", line))
    return tokens


# --------------------------------------------------------------------------
# Parser with scope tracking
# --------------------------------------------------------------------------

@dataclass
class Local:
    name: str
    line: int
    used: bool = False
    is_param: bool = False


@dataclass
class Report:
    path: str
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


BINARY_PRIORITY = {
    "or": (1, 1), "and": (2, 2),
    "<": (3, 3), ">": (3, 3), "<=": (3, 3), ">=": (3, 3), "~=": (3, 3), "==": (3, 3),
    "..": (5, 4),  # right associative
    "+": (6, 6), "-": (6, 6),
    "*": (7, 7), "/": (7, 7), "//": (7, 7), "%": (7, 7),
    "^": (10, 9),  # right associative
}
UNARY_PRIORITY = 8


class Parser:
    def __init__(self, tokens: list[Token], report: Report):
        self.t = tokens
        self.p = 0
        self.report = report
        self.scopes: list[dict[str, Local]] = []
        self.loop_depth = 0

    # -- token helpers ------------------------------------------------------
    @property
    def tok(self) -> Token:
        return self.t[self.p]

    def peek(self, k: int = 1) -> Token:
        return self.t[min(self.p + k, len(self.t) - 1)]

    def check(self, value: str) -> bool:
        tok = self.tok
        return tok.kind in ("op", "keyword") and tok.value == value

    def accept(self, value: str) -> bool:
        if self.check(value):
            self.p += 1
            return True
        return False

    def expect(self, value: str, context: str = "") -> Token:
        if not self.check(value):
            where = f" {context}" if context else ""
            raise LuauSyntaxError(f"expected '{value}'{where}, got '{self.tok.value}'", self.tok.line)
        tok = self.tok
        self.p += 1
        return tok

    def expect_name(self) -> Token:
        if self.tok.kind != "name":
            raise LuauSyntaxError(f"expected a name, got '{self.tok.value}'", self.tok.line)
        tok = self.tok
        self.p += 1
        return tok

    # -- scopes ---------------------------------------------------------------
    def open_scope(self):
        self.scopes.append({})

    def close_scope(self):
        scope = self.scopes.pop()
        for local in scope.values():
            if not local.used and not local.name.startswith("_") and not local.is_param:
                self.report.warnings.append(f"line {local.line}: unused local '{local.name}'")

    def declare(self, name: str, line: int, is_param: bool = False):
        scope = self.scopes[-1]
        previous = scope.get(name)
        if previous and not previous.used and not name.startswith("_") and not previous.is_param:
            self.report.warnings.append(f"line {previous.line}: local '{name}' redeclared before use")
        scope[name] = Local(name, line, is_param=is_param)

    def resolve(self, name: str, line: int, write: bool):
        for scope in reversed(self.scopes):
            if name in scope:
                if not write:
                    scope[name].used = True
                return
        if write:
            self.report.errors.append(f"line {line}: assignment to global '{name}' (missing 'local'?)")
        elif name not in KNOWN_GLOBALS:
            self.report.errors.append(f"line {line}: unknown global '{name}'")

    # -- types (minimal: skip simple annotations if present) ------------------
    def skip_type(self):
        depth = 0
        while True:
            tok = self.tok
            if tok.kind == "eof":
                return
            if tok.value in ("(", "{", "<", "[") and tok.kind == "op":
                depth += 1
            elif tok.value in (")", "}", ">", "]") and tok.kind == "op":
                if depth == 0:
                    return
                depth -= 1
            elif depth == 0 and tok.value in (",", "=", ";") and tok.kind == "op":
                return
            elif depth == 0 and tok.kind == "keyword" and tok.value not in ("nil",):
                return
            self.p += 1

    # -- grammar ----------------------------------------------------------------
    def chunk(self):
        self.open_scope()
        self.block()
        if self.tok.kind != "eof":
            raise LuauSyntaxError(f"unexpected '{self.tok.value}'", self.tok.line)
        self.close_scope()

    def block_ends(self) -> bool:
        tok = self.tok
        return tok.kind == "eof" or (tok.kind == "keyword" and tok.value in ("end", "else", "elseif", "until"))

    def block(self):
        while not self.block_ends():
            if self.check("return"):
                self.p += 1
                if not self.block_ends() and not self.check(";"):
                    self.explist()
                self.accept(";")
                if not self.block_ends():
                    raise LuauSyntaxError("'return' must be the last statement in a block", self.tok.line)
                return
            self.statement()

    def scoped_block(self):
        self.open_scope()
        self.block()
        self.close_scope()

    def statement(self):
        tok = self.tok
        line = tok.line
        if self.accept(";"):
            return
        if tok.kind == "keyword":
            v = tok.value
            if v == "if":
                self.p += 1
                self.expr()
                self.expect("then", "after if condition")
                self.scoped_block()
                while self.accept("elseif"):
                    self.expr()
                    self.expect("then", "after elseif condition")
                    self.scoped_block()
                if self.accept("else"):
                    self.scoped_block()
                self.expect("end", f"to close 'if' at line {line}")
                return
            if v == "while":
                self.p += 1
                self.expr()
                self.expect("do", "after while condition")
                self.loop_body(line, "while")
                return
            if v == "do":
                self.p += 1
                self.scoped_block()
                self.expect("end", f"to close 'do' at line {line}")
                return
            if v == "for":
                self.p += 1
                self.for_statement(line)
                return
            if v == "repeat":
                self.p += 1
                self.open_scope()
                self.loop_depth += 1
                self.block()
                self.loop_depth -= 1
                self.expect("until", f"to close 'repeat' at line {line}")
                self.expr()  # condition can see the block's locals
                self.close_scope()
                return
            if v == "function":
                self.p += 1
                name = self.expect_name()
                is_method = False
                path_is_plain = True
                while self.check(".") or self.check(":"):
                    if self.check(":"):
                        is_method = True
                    self.p += 1
                    self.expect_name()
                    path_is_plain = False
                self.resolve(name.value, name.line, write=path_is_plain)
                if not path_is_plain:
                    self.resolve(name.value, name.line, write=False)
                self.funcbody(line, is_method)
                return
            if v == "local":
                self.p += 1
                if self.accept("function"):
                    name = self.expect_name()
                    self.declare(name.value, name.line)
                    self.funcbody(line, False)
                    return
                names = [self.expect_name()]
                self.attrib_or_type()
                while self.accept(","):
                    names.append(self.expect_name())
                    self.attrib_or_type()
                if self.accept("="):
                    self.explist()
                for name in names:
                    self.declare(name.value, name.line)
                return
            if v == "break":
                self.p += 1
                if self.loop_depth == 0:
                    raise LuauSyntaxError("'break' outside a loop", line)
                return
            if v == "return":
                raise LuauSyntaxError("unexpected 'return'", line)
            raise LuauSyntaxError(f"unexpected '{v}'", line)

        if tok.kind == "name" and tok.value == "continue":
            nxt = self.peek()
            if not (nxt.kind == "op" and nxt.value in ("(", "=", ".", "[", ":", ",", "{")) and nxt.kind != "string" and not (
                nxt.kind == "op" and nxt.value in COMPOUND_OPS
            ):
                self.p += 1
                if self.loop_depth == 0:
                    raise LuauSyntaxError("'continue' outside a loop", line)
                return
        if tok.kind == "name" and tok.value in ("type", "export") and self.peek().kind == "name":
            raise LuauSyntaxError("type declarations are not supported by this checker", line)

        # expression statement: call or assignment
        target = self.suffixedexp(defer_name=True)
        if self.check("=") or self.check(","):
            targets = [target]
            while self.accept(","):
                targets.append(self.suffixedexp(defer_name=True))
            for kind, name, tline in targets:
                if kind == "call":
                    raise LuauSyntaxError("cannot assign to a function call", tline)
            self.expect("=")
            self.explist()
            for kind, name, tline in targets:
                if kind == "name":
                    self.resolve(name, tline, write=True)
            return
        if self.tok.kind == "op" and self.tok.value in COMPOUND_OPS:
            kind, name, tline = target
            if kind == "call":
                raise LuauSyntaxError("cannot assign to a function call", tline)
            self.p += 1
            self.expr()
            if kind == "name":
                self.resolve(name, tline, write=False)
                self.resolve(name, tline, write=True)
            return
        if target[0] != "call":
            if target[0] == "name":
                self.resolve(target[1], target[2], write=False)
            raise LuauSyntaxError("expression is not a statement (missing call or '=')", line)

    def attrib_or_type(self):
        if self.accept(":"):
            self.skip_type()

    def loop_body(self, line: int, what: str):
        self.loop_depth += 1
        self.scoped_block()
        self.loop_depth -= 1
        self.expect("end", f"to close '{what}' at line {line}")

    def for_statement(self, line: int):
        first = self.expect_name()
        self.attrib_or_type()
        if self.accept("="):
            self.expr()
            self.expect(",", "in numeric for")
            self.expr()
            if self.accept(","):
                self.expr()
            self.expect("do", "in numeric for")
            self.open_scope()
            self.declare(first.value, first.line)
            self.scopes[-1][first.value].used = True  # loop counters are often unused by design
            self.loop_depth += 1
            self.block()
            self.loop_depth -= 1
            self.close_scope()
            self.expect("end", f"to close 'for' at line {line}")
            return
        names = [first]
        while self.accept(","):
            names.append(self.expect_name())
            self.attrib_or_type()
        self.expect("in", "in generic for")
        self.explist()
        self.expect("do", "in generic for")
        self.open_scope()
        for name in names:
            self.declare(name.value, name.line)
        self.loop_depth += 1
        self.block()
        self.loop_depth -= 1
        self.close_scope()
        self.expect("end", f"to close 'for' at line {line}")

    def funcbody(self, line: int, is_method: bool):
        saved_loop = self.loop_depth
        self.loop_depth = 0
        self.open_scope()
        if is_method:
            self.declare("self", line, is_param=True)
        self.expect("(", "to start parameter list")
        if not self.check(")"):
            while True:
                if self.accept("..."):
                    self.declare("...", line, is_param=True)
                    if self.accept(":"):
                        self.skip_type()
                    break
                name = self.expect_name()
                self.declare(name.value, name.line, is_param=True)
                if self.accept(":"):
                    self.skip_type()
                if not self.accept(","):
                    break
        self.expect(")", "to close parameter list")
        if self.accept(":"):
            self.skip_type()
        self.block()
        self.expect("end", f"to close 'function' at line {line}")
        self.close_scope()
        self.loop_depth = saved_loop

    def explist(self):
        self.expr()
        while self.accept(","):
            self.expr()

    def expr(self, limit: int = 0):
        tok = self.tok
        if (tok.kind == "keyword" and tok.value == "not") or (tok.kind == "op" and tok.value in ("-", "#")):
            self.p += 1
            self.expr(UNARY_PRIORITY)
        else:
            self.simpleexp()
        while True:
            tok = self.tok
            if tok.kind not in ("op", "keyword") or tok.value not in BINARY_PRIORITY:
                break
            left, right = BINARY_PRIORITY[tok.value]
            if left <= limit:
                break
            self.p += 1
            self.expr(right)
        if self.check("::"):
            self.p += 1
            self.skip_type()

    def simpleexp(self):
        tok = self.tok
        if tok.kind in ("number", "string"):
            self.p += 1
            return
        if tok.kind == "keyword":
            if tok.value in ("nil", "true", "false"):
                self.p += 1
                return
            if tok.value == "function":
                self.p += 1
                self.funcbody(tok.line, False)
                return
            if tok.value == "if":
                self.p += 1
                self.expr()
                self.expect("then", "in if-expression")
                self.expr()
                while self.accept("elseif"):
                    self.expr()
                    self.expect("then", "in if-expression")
                    self.expr()
                self.expect("else", "in if-expression (else is required)")
                self.expr()
                return
        if tok.kind == "op" and tok.value == "...":
            self.p += 1
            for scope in reversed(self.scopes):
                if "..." in scope:
                    return
            if len(self.scopes) > 1:
                raise LuauSyntaxError("'...' used outside a vararg function", tok.line)
            return
        if tok.kind == "op" and tok.value == "{":
            self.table()
            return
        self.suffixedexp()

    def table(self):
        line = self.tok.line
        self.expect("{")
        while not self.check("}"):
            if self.check("["):
                self.p += 1
                self.expr()
                self.expect("]")
                self.expect("=")
                self.expr()
            elif self.tok.kind == "name" and self.peek().kind == "op" and self.peek().value == "=":
                self.p += 2
                self.expr()
            else:
                self.expr()
            if not (self.accept(",") or self.accept(";")):
                break
        self.expect("}", f"to close table at line {line}")

    def primaryexp(self, defer_name: bool = False):
        tok = self.tok
        if tok.kind == "name":
            self.p += 1
            if not defer_name:
                self.resolve(tok.value, tok.line, write=False)
            return ("name", tok.value, tok.line)
        if self.accept("("):
            self.expr()
            self.expect(")")
            return ("paren", None, tok.line)
        raise LuauSyntaxError(f"unexpected '{tok.value}'", tok.line)

    def _is_suffix(self) -> bool:
        tok = self.tok
        return tok.kind == "string" or (tok.kind == "op" and tok.value in (".", "[", ":", "(", "{"))

    def suffixedexp(self, defer_name: bool = False):
        """Parse a prefix expression with its suffixes.

        With defer_name=True (statement level) a bare name that is NOT followed
        by a suffix is returned unresolved, so the caller can treat it as an
        assignment target (write) instead of a read.
        """
        kind, name, line = self.primaryexp(defer_name=True)
        if kind == "name":
            if not defer_name or self._is_suffix():
                self.resolve(name, line, write=False)
        while True:
            tok = self.tok
            if tok.kind == "op" and tok.value == ".":
                self.p += 1
                self.expect_name()
                kind = "index"
            elif tok.kind == "op" and tok.value == "[":
                self.p += 1
                self.expr()
                self.expect("]")
                kind = "index"
            elif tok.kind == "op" and tok.value == ":":
                self.p += 1
                self.expect_name()
                self.call_args()
                kind = "call"
            elif (tok.kind == "op" and tok.value in ("(", "{")) or tok.kind == "string":
                if tok.kind == "op" and tok.value == "(" and tok.line != self.t[self.p - 1].line:
                    raise LuauSyntaxError("ambiguous syntax: call arguments start on a new line", tok.line)
                self.call_args()
                kind = "call"
            else:
                break
        return (kind, name if kind == "name" else None, line)

    def call_args(self):
        tok = self.tok
        if tok.kind == "string":
            self.p += 1
            return
        if self.check("{"):
            self.table()
            return
        self.expect("(")
        if not self.check(")"):
            self.explist()
        self.expect(")", "to close call arguments")


# --------------------------------------------------------------------------
# Module cross-reference check
# --------------------------------------------------------------------------

REQUIRE_RE = re.compile(
    r"local\s+(\w+)\s*=\s*require\(\s*[\w.:]*?(?:WaitForChild|FindFirstChild)\(\s*\"(\w+)\"\s*\)\s*\)"
)
REQUIRE_CHAIN_RE = re.compile(
    r"local\s+(\w+)\s*=\s*require\((?:[^()]|\([^()]*\))*?\"(\w+)\"\s*\)\s*\)"
)
RETURN_RE = re.compile(r"^return\s+(\w+)\s*$", re.M)

# Values passed between modules under a different local name.
ALIASES: dict[str, dict[str, str]] = {}


def module_fields(path: str) -> tuple[str | None, set[str]]:
    with open(path, encoding="utf-8") as f:
        src = f.read()
    m = RETURN_RE.search(src)
    if not m:
        # `return { Key = ..., ... }` (e.g. PLACEHOLDER_IDS.lua): the depth-1 keys of that table
        code = strip_comments_and_strings(src)
        r = re.search(r"(?m)^return\s*\{", code)
        if not r:
            return None, set()
        keys, depth, line_start = set(), 0, True
        i = r.end() - 1
        while i < len(code):
            c = code[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    break
            elif depth == 1:
                km = re.match(r"\s*(\w+)\s*=[^=]", code[i:])
                if km and (code[i - 1] in "{,\n"):
                    keys.add(km.group(1))
            i += 1
        return None, keys
    table = m.group(1)
    fields = set(re.findall(rf"(?m)^\s*(?:function\s+)?{re.escape(table)}[.:](\w+)", src))
    fields |= set(re.findall(rf"{re.escape(table)}\.(\w+)\s*=[^=]", src))
    return table, fields


def json_module_fields(path: str) -> set[str]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return set(data.keys()) if isinstance(data, dict) else set()


def strip_comments_and_strings(src: str) -> str:
    out = re.sub(r"--\[(=*)\[.*?\]\1\]", "", src, flags=re.S)
    out = re.sub(r"--[^\n]*", "", out)
    out = re.sub(r"\"(?:\\.|[^\"\\])*\"", '""', out)
    out = re.sub(r"'(?:\\.|[^'\\])*'", "''", out)
    return out


def project_renames(project_path: str = "default.project.json") -> dict[str, str]:
    """Module names the Rojo project gives to single files under a different name."""
    renames: dict[str, str] = {}
    if not os.path.isfile(project_path):
        return renames
    with open(project_path, encoding="utf-8") as f:
        tree = json.load(f).get("tree", {})

    def walk(node):
        for key, child in node.items():
            if key.startswith("$") or not isinstance(child, dict):
                continue
            target = child.get("$path")
            if isinstance(target, str) and os.path.isfile(target):
                renames[key] = target
            walk(child)

    walk(tree)
    return renames


def cross_reference(files: list[str]) -> dict[str, list[str]]:
    modules: dict[str, set[str]] = {}
    for name, target in project_renames().items():
        if target.endswith(".json"):
            modules[name] = json_module_fields(target)
        else:
            modules[name] = module_fields(target)[1]
    for path in files:
        base = os.path.basename(path)
        name = re.sub(r"(\.server|\.client)?\.(luau|lua|json)$", "", base)
        if name == "init":
            continue
        if base.endswith(".json"):
            modules[name] = json_module_fields(path)
        else:
            _, fields = module_fields(path)
            modules[name] = fields

    problems: dict[str, list[str]] = {}
    for path in files:
        if path.endswith(".json"):
            continue
        with open(path, encoding="utf-8") as f:
            src = f.read()
        code = strip_comments_and_strings(src)
        bindings: dict[str, str] = {}
        for regex in (REQUIRE_RE, REQUIRE_CHAIN_RE):
            for local_name, module_name in regex.findall(src):
                bindings[local_name] = module_name
        bindings.update(ALIASES.get(os.path.basename(path), {}))
        for local_name, module_name in bindings.items():
            if module_name not in modules:
                problems.setdefault(path, []).append(f"requires unknown module '{module_name}'")
                continue
            known = modules[module_name]
            for used in set(re.findall(rf"(?<![\w.:]){re.escape(local_name)}[.:](\w+)", code)):
                if used not in known:
                    problems.setdefault(path, []).append(
                        f"'{local_name}.{used}' is not defined by module {module_name}"
                    )
    return problems


# --------------------------------------------------------------------------
# Config key check: <XConfig>.Section.Key, and `local a = XConfig.Section` aliases
# (applies to every module whose file name ends in "Config", e.g. GameConfig.lua)
# --------------------------------------------------------------------------

def config_keys(config_path: str, name: str) -> dict[str, set[str]]:
    with open(config_path, encoding="utf-8") as f:
        src = f.read()
    code = strip_comments_and_strings(src)
    sections: dict[str, set[str]] = {}
    # `Name.Section = { ... }`: take the balanced table (a one-line table such as
    # `X.Owned = { "a", "b" }` must not swallow the sections that follow it)
    for m in re.finditer(rf"(?m)^{name}\.(\w+)\s*=\s*\{{", code):
        depth, i = 0, m.end() - 1
        while i < len(code):
            if code[i] == "{":
                depth += 1
            elif code[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = code[m.end():i]
        sections[m.group(1)] = set(re.findall(r"(?m)^\s*(\w+)\s*=", body))
    for m in re.finditer(rf"(?m)^{name}\.(\w+)\s*=\s*[^{{\s]", code):
        sections.setdefault(m.group(1), set())
    # helper functions on a config module (e.g. ProgressionConfig.LevelForXp)
    for m in re.finditer(rf"(?m)^function\s+{name}\.(\w+)\s*\(", code):
        sections.setdefault(m.group(1), set())
    return sections


def config_check(files: list[str], config_paths: list[str]) -> dict[str, list[str]]:
    problems: dict[str, list[str]] = {}
    for config_path in config_paths:
        name = re.sub(r"\.(luau|lua)$", "", os.path.basename(config_path))
        sections = config_keys(config_path, name)
        for path in files:
            if not path.endswith((".luau", ".lua")):
                continue
            with open(path, encoding="utf-8") as f:
                code = strip_comments_and_strings(f.read())
            if not re.search(rf"\b{name}\b", code):
                continue
            for section, key in re.findall(rf"\b{name}\.(\w+)\.(\w+)", code):
                if section not in sections:
                    problems.setdefault(path, []).append(f"{name}.{section} does not exist")
                elif key not in sections[section]:
                    problems.setdefault(path, []).append(f"{name}.{section}.{key} does not exist")
            for section in re.findall(rf"\b{name}\.(\w+)\b(?!\s*=)", code):
                if section not in sections:
                    problems.setdefault(path, []).append(f"{name}.{section} does not exist")
            # aliases: the same local name may be bound to different sections in different
            # functions, so accept a key that exists in any section bound to that alias
            alias_sections: dict[str, set[str]] = {}
            for alias, section in re.findall(rf"local\s+(\w+)\s*=\s*{name}\.(\w+)\s*$", code, flags=re.M):
                alias_sections.setdefault(alias, set()).add(section)
            for alias, bound in alias_sections.items():
                keys = set().union(*(sections.get(sec, set()) for sec in bound))
                for key in set(re.findall(rf"(?<![\w.:]){re.escape(alias)}\.(\w+)", code)):
                    if key not in keys:
                        problems.setdefault(path, []).append(
                            f"{alias}.{key} ({name}.{'/'.join(sorted(bound))}.{key}) does not exist")
    return problems


# --------------------------------------------------------------------------

def collect(paths: list[str]) -> list[str]:
    files = []
    for path in paths:
        if os.path.isdir(path):
            for root, _, names in os.walk(path):
                for name in sorted(names):
                    if name.endswith((".luau", ".lua")) or (
                        name.endswith(".json") and not name.endswith((".project.json", ".meta.json", ".model.json"))
                    ):
                        files.append(os.path.join(root, name))
        else:
            files.append(path)
    return sorted(files)


# --------------------------------------------------------------------------
# Server start-up: the server builds the world, so it must never wait on workspace for something
# it has not made yet. An unbounded workspace:WaitForChild(name) in a service stalls the boot
# script forever if the thing is created by a service started later (A3, 2026-11-25: the
# MicroSkillService waited for TumbleMarbles, which MarbleCharacterService:Start makes last).
# --------------------------------------------------------------------------

def server_wait_check(files: list[str]) -> dict[str, list[str]]:
    problems: dict[str, list[str]] = {}
    for path in files:
        norm = path.replace(os.sep, "/")
        if not norm.endswith((".lua", ".luau")) or "/Tests/" in norm:
            continue
        if "ServerScriptService/" not in norm and "ServerStorage/" not in norm:
            continue
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
        for line, text in enumerate(lines, start=1):
            text = re.sub(r"--.*", "", text)
            # Unanchoring a frozen marble in place left it unable to move at GO, for humans
            # (2026-11-23) and bots (2026-11-25); GO must spawn a fresh free marble instead.
            if re.search(r"\b\w*[Bb]all\w*\s*\.\s*Anchored\s*=\s*false\b", text):
                problems.setdefault(path, []).append(
                    f"line {line}: a marble is unanchored in place (it may not move); "
                    "respawn a fresh free marble instead (see BUILD_STATUS 2026-11-25)")
            for m in re.finditer(r"\bworkspace\s*:\s*WaitForChild\s*\(([^()]*)\)", text):
                if "," in m.group(1):
                    continue
                problems.setdefault(path, []).append(
                    f"line {line}: server code waits on workspace with no timeout "
                    "(can deadlock start-up; create it or use FindFirstChild)")
    return problems


def check_file(path: str) -> Report:
    report = Report(path)
    with open(path, encoding="utf-8") as f:
        src = f.read()
    try:
        parser = Parser(tokenize(src), report)
        parser.chunk()
    except LuauSyntaxError as exc:
        report.errors.append(f"syntax error: {exc}")
    return report


def main(argv: list[str]) -> int:
    paths = argv[1:] or ["src"]
    files = collect(paths)
    if not files:
        print("no Luau files found", file=sys.stderr)
        return 1
    total_errors = 0
    total_warnings = 0
    for path in files:
        if path.endswith(".json"):
            try:
                with open(path, encoding="utf-8") as f:
                    json.load(f)
            except json.JSONDecodeError as exc:
                print(f"ERROR {path}: invalid JSON: {exc}")
                total_errors += 1
            continue
        report = check_file(path)
        for err in report.errors:
            print(f"ERROR {path}: {err}")
        for warn in report.warnings:
            print(f"warn  {path}: {warn}")
        total_errors += len(report.errors)
        total_warnings += len(report.warnings)

    for path, issues in cross_reference(files).items():
        for issue in issues:
            print(f"ERROR {path}: {issue}")
            total_errors += 1

    config_paths = [f for f in files if re.search(r"Config\.(luau|lua)$", os.path.basename(f))]
    if config_paths:
        for path, issues in config_check(files, config_paths).items():
            for issue in sorted(set(issues)):
                print(f"ERROR {path}: {issue}")
                total_errors += 1

    for path, issues in server_wait_check(files).items():
        for issue in issues:
            print(f"ERROR {path}: {issue}")
            total_errors += 1

    luau_count = sum(1 for f in files if not f.endswith(".json"))
    print(f"\nchecked {luau_count} Luau files + {len(files) - luau_count} JSON modules: "
          f"{total_errors} error(s), {total_warnings} warning(s)")
    return 1 if total_errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
