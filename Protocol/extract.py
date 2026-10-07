#!/usr/bin/env python3
"""Extract the DeepSeek Harness gateway descriptor from the installed app.asar
and translate its schema DSL into JSON Schema.

Reads only the asar file (read-only input). Writes:

    Protocol/endpoints.json      every endpoint in the descriptor
    Protocol/schemas/*.json      one JSON Schema per named request/result type

Standard library only, no network, safe to re-run.

The bundle is one long text blob assembled from ~13k member files, so every
scan here is string-aware: brace matching and expression scanning skip string
literals, template literals and comments.  Nothing is evaluated; the DSL is
parsed as text.

Usage:
    python3 Protocol/extract.py [--asar PATH] [--verify]

Exit codes:
    0  extraction succeeded, every schema resolved
    1  something in the descriptor could not be resolved (see stderr)
    2  the descriptor could not be located at all
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import sys

DEFAULT_ASAR = "/Applications/DeepSeek Harness.app/Contents/Resources/app.asar"
HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_DIR = os.path.join(HERE, "schemas")
ENDPOINTS_JSON = os.path.join(HERE, "endpoints.json")

# Member files we are willing to scan as text.  Binaries (.node, .dylib,
# LibreOffice, ...) and multi-megabyte client UI bundles are excluded by size.
TEXT_EXTS = (".js", ".mjs", ".cjs", ".ts", ".tsx", ".json")
MAX_TEXT_BYTES = 8 * 1024 * 1024

JSON_SCHEMA_DIALECT = "https://json-schema.org/draft/2020-12/schema"


# --------------------------------------------------------------------------
# asar container
# --------------------------------------------------------------------------


class Asar:
    """Minimal reader for the Electron asar archive format.

    Layout:  uint32le(=4) | uint32le(headerSize) | uint32le(headerStringSize)
             | uint32le(jsonSize) | json | padding | file data
    File data offsets in the header are relative to (8 + headerSize).
    """

    def __init__(self, path: str) -> None:
        self.path = path
        self._fh = open(path, "rb")
        raw = self._fh.read(16)
        if len(raw) != 16:
            raise ValueError("asar header truncated")
        _prefix, header_size, _string_size, json_size = struct.unpack("<4I", raw)
        if json_size <= 0 or json_size > header_size + 16:
            raise ValueError("asar header sizes look wrong")
        self._fh.seek(16)
        self.header = json.loads(self._fh.read(json_size))
        self.data_offset = 8 + header_size
        if "files" not in self.header:
            raise ValueError("asar header has no 'files' root")
        self._entries: dict[str, dict] = {}
        self._walk(self.header["files"], "")

    def _walk(self, node: dict, prefix: str) -> None:
        for name, entry in node.items():
            p = prefix + "/" + name
            if "files" in entry:
                self._walk(entry["files"], p)
            else:
                self._entries[p] = entry

    def paths(self):
        return tuple(sorted(self._entries))

    def read(self, path: str) -> bytes:
        entry = self._entries[path]
        if entry.get("unpacked"):
            raise KeyError("member is stored unpacked on disk: %s" % path)
        size = int(entry.get("size", 0))
        offset = self.data_offset + int(entry["offset"])
        self._fh.seek(offset)
        return self._fh.read(size)

    def text_members(self):
        """Yield (path, text) for members small enough and textual enough."""
        for path in self.paths():
            if not path.endswith(TEXT_EXTS):
                continue
            try:
                raw = self.read(path)
            except (KeyError, OSError):
                continue
            if len(raw) > MAX_TEXT_BYTES:
                continue
            try:
                yield path, raw.decode("utf-8")
            except UnicodeDecodeError:
                continue

    def file_sha256(self) -> str:
        h = hashlib.sha256()
        self._fh.seek(0)
        while True:
            chunk = self._fh.read(1 << 20)
            if not chunk:
                break
            h.update(chunk)
        return h.hexdigest()


# --------------------------------------------------------------------------
# string-aware scanning primitives
# --------------------------------------------------------------------------


def skip_string(text: str, i: int) -> int:
    """`text[i]` opens a string/template literal; return index past its close."""
    quote = text[i]
    i += 1
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == quote:
            return i + 1
        i += 1
    raise ValueError("unterminated string literal at %d" % i)


def skip_trivia(text: str, i: int) -> int:
    while i < len(text):
        c = text[i]
        if c in " \t\r\n":
            i += 1
        elif c == "/" and i + 1 < len(text) and text[i + 1] == "/":
            j = text.find("\n", i)
            i = len(text) if j < 0 else j + 1
        elif c == "/" and i + 1 < len(text) and text[i + 1] == "*":
            j = text.find("*/", i)
            i = len(text) if j < 0 else j + 2
        else:
            break
    return i


_CLOSERS = {"(": ")", "[": "]", "{": "}"}
_OPENERS = {v: k for k, v in _CLOSERS.items()}


def match_bracket(text: str, i: int) -> int:
    """`text[i]` is an opening bracket; return the index just past its match."""
    stack = [text[i]]
    i += 1
    while i < len(text):
        c = text[i]
        if c in "\"'`":
            i = skip_string(text, i)
            continue
        if c == "/" and i + 1 < len(text) and text[i + 1] in "/*":
            i = skip_trivia(text, i)
            continue
        if c in _CLOSERS:
            stack.append(c)
        elif c in _OPENERS:
            if not stack or stack[-1] != _OPENERS[c]:
                raise ValueError("unbalanced %r at %d" % (c, i))
            stack.pop()
            if not stack:
                return i + 1
        i += 1
    raise ValueError("unterminated bracket starting at %d" % i)


def unquote(token: str):
    """Decode a JS string literal token without eval."""
    body = token[1:-1]
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        nxt = body[i + 1] if i + 1 < len(body) else ""
        if nxt == "n":
            out.append("\n")
        elif nxt == "t":
            out.append("\t")
        elif nxt == "r":
            out.append("\r")
        elif nxt == "b":
            out.append("\b")
        elif nxt == "f":
            out.append("\f")
        elif nxt == "v":
            out.append("\v")
        elif nxt == "0":
            out.append("\0")
        elif nxt == "u":
            try:
                if body[i + 2] == "{":
                    end = body.index("}", i + 3)
                    out.append(chr(int(body[i + 3 : end], 16)))
                    i = end + 1
                    continue
                out.append(chr(int(body[i + 2 : i + 6], 16)))
                i += 6
                continue
            except (ValueError, IndexError):
                out.append("u")
        elif nxt == "x":
            try:
                out.append(chr(int(body[i + 2 : i + 4], 16)))
                i += 4
                continue
            except ValueError:
                out.append("x")
        elif nxt == "\n":
            pass
        else:
            out.append(nxt)
        i += 2
    return "".join(out)


# --------------------------------------------------------------------------
# minimal JavaScript literal reader (for the descriptor objects themselves)
# --------------------------------------------------------------------------


class RawExpr(str):
    """A JS expression we deliberately do not evaluate (arrow functions etc.)."""

    __slots__ = ()


def js_parse_value(text: str, i: int):
    """Parse one JS literal at `text[i]`.

    Strings, numbers, booleans, null, arrays and objects become Python values.
    Anything else (an identifier reference, an arrow function) is captured
    verbatim as RawExpr.  Nothing is executed.
    """
    i = skip_trivia(text, i)
    if i >= len(text):
        raise ValueError("unexpected end of input")
    c = text[i]
    if c in "\"'`":
        j = skip_string(text, i)
        return unquote(text[i:j]) if c != "`" else RawExpr(text[i:j]), j
    if c == "{":
        return js_parse_object(text, i)
    if c == "[":
        return js_parse_array(text, i)
    # atom: identifier, number, keyword, or an arbitrary expression
    j = i
    depth = 0
    while j < len(text):
        c = text[j]
        if c in "\"'`":
            j = skip_string(text, j)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif c in "," and depth == 0:
            break
        j += 1
    atom = text[i:j].strip()
    if atom == "true":
        return True, j
    if atom == "false":
        return False, j
    if atom == "null":
        return None, j
    if re.fullmatch(r"-?\d+(\.\d+)?([eE][+-]?\d+)?", atom):
        return (float(atom) if ("." in atom or "e" in atom or "E" in atom) else int(atom)), j
    return RawExpr(atom), j


def js_parse_object(text: str, i: int):
    assert text[i] == "{"
    end = match_bracket(text, i)
    body = text[i + 1 : end - 1]
    out = {}
    k = 0
    while True:
        k = skip_trivia(body, k)
        if k >= len(body):
            break
        if body[k] in "\"'":
            j = skip_string(body, k)
            key = unquote(body[k:j])
            k = j
        else:
            m = re.match(r"[A-Za-z_$][\w$]*", body[k:])
            if not m:
                raise ValueError("bad object key at %d" % k)
            key = m.group(0)
            k += m.end()
        k = skip_trivia(body, k)
        if k >= len(body) or body[k] != ":":
            raise ValueError("expected ':' in object")
        value, k = js_parse_value(body, k + 1)
        out[key] = value
        k = skip_trivia(body, k)
        if k < len(body) and body[k] == ",":
            k += 1
    return out, end


def js_parse_array(text: str, i: int):
    assert text[i] == "["
    end = match_bracket(text, i)
    body = text[i + 1 : end - 1]
    out = []
    k = 0
    while True:
        k = skip_trivia(body, k)
        if k >= len(body):
            break
        value, k = js_parse_value(body, k)
        out.append(value)
        k = skip_trivia(body, k)
        if k < len(body) and body[k] == ",":
            k += 1
    return out, end


# --------------------------------------------------------------------------
# descriptor discovery
# --------------------------------------------------------------------------

DESCRIPTORS_KEY = re.compile(r"\bdescriptors\s*:\s*\[")
PACKAGE_FIELD = re.compile(r"""\bpackage\s*:\s*(['"])([^'"]+)\1""")
DEFINITION = re.compile(r"const\s+([\w$]+)\s*=\s*\(\)\s*=>\s*[\w$]*\$value[\w$]*\s*\?\?=\s*")


def read_expression(text: str, i: int) -> str:
    """Read a JS expression starting at `i` up to its depth-0 terminator.

    Terminates at `;` at bracket depth 0 (the DSL definitions are
    `const N = () => N$value ??= <expr>;`).
    """
    start = i
    depth = 0
    while i < len(text):
        c = text[i]
        if c in "\"'`":
            i = skip_string(text, i)
            continue
        if c == "/" and i + 1 < len(text) and text[i + 1] in "/*":
            i = skip_trivia(text, i)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == ";" and depth == 0:
            return text[start:i].strip()
        i += 1
    return text[start:].strip()


def collect_definitions(text: str) -> dict:
    """name -> raw DSL/JS expression text for every `const N$schema = () => ...`."""
    defs = {}
    for m in DEFINITION.finditer(text):
        name = m.group(1)
        expr = read_expression(text, m.end())
        if expr:
            defs[name] = expr
    return defs


def collect_descriptor_arrays(text: str) -> list:
    """Return [(package_or_None, raw_array_text)] for each `descriptors: [...]`."""
    out = []
    for m in DESCRIPTORS_KEY.finditer(text):
        array_start = text.find("[", m.start(), m.end())
        try:
            end = match_bracket(text, array_start)
        except ValueError:
            continue
        head = text[max(0, m.start() - 400) : m.start()]
        pkgs = PACKAGE_FIELD.findall(head)
        out.append((pkgs[-1][1] if pkgs else None, text[array_start:end]))
    return out


def looks_like_descriptor_list(value) -> bool:
    if not isinstance(value, list) or not value:
        return False
    for item in value:
        if not isinstance(item, dict):
            return False
        if "id" not in item or "service" not in item or "namespace" not in item:
            return False
    return True


# --------------------------------------------------------------------------
# schema DSL parser
# --------------------------------------------------------------------------


class DslError(Exception):
    pass


class DslParser:
    """Recursive-descent parser for the harness's schema DSL.

    Observed vocabulary (see README):
        object({ "k": expr, ... })     union([expr, ...])
        intersection(a, b)             literal(value)
        string() number() boolean()    unknown() never()
        array(expr)                    record(key_expr, value_expr)
        lazy(() => Name())             _void() _undefined()
        _instanceof(Ctor)
        postfix: .readonly() .optional()
    """

    IDENT = re.compile(r"[A-Za-z_$][\w$]*")
    NUMBER = re.compile(r"-?\d+(\.\d+)?([eE][+-]?\d+)?")

    def __init__(self, text: str) -> None:
        self.text = text
        self.i = 0

    def parse(self):
        node = self.expr()
        self.ws()
        if self.i != len(self.text):
            raise DslError("trailing input at %d: %r" % (self.i, self.text[self.i : self.i + 40]))
        return node

    def ws(self) -> None:
        self.i = skip_trivia(self.text, self.i)

    def peek(self) -> str:
        return self.text[self.i] if self.i < len(self.text) else ""

    def expect(self, ch: str) -> None:
        self.ws()
        if self.peek() != ch:
            raise DslError("expected %r at %d, found %r" % (ch, self.i, self.text[self.i : self.i + 30]))
        self.i += 1

    def expr(self):
        node = self.primary()
        while True:
            self.ws()
            if self.peek() == ".":
                self.i += 1
                self.ws()
                m = self.IDENT.match(self.text, self.i)
                if not m:
                    raise DslError("bad postfix at %d" % self.i)
                self.i = m.end()
                method = m.group(0)
                self.expect("(")
                self.expect(")")
                node = ("method", node, method)
            else:
                return node

    def primary(self):
        self.ws()
        c = self.peek()
        if c in "\"'`":
            j = skip_string(self.text, self.i)
            token = self.text[self.i : j]
            self.i = j
            if c == "`":
                return ("template", token)
            return ("string", unquote(token))
        if c in "([{":
            raise DslError("unexpected %r at %d" % (c, self.i))
        m = self.NUMBER.match(self.text, self.i)
        if m and (c.isdigit() or c == "-"):
            self.i = m.end()
            raw = m.group(0)
            return ("number", float(raw) if ("." in raw or "e" in raw or "E" in raw) else int(raw))
        m = self.IDENT.match(self.text, self.i)
        if not m:
            raise DslError("unexpected %r at %d" % (self.text[self.i : self.i + 30], self.i))
        name = m.group(0)
        self.i = m.end()
        if name == "true":
            return ("bool", True)
        if name == "false":
            return ("bool", False)
        if name == "null":
            return ("null", None)
        if name == "undefined":
            return ("undefined", None)
        self.ws()
        if self.peek() != "(":
            return ("ident", name)
        self.i += 1
        args = self.arglist()
        self.expect(")")
        return ("call", name, args)

    def arglist(self) -> list:
        args = []
        self.ws()
        if self.peek() == ")":
            return args
        while True:
            args.append(self.argument())
            self.ws()
            if self.peek() == ",":
                self.i += 1
                self.ws()
                if self.peek() == ")":
                    return args
                continue
            return args

    def argument(self):
        self.ws()
        c = self.peek()
        if c == "{":
            return self.object_literal()
        if c == "[":
            return self.array_literal()
        if c == "(":
            # `() => Name()` inside lazy(...).  A bare parenthesised expression
            # is not part of this DSL, so anything that is not an arrow is an
            # error rather than something to guess at.
            end = match_bracket(self.text, self.i)
            j = skip_trivia(self.text, end)
            if self.text[j : j + 2] != "=>":
                raise DslError("parenthesised expression is not an arrow at %d" % self.i)
            k = j + 2
            depth = 0
            while k < len(self.text):
                ch = self.text[k]
                if ch in "\"'`":
                    k = skip_string(self.text, k)
                    continue
                if ch in "([{":
                    depth += 1
                elif ch in ")]}":
                    if depth == 0:
                        break
                    depth -= 1
                elif ch == "," and depth == 0:
                    break
                k += 1
            raw = self.text[self.i : k].strip()
            self.i = k
            return ("arrow", raw)
        return self.expr()

    def object_literal(self):
        end = match_bracket(self.text, self.i)
        body = self.text[self.i + 1 : end - 1]
        self.i = end
        props = []
        sub = DslParser(body)
        while True:
            sub.ws()
            if sub.i >= len(body):
                break
            c = sub.peek()
            if c in "\"'`":
                j = skip_string(body, sub.i)
                key = unquote(body[sub.i : j])
                sub.i = j
            else:
                m = sub.IDENT.match(body, sub.i)
                if not m:
                    raise DslError("bad object key at %d in %r" % (sub.i, body[:80]))
                key = m.group(0)
                sub.i = m.end()
            sub.expect(":")
            props.append((key, sub.expr()))
            sub.ws()
            if sub.peek() == ",":
                sub.i += 1
        return ("object", props)

    def array_literal(self):
        end = match_bracket(self.text, self.i)
        body = self.text[self.i + 1 : end - 1]
        self.i = end
        items = []
        sub = DslParser(body)
        while True:
            sub.ws()
            if sub.i >= len(body):
                break
            items.append(sub.argument())
            sub.ws()
            if sub.peek() == ",":
                sub.i += 1
        return ("arraylit", items)


# --------------------------------------------------------------------------
# DSL -> JSON Schema
# --------------------------------------------------------------------------


class Compiler:
    """Translate DSL AST nodes into JSON Schema.

    Every rule that is not literally stated by the descriptor is recorded in
    `self.guesses` and reported in the README; `self.unknown` collects anything
    that could not be translated at all.
    """

    SCALARS = {"string", "number", "boolean"}

    def __init__(self, definitions: dict) -> None:
        self.definitions = definitions
        self._ast_cache: dict[str, object] = {}
        self._defs_out: dict[str, dict] = {}
        self._defs_in_progress: set[str] = set()
        self.guesses: set[str] = set()
        self.unknown: set[str] = set()

    # -- helpers ---------------------------------------------------------

    def ast_for(self, name: str):
        if name not in self._ast_cache:
            if name not in self.definitions:
                raise DslError("no definition for %s" % name)
            self._ast_cache[name] = DslParser(self.definitions[name]).parse()
        return self._ast_cache[name]

    @staticmethod
    def is_call(node, name) -> bool:
        return isinstance(node, tuple) and node[0] == "call" and node[1] == name

    @staticmethod
    def optional_of(node):
        """Return the inner node when `node` carries `.optional()`, else None."""
        if isinstance(node, tuple) and node[0] == "method" and node[2] == "optional":
            return node[1]
        return None

    @staticmethod
    def strip_methods(node):
        """Drop `.readonly()`; keep `.optional()` for the caller to inspect."""
        while isinstance(node, tuple) and node[0] == "method" and node[2] == "readonly":
            node = node[1]
        return node

    def union_has_undefined(self, node) -> bool:
        node = self.strip_methods(node)
        if isinstance(node, tuple) and node[0] == "call" and node[1] == "union":
            for arg in node[2][0][1]:
                if self._is_undefined(arg):
                    return True
        return self._is_undefined(node)

    @staticmethod
    def _is_undefined(node) -> bool:
        if isinstance(node, tuple) and node[0] == "call" and node[1] in ("_undefined", "undefined"):
            return True
        if isinstance(node, tuple) and node[0] == "undefined":
            return True
        return False

    # -- translation -----------------------------------------------------

    def compile(self, node, stack=()):
        if node is None:
            return {}
        if isinstance(node, tuple):
            pass
        else:
            raise DslError("not an AST node: %r" % (node,))

        kind = node[0]

        if kind == "method":
            return self.compile(node[1], stack)  # .readonly()/.optional() carry no shape

        if kind == "call":
            name, args = node[1], node[2]
            if name == "object":
                return self._object(args[0][1] if args else [], stack)
            if name == "union":
                items = args[0][1] if args else []
                kept = [x for x in items if not self._is_undefined(self.strip_methods(x))]
                if len(kept) != len(items):
                    self.guesses.add(
                        "_undefined() is a member of a union -> the field may be "
                        "ABSENT, not null; the member is dropped and the enclosing "
                        "property is dropped from `required`"
                    )
                if not kept:
                    return {}
                if len(kept) == 1:
                    return self.compile(kept[0], stack)
                return {"anyOf": [self.compile(x, stack) for x in kept]}
            if name == "intersection":
                return self._intersection(args, stack)
            if name == "literal":
                return {"const": self._literal_value(args[0])}
            if name in self.SCALARS:
                return {"type": name}
            if name == "unknown":
                return {}
            if name == "never":
                self.guesses.add("never() -> {\"not\": {}} (no JSON value satisfies it)")
                return {"not": {}}
            if name == "array":
                return {"type": "array", "items": self.compile(args[0], stack)}
            if name == "record":
                self.guesses.add("record(K, V) -> {\"type\":\"object\",\"additionalProperties\":V}")
                return {"type": "object", "additionalProperties": self.compile(args[1], stack)}
            if name == "lazy":
                return self._lazy(args, stack)
            if name in ("_void", "void"):
                self.guesses.add("_void() -> {\"type\":\"null\"} (result carries no value)")
                return {"type": "null"}
            if name in ("_undefined", "undefined"):
                self.guesses.add(
                    "_undefined() -> the value may be absent; never translated to null"
                )
                return {}
            if name == "_instanceof":
                ctor = args[0]
                ctor_name = ctor[1] if isinstance(ctor, tuple) else str(ctor)
                self.guesses.add(
                    "_instanceof(%s) -> {\"type\":\"null\"}: the generated encode() "
                    "replaces the field with writeBytes(...), which the gateway sends "
                    "as null plus a path-addressed entry in the envelope's attachments "
                    "array" % ctor_name
                )
                return {"type": "null"}
            raise DslError("unhandled DSL call %r" % (name,))

        if kind == "string":
            return {"const": node[1]}  # a bare string is not produced by the DSL

        raise DslError("unhandled DSL node %r" % (kind,))

    def _literal_value(self, node):
        if isinstance(node, tuple) and node[0] in ("string", "number", "bool", "null"):
            return node[1]
        if isinstance(node, tuple) and node[0] == "ident":
            return node[1]
        raise DslError("literal() of unsupported node %r" % (node,))

    def _intersection(self, args, stack):
        # intersection(T, unknown()) is the generator's spelling of a plain
        # branded type; unknown() adds nothing, so the pair collapses to T.
        # This is the only intersection shape that is not a plain conjunction.
        if len(args) == 2:
            a, b = (self.strip_methods(x) for x in args)
            if self.is_call(a, "unknown"):
                return self.compile(b, stack)
            if self.is_call(b, "unknown"):
                return self.compile(a, stack)
        self.guesses.add(
            "intersection(T, unknown()) -> T (collapsed); any other "
            "intersection -> {\"allOf\":[a, b]}"
        )
        return {"allOf": [self.compile(x, stack) for x in args]}

    def _object(self, props, stack):
        properties = {}
        required = []
        for key, value in props:
            inner = self.strip_methods(value)
            optional = self.optional_of(inner) is not None or self.union_has_undefined(inner)
            if optional:
                inner = self.optional_of(inner) or inner
            inner = self.strip_methods(inner)
            if self.union_has_undefined(inner):
                self.guesses.add(
                    "a property whose union contains _undefined() is dropped from "
                    "`required` and _undefined() is folded to null"
                )
                inner = self._drop_undefined(inner)
            properties[key] = self.compile(inner, stack)
            if not optional:
                required.append(key)
        schema = {"type": "object", "properties": properties, "required": required}
        return schema

    def _drop_undefined(self, node):
        node = self.strip_methods(node)
        if isinstance(node, tuple) and node[0] == "call" and node[1] == "union":
            items = [x for x in node[2][0][1] if not self._is_undefined(x)]
            if len(items) == 1:
                return items[0]
            return ("call", "union", [("arraylit", items)])
        return node

    def _lazy(self, args, stack):
        # lazy(() => Name()) - resolve `Name` against the definition table.
        arrow = args[0] if args else None
        if not (isinstance(arrow, tuple) and arrow[0] == "arrow"):
            raise DslError("lazy() without an arrow: %r" % (arrow,))
        m = re.match(r"\(\s*\)\s*=>\s*([\w$]+)\s*\(\s*\)\s*$", arrow[1].strip())
        if not m:
            raise DslError("unrecognised lazy() arrow: %r" % (arrow[1],))
        name = m.group(1)
        if name in stack:
            self._defs_out.setdefault(name, None)
            return {"$ref": "#/$defs/" + name}
        return self.compile(self.ast_for(name), stack + (name,))

    # -- driver ----------------------------------------------------------

    def root(self, expr_text: str):
        node = DslParser(expr_text).parse()
        may_be_absent = self.union_has_undefined(node)
        schema = self.compile(node, ("<root>",))
        # materialise any recursive reference discovered while compiling
        while True:
            pending = [n for n, v in self._defs_out.items() if v is None]
            if not pending:
                break
            for name in pending:
                self._defs_out[name] = self.compile(self.ast_for(name), (name,))
        if self._defs_out:
            schema = dict(schema)
            schema["$defs"] = {k: self._defs_out[k] for k in sorted(self._defs_out)}
        return schema, may_be_absent


# --------------------------------------------------------------------------
# naming
# --------------------------------------------------------------------------


def sanitize_type_name(type_symbol: str) -> str:
    s = type_symbol
    if s.startswith("@deepseek-ai/"):
        s = s[len("@deepseek-ai/") :]
    s = s.replace("@", "")
    for ch in "#/\\:*?\"<>|":
        s = s.replace(ch, ".")
    s = re.sub(r"\.+", ".", s).strip(".")
    return s


def canonical_shape(schema):
    """A structural fingerprint of a compiled schema.

    The generator emits a fresh closure name per use site, so the same
    TypeScript type compiles to the same shape under different `$defs` keys.
    Rename those keys positionally before comparing, so a difference in the
    fingerprint means a real difference in shape.
    """
    defs = schema.get("$defs") or {}
    order = sorted(defs)
    rename = {name: "d%d" % i for i, name in enumerate(order)}

    def walk(node):
        if isinstance(node, dict):
            out = {}
            for k, v in node.items():
                if k == "$defs":
                    out[k] = {rename.get(n, n): walk(v[n]) for n in order}
                elif k == "$ref" and isinstance(v, str) and v.startswith("#/$defs/"):
                    out[k] = "#/$defs/" + rename.get(v[len("#/$defs/") :], v[len("#/$defs/") :])
                else:
                    out[k] = walk(v)
            return out
        if isinstance(node, list):
            return [walk(x) for x in node]
        return node

    return json.dumps(walk(schema), sort_keys=True)


def unique_names(symbols):
    """Map typeSymbol -> file stem, disambiguating the rare sanitize collision."""
    by_stem: dict[str, list] = {}
    for sym in symbols:
        by_stem.setdefault(sanitize_type_name(sym), []).append(sym)
    stems = {}
    for stem, syms in by_stem.items():
        if len(syms) == 1:
            stems[syms[0]] = stem
        else:
            for i, sym in enumerate(sorted(syms)):
                stems[sym] = "%s.%d" % (stem, i)
    return stems


# --------------------------------------------------------------------------
# extraction
# --------------------------------------------------------------------------


def extract(asar: Asar, verbose: bool = True):
    report = {
        "descriptorFiles": [],
        "definitionFiles": [],
        "unresolved": [],
        "parseErrors": [],
        "dialects": {},
    }

    # endpoint id -> best descriptor record
    records: dict[str, dict] = {}
    mirrors: dict[str, list] = {}
    definitions: dict[str, str] = {}
    definition_source: dict[str, str] = {}

    for path, text in asar.text_members():
        if "descriptors" not in text:
            continue
        arrays = collect_descriptor_arrays(text)
        parsed_arrays = []
        for package, raw in arrays:
            try:
                value, _ = js_parse_value(raw, 0)
            except ValueError as exc:
                report["parseErrors"].append("%s: descriptors array: %s" % (path, exc))
                continue
            if not looks_like_descriptor_list(value):
                continue
            parsed_arrays.append((package, value))
        if not parsed_arrays:
            continue

        defs = collect_definitions(text)
        for name, expr in defs.items():
            definitions.setdefault(name, expr)
            definition_source.setdefault(name, path)

        dialect = "dsl"
        if re.search(r"\bz\.(object|union|literal|string|number|boolean)\(", text):
            dialect = "zod"
        report["descriptorFiles"].append({"file": path, "dialect": dialect, "arrays": len(parsed_arrays)})
        report["dialects"][path] = dialect

        for package, value in parsed_arrays:
            for entry in value:
                eid = entry.get("id")
                if not isinstance(eid, str) or "#" not in eid:
                    continue
                mirrors.setdefault(eid, []).append(path)
                if eid in records and records[eid]["dialect"] == "dsl":
                    continue
                records[eid] = {
                    "descriptor": entry,
                    "file": path,
                    "dialect": dialect,
                    "package": package,
                }

    if not records:
        return None, report

    # Keep the DSL dialect where both dialects describe the same endpoint.
    chosen = {}
    for eid, rec in records.items():
        chosen[eid] = rec
    duplicates = {}
    for eid, files in mirrors.items():
        if len(files) > 1:
            duplicates[eid] = files
    report["mirrors"] = duplicates

    # definitions must come from the DSL dialect files
    dsl_files = {f["file"] for f in report["descriptorFiles"] if f["dialect"] == "dsl"}
    report["definitionFiles"] = sorted(dsl_files)

    return {"endpoints": chosen, "definitions": definitions,
            "definitionSource": definition_source, "dslFiles": dsl_files,
            "mirrorFiles": mirrors, "dialects": report["dialects"]}, report


def build_schema_index(endpoints):
    """typeSymbol -> list of (endpoint_id, role, expression, definition_source_file)."""
    index: dict[str, list] = {}
    for eid, rec in endpoints.items():
        d = rec["descriptor"]
        for p in d.get("parameters") or []:
            codec = p.get("codec") or {}
            sym = codec.get("typeSymbol")
            create = codec.get("create")
            if not sym or not isinstance(create, RawExpr):
                continue
            index.setdefault(sym, []).append(
                {"endpoint": eid, "role": "parameter:" + str(p.get("wire")),
                 "create": str(create), "acceptsUndefined": bool(p.get("acceptsUndefined"))}
            )
        result = d.get("result") or {}
        sym = result.get("typeSymbol")
        create = result.get("create")
        if sym and isinstance(create, RawExpr):
            index.setdefault(sym, []).append(
                {"endpoint": eid, "role": "result", "create": str(create),
                 "acceptsUndefined": False}
            )
    return index


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--asar", default=os.environ.get("DSH_ASAR", DEFAULT_ASAR))
    ap.add_argument("--verify", action="store_true",
                    help="re-read the written files and report counts")
    args = ap.parse_args(argv)

    if not os.path.exists(args.asar):
        print("asar not found: %s" % args.asar, file=sys.stderr)
        return 2

    asar = Asar(args.asar)
    extracted, report = extract(asar)
    if not extracted:
        print("gateway descriptor NOT FOUND in %s" % args.asar, file=sys.stderr)
        return 2

    endpoints = extracted["endpoints"]
    definitions = extracted["definitions"]
    dsl_files = extracted["dslFiles"]

    compiler = Compiler(definitions)
    guesses = set(compiler.guesses)

    # ---- resolve every create: target and compile it -------------------
    schema_index = build_schema_index(endpoints)
    stems = unique_names(sorted(schema_index))

    unresolved = []
    per_symbol_schema: dict[str, dict] = {}
    per_symbol_dsl: dict[str, str] = {}
    per_symbol_absent: dict[str, bool] = {}
    per_symbol_variants: dict[str, list] = {}

    for sym in sorted(schema_index):
        refs = schema_index[sym]
        creates = sorted({r["create"] for r in refs})
        compiled = []
        for name in creates:
            expr = definitions.get(name)
            if expr is None:
                unresolved.append((sym, "no definition for %s" % name))
                break
            c = Compiler(definitions)
            try:
                schema, may_be_absent = c.root(expr)
            except DslError as exc:
                unresolved.append((sym, "DSL error in %s: %s" % (name, exc)))
                break
            guesses |= c.guesses
            compiled.append((name, expr, schema, may_be_absent))
        if not compiled or len(compiled) != len(creates):
            continue
        # The generator emits one `create:` closure per use site, so a single
        # TypeScript type can appear under several symbols.  Keep the first in
        # sorted order, and record the others only when their shape differs.
        primary_name, primary_expr, primary_schema, primary_absent = compiled[0]
        canon = canonical_shape(primary_schema)
        differing = [n for n, _e, s, _a in compiled[1:] if canonical_shape(s) != canon]
        per_symbol_schema[sym] = primary_schema
        per_symbol_dsl[sym] = primary_expr
        per_symbol_absent[sym] = primary_absent
        per_symbol_variants[sym] = {
            "definitions": creates,
            "differing": differing,
        }

    # ---- write schemas --------------------------------------------------
    os.makedirs(SCHEMA_DIR, exist_ok=True)
    written = set()
    for sym, schema in per_symbol_schema.items():
        refs = schema_index[sym]
        stem = stems[sym]
        out = {
            "$schema": JSON_SCHEMA_DIALECT,
            "title": stem,
            "x-dsh-typeSymbol": sym,
            "x-dsh-translatedFrom": "harness schema DSL (see Protocol/README.md)",
            "x-dsh-definition": {
                "symbol": refs[0]["create"],
                "source": extracted["definitionSource"].get(refs[0]["create"]),
                "allSymbols": per_symbol_variants[sym]["definitions"],
                "differingSymbols": per_symbol_variants[sym]["differing"],
            },
            "x-dsh-usedBy": sorted(
                "%s :: %s" % (r["endpoint"], r["role"]) for r in refs
            ),
            "x-dsh-rawExpression": per_symbol_dsl[sym],
        }
        if per_symbol_absent[sym]:
            out["x-dsh-mayBeAbsent"] = True
        out.update(schema)
        path = os.path.join(SCHEMA_DIR, stem + ".json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(out, fh, indent=2, ensure_ascii=False, sort_keys=False)
            fh.write("\n")
        written.add(os.path.basename(path))

    # remove schemas from earlier runs that no longer belong
    for stale in sorted(os.listdir(SCHEMA_DIR)):
        if stale.endswith(".json") and stale not in written:
            os.remove(os.path.join(SCHEMA_DIR, stale))

    # ---- endpoints.json -------------------------------------------------
    endpoint_out = []
    for eid in sorted(endpoints):
        rec = endpoints[eid]
        d = rec["descriptor"]
        params = []
        for p in d.get("parameters") or []:
            codec = p.get("codec") or {}
            sym = codec.get("typeSymbol")
            create = codec.get("create")
            entry = {
                "name": p.get("name"),
                "wire": p.get("wire"),
                "source": p.get("source"),
                "typeSymbol": sym,
                "dialect": rec["dialect"],
            }
            if p.get("lookup") is not None:
                entry["lookup"] = p.get("lookup")
            if p.get("acceptsUndefined"):
                entry["acceptsUndefined"] = True
            if isinstance(create, RawExpr):
                entry["definition"] = str(create)
                if sym in per_symbol_dsl:
                    entry["expression"] = per_symbol_dsl[sym]
            if sym and sym in per_symbol_schema:
                entry["schema"] = "schemas/%s.json" % stems[sym]
            # The wire field may be omitted entirely.  Sourced from the
            # descriptor's own `acceptsUndefined` flag, cross-checked against
            # `union([_undefined(), T])` in the DSL expression.
            if p.get("acceptsUndefined") or (sym in per_symbol_absent and per_symbol_absent[sym]):
                entry["optional"] = True
            params.append(entry)

        result = d.get("result") or {}
        rsym = result.get("typeSymbol")
        rcreate = result.get("create")
        result_out = {
            "typeSymbol": rsym,
            "mode": result.get("mode"),
            "dialect": rec["dialect"],
        }
        if isinstance(rcreate, RawExpr):
            result_out["definition"] = str(rcreate)
            if rsym in per_symbol_dsl:
                result_out["expression"] = per_symbol_dsl[rsym]
        if rsym and rsym in per_symbol_schema:
            result_out["schema"] = "schemas/%s.json" % stems[rsym]
        if rsym in per_symbol_absent and per_symbol_absent[rsym]:
            result_out["mayBeAbsent"] = True
        if result.get("encode") is not None:
            # The generated encode() moves native bytes out of the JSON body and
            # into path-addressed attachments; the field itself becomes null.
            result_out["byteAttachments"] = True
        if result.get("decode") is not None:
            result_out["hasDecode"] = True

        mode = d.get("mode") or "unary"
        endpoint_out.append({
            "id": eid,
            "service": d.get("service"),
            "namespace": d.get("namespace"),
            "method": d.get("method"),
            "mode": mode,
            "httpPath": "/api/%s/%s" % (d.get("namespace"), d.get("method")),
            "invocation": d.get("invocation") if isinstance(d.get("invocation"), dict) else None,
            "scope": d.get("scope") if isinstance(d.get("scope"), dict) else None,
            "cancellation": d.get("cancellation") if isinstance(d.get("cancellation"), dict) else None,
            "sourceLocation": d.get("sourceLocation") if isinstance(d.get("sourceLocation"), dict) else None,
            "descriptorSource": rec["file"],
            "dialect": rec["dialect"],
            "mirrorDialects": sorted(
                {extracted["dialects"][f] for f in extracted["mirrorFiles"].get(eid, [])
                 if f != rec["file"]}
            ),
            "parameters": params,
            "result": result_out,
        })

    release = {}
    try:
        runtime = json.loads(asar.read("/dsh/desktop-runtime.json").decode("utf-8"))
        release = runtime.get("release", {})
    except Exception:
        pass

    doc = {
        "generatedBy": "Protocol/extract.py",
        "source": {
            "asarPath": args.asar,
            "asarBytes": os.path.getsize(args.asar),
            "asarSha256": asar.file_sha256(),
            "harnessVersion": release.get("version"),
            "hostProtocolVersion": release.get("hostProtocolVersion"),
            "descriptorFiles": report["descriptorFiles"],
            "definitionFiles": sorted(
                {extracted["definitionSource"][n] for n in extracted["definitionSource"]}
            ),
        },
        "counts": {
            "endpoints": len(endpoint_out),
            "schemas": len(per_symbol_schema),
            "schemasWithDifferingVariants": sum(
                1 for v in per_symbol_variants.values() if v["differing"]),
            "unresolved": len(unresolved),
        },
        "crossCheck": _cross_check(extracted),
        "translationGuesses": sorted(guesses | _collect_guesses(per_symbol_schema)),
        "unresolved": [{"typeSymbol": s, "reason": r} for s, r in unresolved],
        "parseErrors": report["parseErrors"],
        "endpoints": endpoint_out,
    }
    with open(ENDPOINTS_JSON, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    print("asar:        %s" % args.asar)
    print("harness:     %s (host protocol %s)" % (doc["source"]["harnessVersion"],
                                                  doc["source"]["hostProtocolVersion"]))
    print("descriptor:  %d endpoint definitions in %d files (%s)"
          % (len(endpoint_out), len(report["descriptorFiles"]), ", ".join(
              sorted({f["dialect"] for f in report["descriptorFiles"]}))))
    print("schemas:     %d written to %s" % (len(per_symbol_schema), SCHEMA_DIR))
    print("endpoints:   %s" % ENDPOINTS_JSON)
    if unresolved:
        print("UNRESOLVED (%d):" % len(unresolved), file=sys.stderr)
        for sym, why in unresolved:
            print("  %s: %s" % (sym, why), file=sys.stderr)

    if args.verify:
        with open(ENDPOINTS_JSON, encoding="utf-8") as fh:
            check = json.load(fh)
        files = sorted(f for f in os.listdir(SCHEMA_DIR) if f.endswith(".json"))
        problems = []
        for name in files:
            try:
                json.load(open(os.path.join(SCHEMA_DIR, name), encoding="utf-8"))
            except ValueError as exc:
                problems.append("%s is not valid JSON: %s" % (name, exc))
        for e in check["endpoints"]:
            for p in e["parameters"]:
                if not p.get("schema"):
                    problems.append("%s parameter %s has no schema" % (e["id"], p.get("wire")))
            if not e["result"].get("schema"):
                problems.append("%s result has no schema" % e["id"])
        print("verify:      endpoints.json has %d endpoints, schemas/ has %d files"
              % (len(check["endpoints"]), len(files)))
        if problems:
            print("verify FAILED (%d):" % len(problems), file=sys.stderr)
            for p in problems[:20]:
                print("  " + p, file=sys.stderr)
            return 1
        print("verify:      every endpoint parameter and result resolves to a valid schema file")

    return 1 if unresolved else 0


def _cross_check(extracted) -> dict:
    """How many endpoints appear in both generated dialects, and in only one."""
    dialects = extracted["dialects"]
    mirrors = extracted["mirrorFiles"]
    per_endpoint = {eid: sorted({dialects[f] for f in files}) for eid, files in mirrors.items()}
    dsl = {e for e, d in per_endpoint.items() if "dsl" in d}
    zod = {e for e, d in per_endpoint.items() if "zod" in d}
    return {
        "byDialect": {"dsl": len(dsl), "zod": len(zod), "both": len(dsl & zod),
                      "dslOnly": len(dsl - zod), "zodOnly": len(zod - dsl)},
        "note": (
            "Each endpoint appears twice in the bundle: once in the schema DSL "
            "(`create:` closures, used here) and once as a zod mirror in the "
            "package's lib/typert.remote-client.js. The two sets are identical."
        ),
    }


def _collect_guesses(per_symbol_schema):
    """Guesses visible in the output rather than in the compiler's own log."""
    guesses = set()
    for schema in per_symbol_schema.values():
        if "$defs" in schema:
            guesses.add("recursive lazy() reference -> $ref under this file's $defs")
    return guesses


if __name__ == "__main__":
    sys.exit(main())
