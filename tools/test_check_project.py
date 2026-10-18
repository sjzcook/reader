#!/usr/bin/env python3
"""校验器自测：手写 YAML 解析器 vs PyYAML。

`tools/check_project.py` 为了在没装 PyYAML 的 Windows 上也能跑，内置了一个
精简 YAML 解析器。解析器出错会让校验结果变成假阳性，所以这里做一次对拍。

需要 PyYAML（没装就跳过并返回 0，不影响主流程）：

    pip install pyyaml
    python tools/test_check_project.py
"""

from __future__ import annotations

import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_module():
    path = os.path.join(ROOT, "tools", "check_project.py")
    spec = importlib.util.spec_from_file_location("check_project", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    try:
        import yaml
    except ImportError:
        print("跳过：未安装 PyYAML（pip install pyyaml）")
        return 0

    module = load_module()
    path = os.path.join(ROOT, "project.yml")
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()

    mine, _ = module.parse_yaml(raw.splitlines())
    real = yaml.safe_load(raw)

    diffs: list[str] = []

    def diff(a, b, where=""):
        if type(a) is not type(b):
            diffs.append(f"类型差异 {where}: {type(a).__name__} vs {type(b).__name__}")
            return
        if isinstance(a, dict):
            for key in set(a) | set(b):
                if key not in a:
                    diffs.append(f"缺少 {where}/{key}")
                elif key not in b:
                    diffs.append(f"多余 {where}/{key}")
                else:
                    diff(a[key], b[key], f"{where}/{key}")
        elif isinstance(a, list):
            if len(a) != len(b):
                diffs.append(f"长度差异 {where}: {len(a)} vs {len(b)}")
            for i, (x, y) in enumerate(zip(a, b)):
                diff(x, y, f"{where}[{i}]")
        elif a != b:
            diffs.append(f"值差异 {where}: {a!r} != {b!r}")

    diff(mine, real)

    if diffs:
        print(f"FAIL：{len(diffs)} 处差异")
        for line in diffs[:40]:
            print(f"  {line}")
        return 1

    print("OK：手写解析器与 PyYAML 结果完全一致")

    # 顺手校验 workflow 也能解析
    wf = os.path.join(ROOT, ".github", "workflows", "build.yml")
    if os.path.isfile(wf):
        with open(wf, encoding="utf-8") as fh:
            yaml.safe_load(fh)
        print("OK：.github/workflows/build.yml 语法正确")
    return 0


if __name__ == "__main__":
    sys.exit(main())
