mkdir -p gemini-scripts

cat > gemini-scripts/004-replace-textual-with-inquirerpy.sh <<'SH'
#!/bin/zsh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

TARGET="${1:-/Users/knebuka/bin/cat2}"

python3 - "$TARGET" <<'PY'
import ast
import re
import sys
from pathlib import Path

target = Path(sys.argv[1]).expanduser().resolve()
if not target.is_file():
    raise SystemExit(f"Target file not found: {target}")

source = target.read_text(encoding="utf-8")
if "def run_console_wizard(" in source:
    raise SystemExit("The InquirerPy update has already been applied.")

tree = ast.parse(source)

required = {
    "build_output_plan",
    "write_output_plan",
}
functions = {
    node.name
    for node in tree.body
    if isinstance(node, ast.FunctionDef)
}
if not required.issubset(functions):
    raise SystemExit(
        "Token splitting functions were not found. "
        "Apply the earlier token-splitting update first."
    )

if not any(
    isinstance(node, ast.ClassDef) and node.name == "Cat2App"
    for node in tree.body
):
    raise SystemExit("Cat2App was not found.")

def is_textual_import(node):
    if isinstance(node, ast.ImportFrom):
        return (
            node.module == "textual"
            or (node.module or "").startswith("textual.")
        )
    if isinstance(node, ast.Import):
        return any(
            item.name == "textual"
            or item.name.startswith("textual.")
            for item in node.names
        )
    return False

remove = []
dependency_blocks = []

for node in tree.body:
    if isinstance(node, ast.ClassDef) and node.name in {
        "Cat2App", "WizardPage"
    }:
        remove.append(node)
    elif isinstance(node, ast.FunctionDef) and node.name == "main":
        remove.append(node)
    elif is_textual_import(node):
        remove.append(node)
    elif isinstance(node, ast.Try) and any(
        is_textual_import(child)
        for child in ast.walk(node)
    ):
        dependency_blocks.append(node)

if len(dependency_blocks) != 1:
    raise SystemExit(
        "Could not uniquely identify the Textual dependency block."
    )

dependency_code = r'''
try:
    import tiktoken
    from InquirerPy import inquirer
    from InquirerPy.base.control import Choice
except ImportError as exc:
    raise SystemExit(
        "Required packages are missing.\n"
        "Run: python3 -m pip install -r cat2-requirements.txt\n"
        f"Details: {exc}"
    ) from exc
'''.strip() + "\n"

edits = [
    (node.lineno - 1, node.end_lineno, "")
    for node in remove
]
dependency_node = dependency_blocks[0]
edits.append((
    dependency_node.lineno - 1,
    dependency_node.end_lineno,
    dependency_code,
))

lines = source.splitlines(keepends=True)
for start, end, replacement in sorted(edits, reverse=True):
    lines[start:end] = [replacement] if replacement else []

updated = "".join(lines)

console_code = r'''
def select_console(message, choices, default):
    return inquirer.select(
        message=message,
        choices=[
            Choice(value=value, name=label)
            for label, value in choices
        ],
        default=default,
        instruction="(Up/Down to move, Enter to select)",
        raise_keyboard_interrupt=True,
    ).execute()


def print_output_summary(plan):
    print()
    print("Export preview")
    print("--------------")
    print(f"Source:           {plan.directory}")
    print(f"Profile:          {ENGINE_PROFILES[plan.engine][0]}")
    print(f"Tokenizer:        {plan.tokenizer}")
    print(f"Encoding:         {plan.encoding}")
    print(f"Input files:      {plan.file_count:,}")
    print(f"Token limit:      {plan.limit:,}")
    print(f"Output files:     {len(plan.documents):,}")
    print(f"Output directory: {Path.cwd()}")
    print()

    for number, (document, count) in enumerate(
        zip(plan.documents, plan.counts), 1
    ):
        size = len(document.encode("utf-8"))
        print(
            f"  output.{number:02d}.md"
            f"  {count:>9,} estimated tokens"
            f"  {size:>10,} bytes"
        )

    print()
    print("Token counts are tiktoken estimates, not Gemini token counts.")
    print("Export uses the source snapshot collected during this preview.")
    print("Run the preview again if the source files have changed.")
    print("Existing output.NN.md files in the output directory are replaced.")
    print()


def choose_token_limit(engine, current=None):
    default = ENGINE_PROFILES[engine][1]
    selected = default if current is None else current
    values = sorted({
        8000, 16000, 32000, 64000, 128000,
        default, selected,
    })

    choices = [
        (
            f"{value:,} tokens"
            + (" (profile default)" if value == default else ""),
            value,
        )
        for value in values
    ]
    choices.append(("Custom limit...", "custom"))

    result = select_console(
        "Select the token limit:",
        choices,
        selected,
    )
    if result != "custom":
        return result

    def valid_limit(value):
        return value.isascii() and value.isdigit() and int(value) >= 1024

    value = inquirer.text(
        message="Enter a token limit:",
        default=str(selected),
        validate=valid_limit,
        invalid_message="Enter an integer of at least 1,024.",
        raise_keyboard_interrupt=True,
    ).execute()
    return int(value)


def run_console_wizard(initial_directory):
    directory = initial_directory

    while True:
        print()
        print("cat2 - Gemini Export")
        print("Use Up/Down and Enter to select. Press Ctrl+C to cancel.")
        print("Profile limits are local presets, not official Gemini limits.")
        print()

        directory = inquirer.filepath(
            message="Target directory:",
            default=directory,
            only_directories=True,
            validate=lambda value: bool(value.strip()) and (
                Path(value).expanduser().is_dir()
            ),
            invalid_message="Enter an existing directory.",
            raise_keyboard_interrupt=True,
        ).execute()
        directory = str(Path(directory).expanduser().resolve())

        engine = select_console(
            "Select a Gemini profile:",
            [
                (label, key)
                for key, (label, _) in ENGINE_PROFILES.items()
            ],
            "flash",
        )

        tokenizer = select_console(
            "Select a token counting model:",
            TOKENIZERS,
            "model:gpt-4o",
        )

        limit = choose_token_limit(engine)

        while True:
            print()
            print("Collecting files, counting tokens and splitting...")
            print(
                "The first tokenizer load may download encoding data."
            )

            try:
                plan = build_output_plan(
                    directory, engine, tokenizer, limit
                )
            except Exception as exc:
                print(f"\nError: {exc}\n")
                action = select_console(
                    "What would you like to do?",
                    [
                        ("Retry", "retry"),
                        ("Change token limit", "limit"),
                        ("Start over", "restart"),
                        ("Quit", "quit"),
                    ],
                    "retry",
                )
                if action == "quit":
                    return
                if action == "restart":
                    break
                if action == "limit":
                    limit = choose_token_limit(engine, limit)
                continue

            print_output_summary(plan)

            action = select_console(
                "What would you like to do?",
                [
                    ("Export files", "export"),
                    ("Run preview again", "retry"),
                    ("Change token limit", "limit"),
                    ("Start over", "restart"),
                    ("Quit without exporting", "quit"),
                ],
                "export",
            )

            if action == "quit":
                return
            if action == "restart":
                break
            if action == "limit":
                limit = choose_token_limit(engine, limit)
                continue
            if action == "retry":
                continue

            print()
            print("Rechecking token counts and exporting files...")

            try:
                names = write_output_plan(plan)
            except Exception as exc:
                print(f"\nExport failed: {exc}")
                print(
                    "Some files may have been written. "
                    "Inspect the output directory before retrying."
                )
                continue

            print(f"\nExport complete: {len(names):,} files")
            print(f"Output directory: {Path.cwd()}")
            for name in names:
                print(f"  {name}")
            print()

            action = select_console(
                "What would you like to do next?",
                [
                    ("Quit", "quit"),
                    ("Export another project", "restart"),
                ],
                "quit",
            )
            if action == "quit":
                return
            break


def main():
    if len(sys.argv) > 2:
        print("Usage: cat2 [directory]", file=sys.stderr)
        sys.exit(1)

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print(
            "Error: interactive input and output terminals are required.",
            file=sys.stderr,
        )
        sys.exit(1)

    directory = sys.argv[1] if len(sys.argv) == 2 else "."

    try:
        run_console_wizard(directory)
    except (KeyboardInterrupt, EOFError):
        print("\nCancelled.")
        sys.exit(130)
'''

