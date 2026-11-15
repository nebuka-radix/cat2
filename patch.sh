mkdir -p gemini-scripts

cat > gemini-scripts/003-fix-textual-margin.sh <<'SH'
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
tree = ast.parse(source)

classes = [
    node for node in tree.body
    if isinstance(node, ast.ClassDef) and node.name == "Cat2App"
]
if len(classes) != 1:
    raise SystemExit("Could not uniquely locate Cat2App.")

css_nodes = [
    node for node in classes[0].body
    if isinstance(node, ast.Assign)
    and any(
        isinstance(name, ast.Name) and name.id == "CSS"
        for name in node.targets
    )
]
if len(css_nodes) != 1:
    raise SystemExit("Could not uniquely locate Cat2App.CSS.")

node = css_nodes[0]
css = ast.literal_eval(node.value)

old_margin = "margin: 1 auto;"
old_screen = "Screen { layout: vertical; }"

if css.count(old_margin) != 1:
    raise SystemExit("Expected exactly one unsupported margin rule.")
if css.count(old_screen) != 1:
    raise SystemExit("Could not uniquely locate the Screen layout rule.")

css = css.replace(old_margin, "margin: 1 0;", 1)
css = css.replace(
    old_screen,
    """Screen {
        layout: vertical;
        align-horizontal: center;
    }""",
    1,
)

replacement = '    CSS = """\n' + css.strip("\n") + '\n    """\n'
lines = source.splitlines(keepends=True)
lines[node.lineno - 1:node.end_lineno] = [replacement]
updated = "".join(lines)

ast.parse(updated, filename=str(target))
target.write_text(updated, encoding="utf-8")

print(f"Updated: {target}")
print("Replaced unsupported margin and enabled horizontal alignment.")
print("Python syntax validation passed.")
PY

git add .
git commit -m 'Textualの余白指定と中央寄せを修正'
SH

chmod +x gemini-scripts/003-fix-textual-margin.sh
./gemini-scripts/003-fix-textual-margin.sh