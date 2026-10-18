#!/usr/bin/env python3
"""project.yml 的离线校验器。

项目在 Windows 上开发，跑不了真正的 `xcodegen generate`。
这个脚本复刻 XcodeGen 对 project.yml 的主要校验逻辑，把配置错误提前暴露出来。

只用标准库，不依赖 PyYAML（Windows 上常常没装）。
内置一个够用的 YAML 子集解析器：支持缩进块、列表、行内 `{}` / `[]`、引号、注释、
多行字符串（`SUBQUERY(...)` 这种跨行块），足以覆盖 project.yml。
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_YML = os.path.join(ROOT, "project.yml")

problems: list[tuple[str, str]] = []  # (level, message)


def ok(msg: str) -> None:
    problems.append(("OK", msg))


def warn(msg: str) -> None:
    problems.append(("WARN", msg))


def fail(msg: str) -> None:
    problems.append(("FAIL", msg))


# --------------------------------------------------------------------------
# 极简 YAML 解析
# --------------------------------------------------------------------------

def strip_comment(line: str) -> str:
    """去掉行尾注释，但保留引号内的 #。"""
    out = []
    quote = None
    for i, ch in enumerate(line):
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
            out.append(ch)
            continue
        if ch == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(ch)
    return "".join(out).rstrip()


def split_key(text: str) -> tuple[str, str | None]:
    """把 `key: value` 拆开，引号里的冒号不算分隔符。"""
    quote = None
    depth = 0
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
            continue
        if ch in "{[(":
            depth += 1
            continue
        if ch in "}])":
            depth -= 1
            continue
        if ch == ":" and depth == 0:
            rest = text[i + 1:].strip()
            return text[:i].strip(), (rest if rest else None)
    return text.strip(), None


def parse_scalar(text: str):
    text = text.strip()
    if text in ("{}", ""):
        return {} if text == "{}" else None
    if text == "[]":
        return []
    if text in ("true", "True", "YES"):
        return True
    if text in ("false", "False", "NO"):
        return False
    if (text.startswith('"') and text.endswith('"') and len(text) > 1) or \
       (text.startswith("'") and text.endswith("'") and len(text) > 1):
        return text[1:-1]
    if text.startswith("["):
        inner = text[1:-1].strip()
        return [parse_scalar(p) for p in inner.split(",")] if inner else []
    if text.startswith("{"):
        inner = text[1:-1].strip()
        result = {}
        if inner:
            for part in inner.split(","):
                k, v = split_key(part)
                result[k] = parse_scalar(v or "")
        return result
    return text