# 既存の__main__起動処理の直前へ追加する。
updated_tree = ast.parse(updated)
guards = [
    node
    for node in updated_tree.body
    if isinstance(node, ast.If)
    and isinstance(node.test, ast.Compare)
    and isinstance(node.test.left, ast.Name)
    and node.test.left.id == "__name__"
    and len(node.test.ops) == 1
    and isinstance(node.test.ops[0], ast.Eq)
    and len(node.test.comparators) == 1
    and isinstance(node.test.comparators[0], ast.Constant)
    and node.test.comparators[0].value == "__main__"
]
if len(guards) != 1:
    raise SystemExit("Could not uniquely locate the __main__ entry point.")

lines = updated.splitlines(keepends=True)
lines.insert(
    guards[0].lineno - 1,
    "\n\n" + console_code.strip() + "\n\n",
)
updated = "".join(lines)

translations = {
    "分割上限は1,024 tokens以上にしてください。":
        "The token limit must be at least 1,024.",
    "ディレクトリがありません:":
        "Directory not found:",
    "対象のテキストファイルがありません。":
        "No text files were found.",
    "見出しを含めると上限に収まりません:":
        "The section cannot fit within the token limit:",
    "単一ブロックが上限を超えています。":
        "A single block exceeds the token limit.",
    "最終出力のトークン上限チェックに失敗しました。":
        "Final output token validation failed.",
    "出力直前のトークン検証に失敗しました。":
        "Pre-export token validation failed.",
}
for old, new in translations.items():
    updated = updated.replace(old, new)

final_tree = ast.parse(updated, filename=str(target))
if any(is_textual_import(node) for node in ast.walk(final_tree)):
    raise SystemExit("A Textual import remains. No changes were saved.")

requirements = Path("cat2-requirements.txt")
content = (
    requirements.read_text(encoding="utf-8")
    if requirements.exists() else ""
)
kept = []
for line in content.splitlines():
    if re.match(
        r"^\s*(textual|inquirerpy|tiktoken)(?=\s|[<>=!~;\[]|$)",
        line,
        flags=re.IGNORECASE,
    ):
        continue
    kept.append(line)

while kept and not kept[-1].strip():
    kept.pop()

kept.extend([
    "InquirerPy>=0.3.4,<0.4",
    "tiktoken>=0.8,<1",
])

target.write_text(updated, encoding="utf-8")
requirements.write_text(
    "\n".join(kept) + "\n",
    encoding="utf-8",
)

print(f"Updated: {target}")
print(f"Updated: {requirements}")
print("Python syntax validation passed.")
print("Textual imports were removed.")
print("Interactive runtime testing has not been performed.")
PY

git add .
git commit -m 'TextualをInquirerPyの対話式CLIに置き換え'
SH

chmod +x gemini-scripts/004-replace-textual-with-inquirerpy.sh
./gemini-scripts/004-replace-textual-with-inquirerpy.sh