mkdir -p gemini-scripts

cat > gemini-scripts/002-english-step-wizard.sh <<'SH'
#!/bin/zsh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

TARGET="${1:-cat2}"

python3 - "$TARGET" <<'PY'
import ast
import sys
from pathlib import Path

target = Path(sys.argv[1])
if not target.is_file():
    raise SystemExit(f"Target file not found: {target}")

source = target.read_text(encoding="utf-8")
if "class WizardPage(" in source:
    raise SystemExit("The wizard update has already been applied.")

tree = ast.parse(source)
classes = [
    node for node in tree.body
    if isinstance(node, ast.ClassDef) and node.name == "Cat2App"
]
if len(classes) != 1:
    raise SystemExit("Could not uniquely locate Cat2App.")

for required in (
    "build_output_plan",
    "write_output_plan",
):
    if not any(
        isinstance(node, ast.FunctionDef) and node.name == required
        for node in tree.body
    ):
        raise SystemExit(f"Required function not found: {required}")

replacement = r'''
from textual.screen import Screen
from textual.widgets import OptionList, Static


class WizardPage(Screen):
    BINDINGS = [
        ("escape", "back", "Back"),
        ("ctrl+q", "app.quit", "Quit"),
    ]

    def __init__(
        self,
        title,
        description="",
        choices=None,
        selected=None,
        input_value=None,
        integer=False,
        report=None,
        busy=False,
    ):
        super().__init__()
        self.question_title = title
        self.description = description
        self.choices = choices
        self.selected = selected
        self.input_value = input_value
        self.integer = integer
        self.report = report
        self.busy = busy

    def compose(self) -> ComposeResult:
        yield Header()
        with VerticalScroll(id="wizard"):
            yield Static(self.question_title, id="question", markup=False)
            if self.description:
                yield Static(
                    self.description, id="description", markup=False
                )
            if self.report is not None:
                yield TextArea(
                    self.report,
                    read_only=True,
                    id="report",
                )
            if self.input_value is not None:
                yield Input(
                    value=self.input_value,
                    type="integer" if self.integer else "text",
                    id="answer",
                )
            if self.choices:
                yield OptionList(
                    *(label for label, value in self.choices),
                    id="choices",
                )
            yield Static("", id="error", markup=False)
        yield Footer()

    def on_mount(self):
        if self.choices:
            options = self.query_one("#choices", OptionList)
            values = [value for label, value in self.choices]
            options.highlighted = (
                values.index(self.selected)
                if self.selected in values else 0
            )
            options.focus()
        elif self.input_value is not None:
            self.query_one("#answer", Input).focus()

    def on_option_list_option_selected(
        self, event: OptionList.OptionSelected
    ):
        event.stop()
        if self.choices and not self.busy:
            self.app.accept_answer(
                self.choices[event.option_index][1]
            )

    def on_input_submitted(self, event: Input.Submitted):
        event.stop()
        if not self.busy:
            self.app.accept_answer(event.value)

    def action_back(self):
        if not self.busy:
            self.app.go_back()

    def show_error(self, message):
        self.query_one("#error", Static).update(message)


class Cat2App(App):
    TITLE = "cat2 - Gemini Export Wizard"
    BINDINGS = [("ctrl+q", "quit", "Quit")]
    CSS = """
    Screen { layout: vertical; }
    #wizard {
        width: 90%;
        max-width: 110;
        height: 1fr;
        margin: 1 auto;
        padding: 1 2;
    }
    #question {
        text-style: bold;
        margin-bottom: 1;
    }
    #description {
        margin-bottom: 1;
        color: $text-muted;
    }
    #answer {
        width: 100%;
        margin-top: 1;
    }
    #choices {
        height: auto;
        max-height: 16;
        margin-top: 1;
    }
    #report {
        height: 16;
        margin-bottom: 1;
    }
    #error {
        color: $error;
        margin-top: 1;
        height: auto;
    }
    """

    def __init__(self, directory):
        super().__init__()
        self.directory = directory
        self.engine = "flash"
        self.tokenizer = "model:gpt-4o"
        self.limit = ENGINE_PROFILES[self.engine][1]
        self.plan = None
        self.stage = "directory"
        self.page_started = False

    def on_mount(self):
        self.show_stage("directory")

    def display_page(self, page):
        if self.page_started:
            self.switch_screen(page)
        else:
            self.push_screen(page)
            self.page_started = True

    def show_stage(self, stage, report=None):
        self.stage = stage

        if stage == "directory":
            page = WizardPage(
                "1 / 5 - Target directory",
                "Enter the directory to export, then press Enter.",
                input_value=self.directory,
            )

        elif stage == "engine":
            page = WizardPage(
                "2 / 5 - Gemini profile",
                "Use Up / Down to select. Press Enter to continue.\n"
                "Profiles are local presets, not official model limits.",
                choices=[
                    (label, key)
                    for key, (label, _) in ENGINE_PROFILES.items()
                ],
                selected=self.engine,
            )

        elif stage == "tokenizer":
            page = WizardPage(
                "3 / 5 - Token counting model",
                "Use Up / Down to select. Press Enter to continue.\n"
                "tiktoken counts are estimates, not Gemini token counts.",
                choices=TOKENIZERS,
                selected=self.tokenizer,
            )

        elif stage == "limit":
            default = ENGINE_PROFILES[self.engine][1]
            values = sorted({
                8000, 16000, 32000, 64000, 128000,
                default, self.limit,
            })
            page = WizardPage(
                "4 / 5 - Tokens per output file",
                "The limit includes export headers and Markdown fences.\n"
                "Use Up / Down to select. Press Enter to continue.",
                choices=[
                    (
                        f"{value:,} tokens"
                        + (" (profile default)" if value == default else ""),
                        value,
                    )
                    for value in values
                ] + [("Custom limit...", "custom")],
                selected=self.limit,
            )

        elif stage == "custom":
            page = WizardPage(
                "4 / 5 - Custom token limit",
                "Enter at least 1,024 tokens, then press Enter.",
                input_value=str(self.limit),
                integer=True,
            )

        elif stage == "counting":
            page = WizardPage(
                "Counting and splitting...",
                "Collecting files and measuring the final Markdown.\n"
                "The first tokenizer load may download encoding data.\n"
                "Please wait.",
                busy=True,
            )

        elif stage == "review":
            page = WizardPage(
                "5 / 5 - Review and export",
                "Review the estimates, then select an action.\n"
                "Export replaces existing output.NN.md files "
                "in the output directory.",
                report=self.format_plan(),
                choices=[
                    ("Export files", "export"),
                    ("Change token limit", "limit"),
                    ("Start over", "restart"),
                    ("Quit without exporting", "quit"),
                ],
                selected="export",
            )

        elif stage == "writing":
            page = WizardPage(
                "Exporting...",
                "Rechecking token counts and writing output files.\n"
                "Please wait.",
                busy=True,
            )

        elif stage == "done":
            page = WizardPage(
                "Export complete",
                "All output files passed the selected token limit.",
                report=report,
                choices=[
                    ("Export another project", "restart"),
                    ("Quit", "quit"),
                ],
                selected="quit",
            )

        elif stage == "error":
            page = WizardPage(
                "Operation failed",
                "No successful export has been confirmed.",
                report=report,
                choices=[
                    ("Return to token limit", "limit"),
                    ("Start over", "restart"),
                    ("Quit", "quit"),
                ],
                selected="limit",
            )
        else:
            raise ValueError(f"Unknown wizard stage: {stage}")

        self.display_page(page)

    def accept_answer(self, value):
        if self.stage == "directory":
            directory = Path(value).expanduser().resolve()
            if not directory.is_dir():
                self.screen.show_error(
                    f"Directory not found: {directory}"
                )
                return
            self.directory = str(directory)
            self.plan = None
            self.show_stage("engine")

        elif self.stage == "engine":
            if value != self.engine:
                self.engine = value
                self.limit = ENGINE_PROFILES[value][1]
            self.plan = None
            self.show_stage("tokenizer")

        elif self.stage == "tokenizer":
            self.tokenizer = value
            self.plan = None
            self.show_stage("limit")

        elif self.stage == "limit":
            if value == "custom":
                self.show_stage("custom")
            else:
                self.limit = value
                self.start_preview()

        elif self.stage == "custom":
            try:
                limit = int(value)
                if limit < 1024:
                    raise ValueError
            except ValueError:
                self.screen.show_error(
                    "Enter an integer of at least 1,024."
                )
                return
            self.limit = limit
            self.start_preview()

        elif self.stage == "review":
            if value == "export":
                if self.plan is None:
                    self.show_stage(
                        "error", "No preview is available. Please retry."
                    )
                    return
                self.show_stage("writing")
                self.export_worker(self.plan)
            else:
                self.navigate(value)

        elif self.stage in ("done", "error"):
            self.navigate(value)

    def navigate(self, value):
        if value == "quit":
            self.exit()
        elif value == "restart":
            self.plan = None
            self.show_stage("directory")
        elif value == "limit":
            self.plan = None
            self.show_stage("limit")

    def go_back(self):
        previous = {
            "engine": "directory",
            "tokenizer": "engine",
            "limit": "tokenizer",
            "custom": "limit",
            "review": "limit",
            "error": "limit",
        }
        if self.stage in previous:
            self.plan = None
            self.show_stage(previous[self.stage])

    def start_preview(self):
        self.plan = None
        self.show_stage("counting")
        self.preview_worker(
            self.directory,
            self.engine,
            self.tokenizer,
            self.limit,
        )

    def format_plan(self):
        plan = self.plan
        rows = [
            f"Source: {plan.directory}",
            f"Profile: {ENGINE_PROFILES[plan.engine][0]}",
            f"Tokenizer: {plan.tokenizer}",
            f"Encoding: {plan.encoding}",
            f"Input files: {plan.file_count:,}",
            f"Token limit: {plan.limit:,}",
            f"Output files: {len(plan.documents):,}",
            f"Output directory: {Path.cwd()}",
            "",
        ]
        for number, (count, document) in enumerate(
            zip(plan.counts, plan.documents), 1
        ):
            rows.append(
                f"output.{number:02d}.md"
                f"  {count:,} estimated tokens"
                f"  {len(document.encode('utf-8')):,} bytes"
            )
        rows.extend([
            "",
            "Export uses the source snapshot collected during preview.",
            "If source files change, run the preview again.",
        ])
        return "\n".join(rows)

    @work(thread=True, exclusive=True)
    def preview_worker(self, directory, engine, tokenizer, limit):
        try:
            plan = build_output_plan(
                directory, engine, tokenizer, limit
            )
        except Exception as exc:
            self.call_from_thread(
                self.show_stage, "error", str(exc)
            )
        else:
            self.call_from_thread(self.finish_preview, plan)

    def finish_preview(self, plan):
        self.plan = plan
        self.show_stage("review")

    @work(thread=True, exclusive=True)
    def export_worker(self, plan):
        try:
            names = write_output_plan(plan)
        except Exception as exc:
            self.call_from_thread(
                self.show_stage, "error", str(exc)
            )
        else:
            report = (
                f"Output directory: {Path.cwd()}\n"
                f"Files created: {len(names):,}\n\n"
                + "\n".join(names)
            )
            self.call_from_thread(
                self.show_stage, "done", report
            )
'''

node = classes[0]
lines = source.splitlines(keepends=True)
lines[node.lineno - 1:node.end_lineno] = [
    replacement.strip() + "\n"
]
updated = "".join(lines)

# UIに表示される既存のエラーメッセージも英語化する。
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
    "依存パッケージが不足しています。":
        "Required packages are missing.",
    "詳細:":
        "Details:",
}
for old, new in translations.items():
    updated = updated.replace(old, new)

ast.parse(updated, filename=str(target))
target.write_text(updated, encoding="utf-8")

print(f"Updated: {target}")
print("Python syntax validation passed.")
print("The Textual runtime has not been tested by this script.")
PY

git add .
git commit -m 'Textual画面を英語の一問一画面ウィザードに変更'
SH

chmod +x gemini-scripts/002-english-step-wizard.sh
./gemini-scripts/002-english-step-wizard.sh