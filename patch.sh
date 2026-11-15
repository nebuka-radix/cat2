mkdir -p gemini-scripts

cat > gemini-scripts/001-add-textual-token-split.sh <<'SH'
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
    raise SystemExit(f"対象ファイルがありません: {target}")

source = target.read_text(encoding="utf-8")
if "class Cat2App(" in source:
    raise SystemExit("Textual版の修正は適用済みです。")

tree = ast.parse(source)
main_nodes = [
    node for node in tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "main"
]
if len(main_nodes) != 1:
    raise SystemExit("main()を一意に特定できません。")

guard_nodes = [
    node for node in tree.body
    if isinstance(node, ast.If)
    and ast.get_source_segment(source, node.test)
    in ('__name__ == \'__main__\'', '__name__ == "__main__"')
]
if len(guard_nodes) != 1:
    raise SystemExit("__main__の起動処理を一意に特定できません。")

anchor = "    # 階層に関係なく node_modules ディレクトリを常に除外する"
if source.count(anchor) != 1:
    raise SystemExit("除外処理の追加位置を特定できません。")

# 元コードの行番号を使い、下から起動処理とmain()を削除する。
lines = source.splitlines(keepends=True)
for node in sorted(
    [main_nodes[0], guard_nodes[0]],
    key=lambda node: node.lineno,
    reverse=True,
):
    del lines[node.lineno - 1:node.end_lineno]

source = "".join(lines)
source = source.replace(
    anchor,
    '''    # 過去の生成物を入力として取り込まない。
    if not is_dir and re.fullmatch(r"output\\.\\d{2,}\\.md", rel_path.name):
        return True

''' + anchor,
    1,
)

