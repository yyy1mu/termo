#!/usr/bin/env python3
"""Static checks for Termo's in-app macOS language switch."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "Mac"
CATALOG = SOURCE_ROOT / "Localizable.xcstrings"


def swift_sources() -> list[Path]:
    return sorted(SOURCE_ROOT.rglob("*.swift"))


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def is_comment_line(text: str, offset: int) -> bool:
    start = text.rfind("\n", 0, offset) + 1
    return text[start:offset].lstrip().startswith("//")


def localized_calls(text: str):
    needle = "String(localized:"
    position = 0
    while (start := text.find(needle, position)) >= 0:
        position = start + len(needle)
        if is_comment_line(text, start):
            continue
        depth = 0
        quoted = False
        escaped = False
        end = None
        for index in range(start, len(text)):
            char = text[index]
            if quoted:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    quoted = False
            else:
                if char == '"':
                    quoted = True
                elif char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        end = index + 1
                        break
        yield start, text[start:end] if end else text[start : start + 400]
        position = end or position


def main() -> int:
    failures: list[str] = []
    catalog = json.loads(CATALOG.read_text())["strings"]
    chinese = re.compile(r"[\u3400-\u9fff]")
    for key, entry in catalog.items():
        for language in ("en", "zh-Hans"):
            unit = entry.get("localizations", {}).get(language, {}).get("stringUnit")
            allowed_states = {"translated"} if language == "en" else {"translated", "new"}
            if not unit or unit.get("state") not in allowed_states:
                failures.append(f"catalog: missing translated {language}: {key!r}")
        english = entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", "")
        if chinese.search(key) and chinese.search(english):
            failures.append(f"catalog: English translation still contains Chinese: {key!r}")

    raw_state = re.compile(
        r'(?:errorText|statusText|keyOpError|credentialError)\s*=\s*"([^"\n]*[\u3400-\u9fff][^"\n]*)"'
        r'|ClientError\(message:\s*"([^"\n]*[\u3400-\u9fff][^"\n]*)"'
    )
    static_ui_patterns = [
        r'String\(localized:\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
        r'keySheetString\("([^"\\]*(?:\\.[^"\\]*)*)"\)',
        r'LocalizedStringKey\("([^"\\]*(?:\\.[^"\\]*)*)"\)',
        r'\b(?:Text|Button|Label|Toggle|Picker|Section|SecureField|TextField)\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
        r'\.(?:alert|confirmationDialog|help|accessibilityLabel)\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
        r'\b(?:PrimaryButton|SecondaryButton)\(\s*title:\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
        r'ThemedTextField\(\s*placeholder:\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
    ]
    static_references = 0

    for path in swift_sources():
        text = path.read_text()
        relative = path.relative_to(ROOT)
        for offset, call in localized_calls(text):
            if "bundle: AppSettings.localizationBundle" not in call or "locale:" not in call:
                failures.append(
                    f"{relative}:{line_number(text, offset)}: String(localized:) bypasses app bundle/locale"
                )

        for match in re.finditer(r"(?:Text|Label)\(verbatim:[^\n]*", text):
            # A localized empty-state fallback may intentionally share a verbatim Text with
            # a user-supplied value so the latter is never treated as a catalog key.
            explicitly_localized = (
                "String(localized:" in match.group(0)
                or "keySheetString(" in match.group(0)
            )
            if chinese.search(match.group(0)) and not explicitly_localized:
                failures.append(
                    f"{relative}:{line_number(text, match.start())}: Chinese UI text marked verbatim"
                )

        for match in raw_state.finditer(text):
            failures.append(
                f"{relative}:{line_number(text, match.start())}: dynamic UI error/status is not localized"
            )

        for pattern in static_ui_patterns:
            for match in re.finditer(pattern, text):
                raw_key = match.group(1)
                if "\\(" in raw_key:
                    continue  # Xcode converts typed interpolation to catalog placeholders.
                key = raw_key.replace(r"\n", "\n").replace(r'\"', '"').replace(r"\\", "\\")
                static_references += 1
                if key not in catalog:
                    failures.append(
                        f"{relative}:{line_number(text, match.start())}: static UI key missing from catalog: {key!r}"
                    )

        # Helpers that return an already-localized String bypass Xcode's automatic catalog
        # extraction. Require every literal key to exist and Chinese source keys to have a
        # genuinely non-Chinese English value, which protects nested key sheets in particular.
        for match in re.finditer(r'keySheetString\("([^"\\]*(?:\\.[^"\\]*)*)"\)', text):
            key = bytes(match.group(1), "utf-8").decode("unicode_escape") if "\\" in match.group(1) else match.group(1)
            entry = catalog.get(key)
            if entry is None:
                failures.append(
                    f"{relative}:{line_number(text, match.start())}: keySheetString key missing from catalog: {key!r}"
                )
                continue
            english = entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", "")
            if chinese.search(key) and chinese.search(english):
                failures.append(
                    f"{relative}:{line_number(text, match.start())}: key sheet English value still contains Chinese: {key!r}"
                )

        # A localized value stored in a static constant is frozen in the language used on first access.
        for match in re.finditer(r"\bstatic\s+let\b", text):
            next_member = re.search(r"\n\s*(?:static\s+|private\s+static\s+|})", text[match.end() :])
            end = match.end() + (next_member.start() if next_member else 1200)
            if "String(localized:" in text[match.start() : end]:
                failures.append(
                    f"{relative}:{line_number(text, match.start())}: localized static let freezes the first language"
                )

    if failures:
        print("Localization audit failed:")
        print("\n".join(f"- {failure}" for failure in failures))
        return 1

    print(
        f"Localization audit passed: {len(catalog)} catalog entries and "
        f"{static_references} static UI references; English and Simplified Chinese complete."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
