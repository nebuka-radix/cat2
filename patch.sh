#!/bin/zsh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

TARGET="${1:-/Users/knebuka/bin/cat2}"

python3 - "$TARGET" <<'PY'
import ast
import sys
from pathlib import Path

target = Path(sys.argv[1]).expanduser().resolve()
if not target.is_file():
    raise SystemExit(f"Target file not found: {target}")

source = target.read_text(encoding="utf-8")
tree = ast.parse(source, filename=str(target))

messages = [
    "cat2 - Gemini Export",
    "Use Up/Down and Enter to select. Press Ctrl+C to cancel.",
    "Profile limits are local presets, not official Gemini limits.",
]

def is_print(node, message=None):
    if not (
        isinstance(node, ast.Expr)
        and isinstance(node.value, ast.Call)
        and isinstance(node.value.func, ast.Name)
        and node.value.func.id == "print"
        and not node.value.keywords
    ):
        return False

    args = node.value.args
    if message is None:
        return not args
    return (
        len(args) == 1
        and isinstance(args[0], ast.Constant)
        and args[0].value == message
    )

wizards = [
    node for node in tree.body
    if isinstance(node, ast.FunctionDef)
    and node.name == "run_console_wizard"
]
if len(wizards) != 1:
    raise SystemExit("Could not uniquely locate run_console_wizard().")

matches = []
for parent in ast.walk(wizards[0]):
    body = getattr(parent, "body", None)
    if not isinstance(body, list):
        continue

    for index in range(len(body) - len(messages) + 1):
        if all(
            is_print(body[index + offset], message)
            for offset, message in enumerate(messages)
        ):
            start = index
            end = index + len(messages)

            if start > 0 and is_print(body[start - 1]):
                start -= 1
            if end < len(body) and is_print(body[end]):
                end += 1

            matches.append((
                body[start].lineno - 1,
                body[end - 1].end_lineno,
            ))

if len(matches) != 1:
    raise SystemExit(
        "Could not uniquely locate the startup banner. "
        "No changes were saved."
    )

lines = source.splitlines(keepends=True)
start, end = matches[0]
del lines[start:end]
updated = "".join(lines)

ast.parse(updated, filename=str(target))
target.write_text(updated, encoding="utf-8")

print(f"Updated: {target}")
print("Removed the startup banner.")
print("Python syntax validation passed.")
PY

git add .
git commit -m '起動時の案内メッセージを削除'