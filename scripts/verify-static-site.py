#!/usr/bin/env python3
"""Dependency-free checks for the static portfolio and delivery bundle."""

from __future__ import annotations

import os
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ROOT / "public"

REQUIRED_FILES = (
    "public/index.html",
    "public/404.html",
    "public/assets/styles.css",
    "public/assets/script.js",
    "public/assets/favicon.svg",
    "public/robots.txt",
    "public/sitemap.xml",
    "Dockerfile",
    "nginx.conf",
    ".github/workflows/delivery.yml",
)

TEXT_SUFFIXES = {
    "",
    ".css",
    ".html",
    ".js",
    ".json",
    ".md",
    ".sh",
    ".svg",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}

SECRET_PATTERNS = (
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\btskey-[A-Za-z0-9-]{16,}\b"),
)

FORBIDDEN_FILE_NAMES = {
    ".DS_Store",
    ".env",
    "id_dsa",
    "id_ed25519",
    "id_ecdsa",
    "id_rsa",
}

REFERENCE_ATTRIBUTES = {
    "a": ("href",),
    "img": ("src", "srcset"),
    "link": ("href",),
    "script": ("src",),
    "source": ("src", "srcset"),
    "video": ("poster", "src"),
}


class PortfolioHTMLParser(HTMLParser):
    def __init__(self, source: Path) -> None:
        super().__init__(convert_charrefs=True)
        self.source = source
        self.errors: List[str] = []
        self.references: List[str] = []
        self.ids: Set[str] = set()
        self.aria_controls: List[str] = []
        self.h1_count = 0
        self.has_lang = False
        self.has_title = False
        self.has_viewport = False
        self._in_title = False
        self._in_inline_script = False
        self._title_text: List[str] = []

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, str | None]]) -> None:
        values = {name: value or "" for name, value in attrs}

        if tag == "html" and values.get("lang", "").strip():
            self.has_lang = True
        if tag == "title":
            self._in_title = True
        if tag == "meta" and values.get("name", "").lower() == "viewport":
            self.has_viewport = bool(values.get("content", "").strip())
        if tag == "h1":
            self.h1_count += 1

        element_id = values.get("id", "").strip()
        if element_id:
            if element_id in self.ids:
                self.errors.append(f"duplicate id #{element_id}")
            self.ids.add(element_id)

        aria_controls = values.get("aria-controls", "").strip()
        if aria_controls:
            self.aria_controls.extend(aria_controls.split())

        if "style" in values:
            self.errors.append(f"inline style is blocked by CSP on <{tag}>")
        for name in values:
            if name.lower().startswith("on"):
                self.errors.append(f"inline event handler {name} is not allowed")

        if tag == "img" and not values.get("alt", "").strip():
            self.errors.append("img element must have non-empty alt text")
        if tag == "a" and values.get("target") == "_blank":
            rel_values = set(values.get("rel", "").lower().split())
            if not {"noopener", "noreferrer"}.issubset(rel_values):
                self.errors.append("target=_blank link must use noopener noreferrer")

        if tag == "style":
            self.errors.append("inline style blocks are not allowed")
        if tag == "script" and not values.get("src", "").strip():
            self._in_inline_script = True

        for attribute in REFERENCE_ATTRIBUTES.get(tag, ()):  # local assets and links
            value = values.get(attribute, "").strip()
            if not value:
                continue
            if attribute == "srcset":
                for candidate in value.split(","):
                    reference = candidate.strip().split()[0]
                    if reference:
                        self.references.append(reference)
            else:
                self.references.append(value)

    def handle_startendtag(self, tag: str, attrs: List[Tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self._in_title = False
            self.has_title = bool("".join(self._title_text).strip())
        if tag == "script":
            self._in_inline_script = False

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self._title_text.append(data)
        if self._in_inline_script and data.strip():
            self.errors.append("inline script is blocked by CSP")

    def finalize(self) -> None:
        if not self.has_lang:
            self.errors.append("html lang is required")
        if not self.has_title:
            self.errors.append("non-empty title is required")
        if not self.has_viewport:
            self.errors.append("viewport meta is required")
        if self.h1_count != 1:
            self.errors.append(f"exactly one h1 is required, found {self.h1_count}")
        for controlled_id in self.aria_controls:
            if controlled_id not in self.ids:
                self.errors.append(f"aria-controls target #{controlled_id} does not exist")


def iter_files() -> Iterable[Path]:
    for candidate in sorted(ROOT.rglob("*")):
        relative_parts = candidate.relative_to(ROOT).parts
        if relative_parts and relative_parts[0] == ".git":
            continue
        if candidate.is_file() or candidate.is_symlink():
            yield candidate


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def has_exact_case(path: Path) -> bool:
    try:
        relative_path = path.relative_to(PUBLIC)
    except ValueError:
        return False

    cursor = PUBLIC
    for part in relative_path.parts:
        try:
            names = {entry.name for entry in cursor.iterdir()}
        except OSError:
            return False
        if part not in names:
            return False
        cursor = cursor / part
    return True


def resolve_reference(source: Path, reference: str) -> Tuple[Path | None, str | None]:
    if reference.startswith("#"):
        return source, unquote(reference[1:]) or None

    parsed = urlsplit(reference)
    scheme = parsed.scheme.lower()
    if scheme in {"mailto", "tel", "data"}:
        return None, None
    if scheme == "javascript":
        raise ValueError("javascript: references are not allowed")
    if scheme == "http":
        raise ValueError("external references must use https")
    if scheme or parsed.netloc:
        return None, None

    decoded_path = unquote(parsed.path)
    if decoded_path.startswith("/"):
        candidate = PUBLIC / decoded_path.lstrip("/")
    elif decoded_path:
        candidate = source.parent / decoded_path
    else:
        candidate = source

    normalized = Path(os.path.normpath(str(candidate)))
    if os.path.commonpath((str(PUBLIC), str(normalized))) != str(PUBLIC):
        raise ValueError("local reference escapes public/")

    if decoded_path.endswith("/") or normalized == PUBLIC or normalized.is_dir():
        normalized = normalized / "index.html"

    return normalized, unquote(parsed.fragment) or None


def parse_html_files(errors: List[str]) -> Dict[Path, PortfolioHTMLParser]:
    parsed_files: Dict[Path, PortfolioHTMLParser] = {}
    for html_path in sorted(PUBLIC.rglob("*.html")):
        parser = PortfolioHTMLParser(html_path)
        try:
            parser.feed(html_path.read_text(encoding="utf-8"))
            parser.close()
            parser.finalize()
        except (OSError, UnicodeError) as exc:
            errors.append(f"{relative(html_path)}: cannot parse UTF-8 HTML: {exc}")
            continue

        parsed_files[html_path] = parser
        for message in parser.errors:
            errors.append(f"{relative(html_path)}: {message}")

    return parsed_files


def verify_references(
    parsed_files: Dict[Path, PortfolioHTMLParser], errors: List[str]
) -> None:
    for source, parser in parsed_files.items():
        for reference in parser.references:
            try:
                target, fragment = resolve_reference(source, reference)
            except ValueError as exc:
                errors.append(f"{relative(source)}: {reference}: {exc}")
                continue

            if target is None:
                continue
            if not target.is_file():
                errors.append(f"{relative(source)}: missing local reference {reference}")
                continue
            if not has_exact_case(target):
                errors.append(f"{relative(source)}: filename case mismatch for {reference}")
                continue
            if fragment and target.suffix.lower() == ".html":
                target_parser = parsed_files.get(target)
                if target_parser is not None and fragment not in target_parser.ids:
                    errors.append(
                        f"{relative(source)}: missing anchor #{fragment} in {relative(target)}"
                    )


def verify_css_references(errors: List[str]) -> None:
    url_pattern = re.compile(r"url\(\s*(['\"]?)(.*?)\1\s*\)", re.IGNORECASE)
    for css_path in sorted(PUBLIC.rglob("*.css")):
        try:
            css = css_path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            errors.append(f"{relative(css_path)}: cannot parse UTF-8 CSS: {exc}")
            continue
        if re.search(r"@import\b", css, re.IGNORECASE):
            errors.append(f"{relative(css_path)}: @import is not allowed")
        for match in url_pattern.finditer(css):
            reference = match.group(2).strip()
            if not reference or reference.startswith("data:"):
                continue
            try:
                target, _ = resolve_reference(css_path, reference)
            except ValueError as exc:
                errors.append(f"{relative(css_path)}: {reference}: {exc}")
                continue
            if target is not None and not target.is_file():
                errors.append(f"{relative(css_path)}: missing local reference {reference}")


def verify_git_context(errors: List[str]) -> None:
    git_path = ROOT / ".git"
    if not git_path.exists() and not git_path.is_symlink():
        return

    if git_path.is_symlink() or not git_path.is_dir():
        errors.append(".git must be a real directory in a GitHub Actions checkout")
        return
    if os.environ.get("GITHUB_ACTIONS") != "true":
        errors.append(".git is only allowed in the exact GitHub Actions workspace")
        return

    workspace_value = os.environ.get("GITHUB_WORKSPACE", "")
    if not workspace_value:
        errors.append(
            "GITHUB_WORKSPACE must resolve to the delivery root when .git exists"
        )
        return

    try:
        workspace = Path(workspace_value).resolve(strict=True)
    except OSError:
        errors.append("GITHUB_WORKSPACE could not be resolved")
        return

    if not workspace.is_dir() or workspace != ROOT:
        errors.append(
            "GITHUB_WORKSPACE must resolve to the delivery root when .git exists"
        )


def verify_files(errors: List[str]) -> None:
    for required in REQUIRED_FILES:
        candidate = ROOT / required
        if not candidate.is_file() or candidate.is_symlink():
            errors.append(f"required regular file is missing: {required}")

    verify_git_context(errors)

    total_size = 0
    for candidate in iter_files():
        path_text = relative(candidate)
        if candidate.is_symlink():
            errors.append(f"symlink is not allowed: {path_text}")
            continue

        total_size += candidate.stat().st_size
        if candidate.stat().st_size > 25 * 1024 * 1024:
            errors.append(f"individual file exceeds 25 MiB: {path_text}")

        name = candidate.name
        if name in FORBIDDEN_FILE_NAMES or name.endswith((".key", ".pem", ".p12", ".pfx")):
            errors.append(f"credential-like file is not allowed: {path_text}")
        if name == ".env" or name.startswith(".env."):
            errors.append(f"environment file is not allowed: {path_text}")

        if candidate.suffix.lower() not in TEXT_SUFFIXES and name not in {
            ".dockerignore",
            ".gitignore",
            "Dockerfile",
        }:
            continue
        try:
            text = candidate.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            continue
        for pattern in SECRET_PATTERNS:
            if pattern.search(text):
                errors.append(f"secret-like value found in {path_text}")

    if total_size > 100 * 1024 * 1024:
        errors.append("delivery source exceeds 100 MiB")


def main() -> int:
    errors: List[str] = []
    verify_files(errors)
    parsed_files = parse_html_files(errors)
    verify_references(parsed_files, errors)
    verify_css_references(errors)

    if errors:
        print("Static site verification failed:", file=sys.stderr)
        for message in errors:
            print(f"- {message}", file=sys.stderr)
        return 1

    print(
        "Static site verification passed "
        f"({len(parsed_files)} HTML files, {sum(1 for _ in iter_files())} source files)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
