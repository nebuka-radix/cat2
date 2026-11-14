#!/bin/zsh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

python3 - <<'PY'
import os
import subprocess
from pathlib import Path

signature = 'def is_ignored(rel_path, is_dir, rules):'
old = '''def is_ignored(rel_path, is_dir, rules):
    """読み込んだルールに基づいて除外対象か判定"""
    if not rules:
        return False
'''
new = '''def is_ignored(rel_path, is_dir, rules):
    """デフォルト除外と読み込んだルールに基づいて除外対象か判定"""
    # 階層に関係なく node_modules ディレクトリを常に除外する
    if is_dir and rel_path.name == 'node_modules':
        return True

    if not rules:
        return False
'''

result = subprocess.run(
    ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
    check=True,
    stdout=subprocess.PIPE,
)

candidates = []
paths = dict.fromkeys(
    os.fsdecode(item) for item in result.stdout.split(b'\0') if item
)

for name in paths:
    path = Path(name)
    if any(part in {'.git', 'node_modules', 'gemini-scripts'} for part in path.parts):
        continue
    if not path.is_file() or path.is_symlink():
        continue

    try:
        source = path.read_bytes().decode('utf-8')
    except (OSError, UnicodeDecodeError):
        continue

    if (
        signature in source
        and 'def collect_files(' in source
        and 'def get_tree_output(' in source
        and 'def generate_output(' in source
    ):
        candidates.append((path, source))

if len(candidates) != 1:
    names = ', '.join(str(path) for path, _ in candidates) or 'なし'
    raise SystemExit(
        f'対象ファイルを一意に特定できません。候補: {names}'
    )

path, source = candidates[0]

if new in source:
    print(f'変更済みです: {path}')
elif source.count(old) == 1:
    updated = source.replace(old, new, 1)
    compile(updated, str(path), 'exec')

    namespace = {'__name__': 'cat2_patch_validation'}
    exec(compile(updated, str(path), 'exec'), namespace)
    is_ignored = namespace['is_ignored']

    assert is_ignored(Path('node_modules'), True, [])
    assert is_ignored(Path('apps/web/node_modules'), True, [])
    assert not is_ignored(Path('apps/web/src'), True, [])
    assert not is_ignored(Path('node_modules'), False, [])
    assert is_ignored(
        Path('apps/web/node_modules'),
        True,
        [{
            'pattern': 'node_modules',
            'negated': True,
            'directory_only': True,
            'anchored': False,
        }],
    )

    path.write_bytes(updated.encode('utf-8'))
    print(f'更新・構文チェック・除外判定テスト完了: {path}')
else:
    raise SystemExit(
        f'想定したコードと一致しないため、変更せず停止しました: {path}'
    )
PY

git add .
git commit -m 'node_modulesを全階層でデフォルト除外'