def parse_yaml(lines: list[str], start: int = 0, indent: int = 0):
    """返回 (解析结果, 下一个未消费的行号)。"""
    result: dict | list
    # 先看第一行（跳过空行与注释）是不是列表项
    first = None
    for idx in range(start, len(lines)):
        probe = strip_comment(lines[idx].strip())
        if probe:
            first = probe
            break
    if first is None:
        return {}, len(lines)

    result = [] if first.startswith("- ") or first == "-" else {}

    i = start
    while i < len(lines):
        raw = lines[i]
        if not raw.strip():
            i += 1
            continue
        cur_indent = len(raw) - len(raw.lstrip(" "))
        if cur_indent < indent:
            break
        if cur_indent > indent:
            # 不该出现：上一轮已经把子块吃掉
            i += 1
            continue

        text = strip_comment(raw.strip())
        if not text:
            i += 1
            continue

        if isinstance(result, list):
            if not text.startswith("-"):
                break
            item = text[1:].strip()
            if not item:
                child, i = parse_yaml(lines, i + 1, indent + 2)
                result.append(child)
                continue
            k, v = split_key(item)
            # 只有 `key: ` 后面确实跟着内容（或以冒号结尾）才算映射项，
            # 否则 `- UIInterfaceOrientationPortrait` 会被 split_key 误判。
            is_mapping = v is not None or (":" in item and item.rstrip().endswith(":"))
            if not is_mapping:
                result.append(parse_scalar(item))
                i += 1
                continue
            if v is None:
                # `- key:` 形式，值在缩进的子块里
                child, nxt = parse_yaml(lines, i + 1, indent + 4)
                result.append({k: child})
                i = nxt
                continue
            # `- key: value` 形式：可能还有同缩进的兄弟键跟在后面
            entry = {k: parse_scalar(v)}
            j = i + 1
            while j < len(lines):
                nxt = lines[j]
                if not nxt.strip():
                    j += 1
                    continue
                nindent = len(nxt) - len(nxt.lstrip(" "))
                if nindent <= indent or nindent != indent + 2:
                    break
                ntext = strip_comment(nxt.strip())
                if not ntext or ntext.startswith("- "):
                    break
                nk, nv = split_key(ntext)
                if not nk:
                    break
                if nv is None:
                    sub, j2 = parse_yaml(lines, j + 1, indent + 4)
                    entry[nk] = sub
                    j = j2
                    continue
                entry[nk] = parse_scalar(nv)
                j += 1
            result.append(entry)
            i = j
            continue

        # 映射
        if not text or text.startswith("#"):
            i += 1
            continue
        k, v = split_key(text)
        if not k:
            i += 1
            continue
        if v is None:
            # 可能是跨行块（SUBQUERY 那种）或嵌套
            child_lines = []
            j = i + 1
            while j < len(lines):
                nxt = lines[j]
                if not nxt.strip():
                    j += 1
                    continue
                nindent = len(nxt) - len(nxt.lstrip(" "))
                if nindent <= indent:
                    break
                child_lines.append(nxt)
                j += 1

            if child_lines and all(len(l) - len(l.lstrip(" ")) > indent for l in child_lines):
                # 判断是嵌套结构还是纯文本块：
                # 只要有一行形如 `key:` / `key: value` / `- item`，就当作结构化数据。
                # 纯文本块的每一行（如 SUBQUERY 的多行写法）都不会以 key: 开头。
                looks_structural = any(
                    strip_comment(l.strip()).startswith("- ")
                    or split_key(strip_comment(l.strip()))[1] is not None
                    or re.match(r"^[A-Za-z_][\w\-]*\s*:\s*$", strip_comment(l.strip()))
                    for l in child_lines
                )
                if looks_structural:
                    child, nxt = parse_yaml(lines, i + 1, indent + 2)
                    result[k] = child
                    i = nxt
                    continue
                # 纯文本块：拼成一行（NSExtensionActivationRule 就是这种）
                result[k] = " ".join(l.strip() for l in child_lines)
                i = j
                continue
            result[k] = {}
            i += 1
            continue

        # 有值的行
        if v.startswith("|") or v.startswith(">"):
            block = []
            j = i + 1
            while j < len(lines):
                nxt = lines[j]
                if nxt.strip() and (len(nxt) - len(nxt.lstrip(" "))) <= indent:
                    break
                block.append(nxt.strip())
                j += 1
            result[k] = "\n".join(block).strip()
            i = j
            continue

        result[k] = parse_scalar(v)
        i += 1

    return result, i


# --------------------------------------------------------------------------
# 校验规则
# --------------------------------------------------------------------------