addition = r'''

# --- Textual UI / token-based output ---
import tempfile
from dataclasses import dataclass

try:
    import tiktoken
    from textual import work
    from textual.app import App, ComposeResult
    from textual.containers import Horizontal, VerticalScroll
    from textual.widgets import (
        Button, Footer, Header, Input, Label, Select, TextArea
    )
except ImportError as exc:
    raise SystemExit(
        "依存パッケージが不足しています。\n"
        "python3 -m pip install -r cat2-requirements.txt\n"
        f"詳細: {exc}"
    ) from exc


# ツール用の初期値。Gemini公式のモデル上限ではない。
ENGINE_PROFILES = {
    "flash": ("Gemini Flash", 32000),
    "thinking": ("Gemini Thinking", 32000),
    "pro": ("Gemini Pro", 64000),
}

# Geminiモデル指定と、計測用のOpenAIモデル指定は分離する。
TOKENIZERS = [
    ("gpt-4o / o200k_base", "model:gpt-4o"),
    ("gpt-4 / cl100k_base", "model:gpt-4"),
    ("encoding: o200k_base", "encoding:o200k_base"),
    ("encoding: cl100k_base", "encoding:cl100k_base"),
    ("encoding: p50k_base", "encoding:p50k_base"),
]

OUTPUT_PATTERN = re.compile(r"output\.\d{2,}\.md")


@dataclass(frozen=True)
class OutputPlan:
    directory: str
    engine: str
    tokenizer: str
    encoding: str
    limit: int
    documents: tuple
    counts: tuple
    file_count: int


def load_tokenizer(setting):
    kind, name = setting.split(":", 1)
    if kind == "model":
        return tiktoken.encoding_for_model(name)
    return tiktoken.get_encoding(name)


def count_tokens(encoding, text):
    # ソース中の特殊トークン風文字列も通常の文字列として扱う。
    return len(encoding.encode(text, disallowed_special=()))


def fenced_section(label, content):
    label = label.replace("\r", "\\r").replace("\n", "\\n")
    longest = max(
        (len(m.group(0)) for m in re.finditer(r"`+", content)),
        default=0,
    )
    fence = "`" * max(4, longest + 1)
    separator = "" if content.endswith("\n") else "\n"
    return f"{fence}{label}\n{content}{separator}{fence}\n\n"


def split_section(label, content, fits):
    """文字単位の分割で元データを保持し、完成したブロックを再計測する。"""
    whole = fenced_section(label, content)
    if fits(whole):
        return [whole]

    def divide(start, end):
        piece_label = f"{label} [chars {start}:{end}]"
        block = fenced_section(piece_label, content[start:end])
        if fits(block):
            return [block]
        if end - start <= 1:
            raise ValueError(
                f"見出しを含めると上限に収まりません: {label}"
            )

        midpoint = (start + end) // 2
        # 巨大な1行以外は、できるだけ行境界で分割する。
        newline = content.rfind("\n", start, midpoint)
        if newline >= start + (end - start) // 4:
            midpoint = newline + 1
        return divide(start, midpoint) + divide(midpoint, end)

    return divide(0, len(content))


def build_output_plan(directory, engine, tokenizer, limit):
    if limit < 1024:
        raise ValueError("分割上限は1,024 tokens以上にしてください。")

    target = Path(directory).expanduser().resolve()
    if not target.is_dir():
        raise ValueError(f"ディレクトリがありません: {target}")

    encoding = load_tokenizer(tokenizer)
    local_ignore = target / ".cat2ignore"
    ignore_file = (
        local_ignore if local_ignore.is_file() else Path(".cat2ignore")
    )
    rules = load_ignore_rules(ignore_file)
    files = collect_files(target, rules)

    if not files:
        raise ValueError("対象のテキストファイルがありません。")

    engine_label = ENGINE_PROFILES[engine][0]
    header = (
        "# cat2 export\n\n"
        f"- Profile: {engine_label}\n"
        f"- Tokenizer: {tokenizer}\n"
        f"- Encoding: {encoding.name}\n"
        f"- Limit: {limit} estimated tokens per file\n"
        "- Counts are tiktoken estimates, not Gemini token counts.\n\n"
    )

    def fits(block):
        return count_tokens(encoding, header + block) <= limit

    sections = [
        ("#file:tree", get_tree_output(target, ignore_rules=rules))
    ]
    sections.extend(files)

    documents = []
    current = header

    for label, content in sections:
        for block in split_section(label, content, fits):
            candidate = current + block
            if count_tokens(encoding, candidate) > limit:
                if current == header:
                    raise ValueError("単一ブロックが上限を超えています。")
                documents.append(current)
                current = header + block
            else:
                current = candidate

    if current != header:
        documents.append(current)

    counts = tuple(count_tokens(encoding, doc) for doc in documents)
    if not all(count <= limit for count in counts):
        raise ValueError("最終出力のトークン上限チェックに失敗しました。")

    return OutputPlan(
        directory=str(target),
        engine=engine,
        tokenizer=tokenizer,
        encoding=encoding.name,
        limit=limit,
        documents=tuple(documents),
        counts=counts,
        file_count=len(files),
    )


def write_output_plan(plan):
    """全ファイルを一時保存後に配置し、余った旧出力を削除する。"""
    destination = Path.cwd()
    encoding = load_tokenizer(plan.tokenizer)

    # 書き込み直前にも、実際の出力文字列を再計測する。
    actual = tuple(
        count_tokens(encoding, doc) for doc in plan.documents
    )
    if actual != plan.counts or any(n > plan.limit for n in actual):
        raise ValueError("出力直前のトークン検証に失敗しました。")

    names = [
        f"output.{number:02d}.md"
        for number in range(1, len(plan.documents) + 1)
    ]

    with tempfile.TemporaryDirectory(
        prefix=".cat2-stage-", dir=destination
    ) as temporary:
        stage = Path(temporary)
        for name, document in zip(names, plan.documents):
            (stage / name).write_bytes(document.encode("utf-8"))

        for name in names:
            (stage / name).replace(destination / name)

        expected = set(names)
        for path in destination.iterdir():
            if (
                OUTPUT_PATTERN.fullmatch(path.name)
                and path.name not in expected
                and (path.is_file() or path.is_symlink())
            ):
                path.unlink()

    return names


class Cat2App(App):
    TITLE = "cat2 — Gemini向けトークン分割"
    BINDINGS = [("ctrl+q", "quit", "終了")]
    CSS = """
    Screen { layout: vertical; }
    #form { height: 1fr; padding: 1 2; }
    Label { margin-top: 1; }
    Input, Select { width: 100%; }
    #buttons { height: 3; margin-top: 1; }
    Button { margin-right: 1; }
    #report { height: 14; margin-top: 1; }
    """

    def __init__(self, directory):
        super().__init__()
        self.initial_directory = directory
        self.plan = None

    def compose(self) -> ComposeResult:
        yield Header()
        with VerticalScroll(id="form"):
            yield Label("対象ディレクトリ")
            yield Input(value=self.initial_directory, id="directory")
            yield Label("Gemini利用プロファイル")
            yield Select(
                [(label, key) for key, (label, _) in ENGINE_PROFILES.items()],
                value="flash",
                allow_blank=False,
                id="engine",
            )
            yield Label("tiktoken計測モデル / encoding")
            yield Select(
                TOKENIZERS,
                value="model:gpt-4o",
                allow_blank=False,
                id="tokenizer",
            )
            yield Label("1ファイルの上限（tiktoken推定tokens）")
            yield Input(value="32000", type="integer", id="limit")
            yield Label(
                "Geminiの実トークン数とは異なります。"
                "プロファイルの初期上限は変更可能です。"
            )
            with Horizontal(id="buttons"):
                yield Button("計測・分割プレビュー", id="preview", variant="primary")
                yield Button("ファイル出力", id="write", disabled=True)
            yield TextArea(
                "設定後に「計測・分割プレビュー」を実行してください。",
                read_only=True,
                id="report",
            )
        yield Footer()

    def invalidate(self):
        self.plan = None
        self.query_one("#write", Button).disabled = True

    def on_input_changed(self, event: Input.Changed):
        self.invalidate()

    def on_select_changed(self, event: Select.Changed):
        self.invalidate()
        if event.select.id == "engine":
            profile = ENGINE_PROFILES.get(event.value)
            if profile:
                self.query_one("#limit", Input).value = str(profile[1])

    def set_busy(self, busy):
        for selector in (
            "#directory", "#engine", "#tokenizer", "#limit", "#preview"
        ):
            self.query_one(selector).disabled = busy
        self.query_one("#write", Button).disabled = (
            busy or self.plan is None
        )

    def show_report(self, text):
        self.query_one("#report", TextArea).load_text(text)

    def on_button_pressed(self, event: Button.Pressed):
        if event.button.id == "preview":
            try:
                limit = int(self.query_one("#limit", Input).value)
                directory = self.query_one("#directory", Input).value
                engine = self.query_one("#engine", Select).value
                tokenizer = self.query_one("#tokenizer", Select).value
                if limit < 1024:
                    raise ValueError("分割上限は1,024以上にしてください。")
            except ValueError as exc:
                self.show_report(str(exc))
                return

            self.invalidate()
            self.set_busy(True)
            self.show_report("ファイル収集・トークン計測・分割を実行中...")
            self.preview_worker(directory, engine, tokenizer, limit)

        elif event.button.id == "write" and self.plan is not None:
            self.set_busy(True)
            self.show_report("出力直前の再計測と書き込みを実行中...")
            self.write_worker(self.plan)

    @work(thread=True, exclusive=True)
    def preview_worker(self, directory, engine, tokenizer, limit):
        try:
            plan = build_output_plan(
                directory, engine, tokenizer, limit
            )
        except Exception as exc:
            self.call_from_thread(self.finish_error, str(exc))
        else:
            self.call_from_thread(self.finish_preview, plan)

    def finish_error(self, message):
        self.show_report(f"エラー: {message}")
        self.set_busy(False)

    def finish_preview(self, plan):
        self.plan = plan
        rows = [
            f"対象: {plan.directory}",
            f"プロファイル: {ENGINE_PROFILES[plan.engine][0]}",
            f"計測: {plan.tokenizer} → {plan.encoding}",
            f"入力ファイル数: {plan.file_count}",
            f"分割上限: {plan.limit:,} estimated tokens",
            f"出力ファイル数: {len(plan.documents)}",
            f"出力先: {Path.cwd()}",
            "",
        ]
        for number, (count, document) in enumerate(
            zip(plan.counts, plan.documents), 1
        ):
            rows.append(
                f"output.{number:02d}.md: "
                f"{count:,} tokens / "
                f"{len(document.encode('utf-8')):,} bytes"
            )
        rows.extend([
            "",
            "既存のoutput.XX.mdはファイル出力時に置き換えます。",
            "プレビューで収集した内容を出力します。",
            "ソースを変更した場合は再プレビューしてください。",
        ])
        self.show_report("\n".join(rows))
        self.set_busy(False)

    @work(thread=True, exclusive=True)
    def write_worker(self, plan):
        try:
            names = write_output_plan(plan)
        except Exception as exc:
            self.call_from_thread(self.finish_error, str(exc))
        else:
            self.call_from_thread(self.finish_write, names)

    def finish_write(self, names):
        self.show_report(
            f"{len(names)}ファイルを出力しました。\n\n"
            + "\n".join(names)
        )
        self.plan = None
        self.set_busy(False)


def main():
    if len(sys.argv) > 2:
        print("Usage: cat2 [directory]", file=sys.stderr)
        sys.exit(1)

    directory = sys.argv[1] if len(sys.argv) == 2 else "."
    Cat2App(directory).run()


if __name__ == "__main__":
    main()
'''

updated = source.rstrip() + "\n\n" + addition.lstrip()
ast.parse(updated, filename=str(target))

requirements = Path("cat2-requirements.txt")
if requirements.exists():
    raise SystemExit(
        "cat2-requirements.txtが既にあります。"
        "上書きを避けるため処理を中止しました。"
    )

target.write_text(updated, encoding="utf-8")
requirements.write_text(
    "textual>=0.89,<2\n"
    "tiktoken>=0.8,<1\n",
    encoding="utf-8",
)

print(f"更新しました: {target}")
print("追加しました: cat2-requirements.txt")
print("Python構文チェックに成功しました。")
PY

git add .
git commit -m 'Textual画面とトークン単位の分割出力を追加'
SH

chmod +x gemini-scripts/001-add-textual-token-split.sh
./gemini-scripts/001-add-textual-token-split.sh