mkdir -p gemini-scripts

cat > gemini-scripts/005-use-directory-argument.sh <<'SH'
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

def find_function(name):
    nodes = [
        node for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == name
    ]
    if len(nodes) != 1:
        raise SystemExit(f"Could not uniquely locate {name}().")
    return nodes[0]

wizard = find_function("run_console_wizard")
main = find_function("main")

# ディレクトリ入力の代入文を特定する。
prompts = [
    node for node in ast.walk(wizard)
    if isinstance(node, ast.Assign)
    and any(
        isinstance(child, ast.Call)
        and isinstance(child.func, ast.Attribute)
        and isinstance(child.func.value, ast.Name)
        and child.func.value.id == "inquirer"
        and child.func.attr == "filepath"
        for child in ast.walk(node.value)
    )
]
if len(prompts) != 1:
    raise SystemExit(
        "Could not uniquely locate the directory prompt. "
        "The update may already be applied."
    )

initializations = [
    node for node in wizard.body
    if isinstance(node, ast.Assign)
    and len(node.targets) == 1
    and isinstance(node.targets[0], ast.Name)
    and node.targets[0].id == "directory"
    and isinstance(node.value, ast.Name)
    and node.value.id == "initial_directory"
]
if len(initializations) != 1:
    raise SystemExit("Could not locate directory initialization.")

initialization = '''    directory_path = Path(initial_directory).expanduser().resolve()
    if not directory_path.is_dir():
        print(
            f"Error: directory not found: {directory_path}",
            file=sys.stderr,
        )
        sys.exit(1)
    directory = str(directory_path)
'''

new_main = '''def main():
    if len(sys.argv) != 2:
        print("Usage: cat2 <directory>", file=sys.stderr)
        sys.exit(1)

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print(
            "Error: interactive input and output terminals are required.",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        run_console_wizard(sys.argv[1])
    except (KeyboardInterrupt, EOFError):
        print("\\\\nCancelled.")
        sys.exit(130)
'''.replace('print("\\\\nCancelled.")', 'print("\\nCancelled.")')

edits = [
    (
        prompts[0].lineno - 1,
        prompts[0].end_lineno,
        "",
    ),
    (
        initializations[0].lineno - 1,
        initializations[0].end_lineno,
        initialization,
    ),
    (
        main.lineno - 1,
        main.end_lineno,
        new_main,
    ),
]

lines = source.splitlines(keepends=True)
for start, end, replacement in sorted(edits, reverse=True):
    lines[start:end] = [replacement] if replacement else []

updated = "".join(lines)
ast.parse(updated, filename=str(target))

target.write_text(updated, encoding="utf-8")
print(f"Updated: {target}")
print("Removed the target directory prompt.")
print("The directory argument is now required.")
print("Python syntax validation passed.")
PY

git add .
git commit -m '対象ディレクトリを引数指定に統一'
SH

chmod +x gemini-scripts/005-use-directory-argument.sh
./gemini-scripts/005-use-directory-argument.sh