def check(yml: dict) -> None:
    if not isinstance(yml, dict):
        fail("project.yml 顶层不是映射结构")
        return

    for key in ("name", "targets"):
        if key in yml:
            ok(f"顶层键存在：{key}")
        else:
            fail(f"顶层缺少必填键：{key}")

    targets = yml.get("targets") or {}
    if not isinstance(targets, dict) or not targets:
        fail("targets 为空")
        return
    ok(f"共 {len(targets)} 个 target：{', '.join(targets)}")

    packages = yml.get("packages") or {}
    package_names = set(packages) if isinstance(packages, dict) else set()

    app_ids: dict[str, str] = {}

    for name, target in targets.items():
        if not isinstance(target, dict):
            fail(f"[{name}] target 定义不是映射")
            continue

        for field in ("type", "platform"):
            if field not in target:
                fail(f"[{name}] 缺少 {field}")
            else:
                ok(f"[{name}] {field} = {target[field]}")

        # sources
        sources = target.get("sources")
        if not sources:
            fail(f"[{name}] 没有配置 sources")
        else:
            for src in sources:
                path = src.get("path") if isinstance(src, dict) else src
                if not path:
                    fail(f"[{name}] sources 里有一项缺少 path")
                    continue
                abs_path = os.path.join(ROOT, path)
                if os.path.isdir(abs_path) or os.path.isfile(abs_path):
                    count = 0
                    if os.path.isdir(abs_path):
                        for _, _, files in os.walk(abs_path):
                            count += len(files)
                    ok(f"[{name}] 源目录存在：{path}/（{count} 个文件）")
                else:
                    fail(f"[{name}] 源目录不存在：{path}")

                excludes = src.get("excludes") if isinstance(src, dict) else None
                if excludes:
                    for pattern in excludes:
                        if not os.path.isdir(abs_path):
                            break
                        hit = 0
                        for cur, _, files in os.walk(abs_path):
                            for f in files:
                                rel = os.path.relpath(os.path.join(cur, f), abs_path).replace("\\", "/")
                                if glob_match(rel, pattern) or glob_match(f, pattern):
                                    hit += 1
                        if hit:
                            ok(f"[{name}] 排除规则命中 {hit} 个文件：{pattern}")
                        else:
                            warn(f"[{name}] 排除规则没有命中任何文件：{pattern}（xcodegen 会给出警告）")

        # dependencies
        deps = target.get("dependencies") or []
        pkg_deps, tgt_deps = 0, 0
        for dep in deps:
            if not isinstance(dep, dict):
                fail(f"[{name}] dependencies 里有一项不是映射")
                continue
            if "package" in dep:
                pkg_deps += 1
                if dep["package"] not in package_names:
                    fail(f"[{name}] 依赖了未定义的包：{dep['package']}")
                elif "product" not in dep:
                    warn(f"[{name}] 包依赖 {dep['package']} 没写 product")
            elif "target" in dep:
                tgt_deps += 1
                if dep["target"] not in targets:
                    fail(f"[{name}] 依赖了不存在的 target：{dep['target']}")
        if deps:
            ok(f"[{name}] 依赖：{pkg_deps} 个包 + {tgt_deps} 个 target")

        settings = target.get("settings") or {}
        base = settings.get("base") if isinstance(settings, dict) else {}
        base = base or {}
        info = target.get("info") or {}
        props = info.get("properties") or {}
        generated_plist = info.get("path")

        bid = base.get("PRODUCT_BUNDLE_IDENTIFIER")
        if bid:
            app_ids[name] = bid
            ok(f"[{name}] bundle id = {bid}")
        else:
            warn(f"[{name}] 没设置 PRODUCT_BUNDLE_IDENTIFIER")

        pname = base.get("PRODUCT_NAME")
        if pname and not pname.isascii():
            fail(f"[{name}] PRODUCT_NAME 必须是 ASCII（当前 {pname}），否则模块名非法")
        elif pname:
            ok(f"[{name}] PRODUCT_NAME = {pname}（ASCII 合法）")

        for field in ("CODE_SIGN_ENTITLEMENTS", "INFOPLIST_FILE"):
            value = base.get(field)
            if not value:
                if field == "CODE_SIGN_ENTITLEMENTS":
                    warn(f"[{name}] 未配置 {field}（App Group / 分享扩展需要）")
                continue
            if field == "INFOPLIST_FILE" and generated_plist:
                # xcodegen 会在 generate 时按 info: 块写出这个文件，现在不存在是对的
                ok(f"[{name}] {field} 由 info 块生成（generate 时才落盘）")
                continue
            abs_path = os.path.join(ROOT, value)
            if os.path.isfile(abs_path):
                ok(f"[{name}] {field} 存在")
                if field == "CODE_SIGN_ENTITLEMENTS":
                    with open(abs_path, encoding="utf-8") as fh:
                        body = fh.read()
                    groups = re.findall(r"<string>([^<]*group[^<]*)</string>", body)
                    if groups:
                        ok(f"[{name}] App Group：{', '.join(groups)}")
                    else:
                        fail(f"[{name}] entitlements 里没有 App Group")
            else:
                fail(f"[{name}] {field} 指向的文件不存在：{value}")

        # info properties
        if not props:
            warn(f"[{name}] 没有 info.properties")
        else:
            if generated_plist:
                ok(f"[{name}] Info.plist 将由 xcodegen 生成：{generated_plist}")
            for key in ("CFBundleDisplayName", "CFBundleShortVersionString", "CFBundleVersion"):
                if key in props:
                    ok(f"[{name}] Info 含 {key}")
                else:
                    warn(f"[{name}] Info 缺少 {key}")

            if target.get("type") == "application":
                for key in ("CFBundleDocumentTypes", "CFBundleURLTypes"):
                    if key in props:
                        ok(f"[{name}] Info 含 {key}（文件打开 / URL Scheme）")
                    else:
                        warn(f"[{name}] Info 缺少 {key}")

            # 扩展激活规则
            ext = props.get("NSExtension") or {}
            rule = (ext.get("NSExtensionAttributes") or {}).get("NSExtensionActivationRule")
            if rule:
                if isinstance(rule, str):
                    depth = 0
                    balanced = True
                    for ch in rule:
                        if ch == "(":
                            depth += 1
                        elif ch == ")":
                            depth -= 1
                            if depth < 0:
                                balanced = False
                                break
                    if balanced and depth == 0:
                        ok(f"[{name}] NSExtensionActivationRule 括号平衡（{len(rule)} 字符）")
                    else:
                        fail(f"[{name}] NSExtensionActivationRule 括号不平衡")
                    if ".@count" not in rule:
                        warn(f"[{name}] ActivationRule 里没有 .@count，可能匹配不到附件")
                else:
                    ok(f"[{name}] NSExtensionActivationRule 是结构化字典")

            principal = ext.get("NSExtensionPrincipalClass")
            if principal:
                ok(f"[{name}] PrincipalClass = {principal}")
                if "$(PRODUCT_MODULE_NAME)" in str(principal) and pname:
                    cls = str(principal).split(".")[-1]
                    src_path = None
                    for src in sources or []:
                        src_path = src.get("path") if isinstance(src, dict) else src
                        if src_path:
                            break
                    found = False
                    if src_path:
                        for cur, _, files in os.walk(os.path.join(ROOT, src_path)):
                            for f in files:
                                if not f.endswith(".swift"):
                                    continue
                                with open(os.path.join(cur, f), encoding="utf-8") as fh:
                                    if f"class {cls}" in fh.read():
                                        found = True
                    if found:
                        ok(f"[{name}] 类 {cls} 在源码里存在")
                    else:
                        fail(f"[{name}] PrincipalClass 指向的类 {cls} 找不到")

    # bundle id 前缀一致性：找出声明了 app-extension 依赖的那个主 App
    extension_targets = {
        dep["target"]
        for target in targets.values() if isinstance(target, dict)
        for dep in (target.get("dependencies") or []) if isinstance(dep, dict) and "target" in dep
    }
    main_ids = [bid for name, bid in app_ids.items() if name not in extension_targets]
    ext_ids = [bid for name, bid in app_ids.items() if name in extension_targets]
    for bid in ext_ids:
        if any(bid.startswith(m + ".") for m in main_ids):
            ok(f"扩展 bundle id 以主 App 为前缀（{bid}）")
        else:
            warn(f"扩展 bundle id {bid} 不以 {main_ids} 为前缀")


def glob_match(path: str, pattern: str) -> bool:
    """支持 `**` 的简易 glob（xcodegen 的 excludes 用这种写法）。"""
    regex = ""
    i = 0
    while i < len(pattern):
        ch = pattern[i]
        if pattern.startswith("**/", i):
            regex += "(?:.*/)?"
            i += 3
            continue
        if pattern.startswith("**", i):
            regex += ".*"
            i += 2
            continue
        if ch == "*":
            regex += "[^/]*"
            i += 1
            continue
        if ch == "?":
            regex += "."
            i += 1
            continue
        regex += re.escape(ch)
        i += 1
    return re.fullmatch(regex, path) is not None


# --------------------------------------------------------------------------

def main() -> int:
    if not os.path.isfile(PROJECT_YML):
        print(f"找不到 {PROJECT_YML}")
        return 2

    with open(PROJECT_YML, encoding="utf-8") as fh:
        raw = fh.read().splitlines()

    try:
        yml, _ = parse_yaml(raw)
    except Exception as exc:  # noqa: BLE001
        print(f"YAML 解析失败：{exc}")
        return 2

    check(yml)

    fails = [m for lv, m in problems if lv == "FAIL"]
    warns = [m for lv, m in problems if lv == "WARN"]
    oks = [m for lv, m in problems if lv == "OK"]

    print("=" * 66)
    print(f"project.yml 离线校验  ·  {len(oks)} 通过  {len(warns)} 警告  {len(fails)} 失败")
    print("=" * 66)

    for lv, msg in problems:
        if lv == "OK":
            continue
        print(f"[{lv:4}] {msg}")

    if not fails and not warns:
        print("全部检查通过。")
    elif not fails:
        print(f"\n{len(warns)} 条警告，不阻塞。")
    else:
        print(f"\n{len(fails)} 条错误需要在 Mac 上跑 xcodegen 之前修掉。")

    print(f"\n（已静默 {len(oks)} 条通过的检查；加 --verbose 可全部打印）")
    if "--verbose" in sys.argv or "-v" in sys.argv:
        print()
        for msg in oks:
            print(f"[OK  ] {msg}")

    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
