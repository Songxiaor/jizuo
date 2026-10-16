#!/usr/bin/env python3
"""读 `sample` 的调用图，只看主线程。

sampletree.py <文件> [模式] [参数]
  top N            按「自身」样本数排前 N 的函数（叶子）
  ours N           调用栈里出现过的、属于本 App 的函数，按包含样本数排前 N
  tree MIN [ROOT]  从 ROOT（函数名子串）往下展开，只显示样本 ≥ MIN 的分支
"""
import re
import sys
sys.setrecursionlimit(1000000)
import threading
threading.stack_size(512*1024*1024)
from collections import defaultdict

LINE = re.compile(r"^(?P<prefix>[\s+!:|]*)(?P<count>\d+)\s+(?P<rest>.*)$")


class Node:
    __slots__ = ("name", "count", "children", "depth", "module")

    def __init__(self, name, count, depth, module):
        self.name, self.count, self.depth, self.module = name, count, depth, module
        self.children = []


def parse(path):
    text = open(path, errors="replace").read()
    start = text.find("Call graph:")
    end = text.find("Total number in stack")
    body = text[start:end].splitlines()[1:]
    roots = []
    stack = []
    in_main = False
    for line in body:
        if "Thread_" in line and ("DispatchQueue_1:" in line or "com.apple.main-thread" in line or "Main Thread" in line):
            in_main = True
        elif "Thread_" in line and re.match(r"^\s+\d+\s+Thread_", line):
            in_main = False
        if not in_main:
            continue
        m = LINE.match(line)
        if not m:
            continue
        depth = len(m.group("prefix"))
        rest = m.group("rest")
        mod = ""
        mm = re.search(r"\(in ([^)]+)\)", rest)
        if mm:
            mod = mm.group(1)
        name = re.sub(r"\s+\(in [^)]+\).*$", "", rest).strip()
        name = re.sub(r"\s+\+\s+\d+.*$", "", name)
        node = Node(name, int(m.group("count")), depth, mod)
        while stack and stack[-1].depth >= depth:
            stack.pop()
        if stack:
            stack[-1].children.append(node)
        else:
            roots.append(node)
        stack.append(node)
    return roots


def walk(node, path=()):
    yield node, path
    for child in node.children:
        yield from walk(child, path + (node,))


def main():
    path, mode = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "top"
    roots = parse(path)
    total = sum(r.count for r in roots)
    print("main thread samples:", total)
    if mode == "top":
        n = int(sys.argv[3]) if len(sys.argv) > 3 else 30
        self_counts = defaultdict(int)
        for root in roots:
            for node, _ in walk(root):
                own = node.count - sum(c.count for c in node.children)
                if own > 0:
                    self_counts[(node.name[:110], node.module)] += own
        for (name, mod), c in sorted(self_counts.items(), key=lambda x: -x[1])[:n]:
            print(f"{c:6d}  {mod[:18]:18s} {name}")
    elif mode == "ours":
        n = int(sys.argv[3]) if len(sys.argv) > 3 else 40
        app = sys.argv[4] if len(sys.argv) > 4 else "LinkDigestPerf"
        incl = defaultdict(int)
        for root in roots:
            for node, anc in walk(root):
                if node.module != app:
                    continue
                # 只算最外层那次出现，避免递归重复
                if any(a.name == node.name for a in anc):
                    continue
                incl[node.name[:150]] += node.count
        for name, c in sorted(incl.items(), key=lambda x: -x[1])[:n]:
            print(f"{c:6d}  {name}")
    elif mode == "tree":
        minimum = int(sys.argv[3])
        root_filter = sys.argv[4] if len(sys.argv) > 4 else None
        max_depth = int(sys.argv[5]) if len(sys.argv) > 5 else 40

        def show(node, level):
            if node.count < minimum or level > max_depth:
                return
            print(f"{'  ' * level}{node.count:6d} [{node.module[:14]}] {node.name[:140]}")
            for child in sorted(node.children, key=lambda c: -c.count):
                show(child, level + 1)

        starts = []
        for root in roots:
            for node, anc in walk(root):
                if root_filter is None and node is root:
                    starts.append(node)
                elif root_filter and root_filter in node.name and not any(root_filter in a.name for a in anc):
                    starts.append(node)
        for s in starts:
            show(s, 0)


if __name__ == "__main__" and (len(sys.argv) <= 2 or sys.argv[2] not in ("presence", "collapsed")):
    t = threading.Thread(target=main); t.start(); t.join()


def presence(path, needles):
    roots = parse(path)
    total = sum(r.count for r in roots)

    def count(node, needle):
        if needle in node.name:
            return node.count
        return sum(count(c, needle) for c in node.children)

    idle = 0
    for r in roots:
        for node, _ in walk(r):
            if node.name.startswith("mach_msg2_trap") and not node.children:
                idle += node.count
    print(f"main samples {total}, idle(mach_msg leaf) {idle}, busy {total - idle}")
    for needle in needles:
        c = sum(count(r, needle) for r in roots)
        print(f"{c:6d}  {100 * c / max(1, total - idle):5.1f}% of busy  {needle}")


if __name__ == "__main__" and len(sys.argv) > 2 and sys.argv[2] == "presence":
    t = threading.Thread(target=lambda: presence(sys.argv[1], sys.argv[3:])); t.start(); t.join()


def collapsed(path, minimum, root_filter=None, max_lines=150):
    roots = parse(path)
    out = []

    def show(node, level):
        if len(out) >= max_lines or node.count < minimum:
            return
        # 折叠单链：只有一个够大的子节点、且数量几乎一样时不单独打印
        big = [c for c in node.children if c.count >= minimum]
        if len(big) == 1 and big[0].count >= node.count * 0.97 and level > 0:
            show(big[0], level)
            return
        out.append(f"{'  ' * level}{node.count:6d} [{node.module[:12]}] {node.name[:120]}")
        for child in sorted(big, key=lambda c: -c.count):
            show(child, level + 1)

    starts = []
    for root in roots:
        for node, anc in walk(root):
            if root_filter is None and node is root:
                starts.append(node)
            elif root_filter and root_filter in node.name and not any(root_filter in a.name for a in anc):
                starts.append(node)
    for s in starts:
        show(s, 0)
    print("\n".join(out))


if __name__ == "__main__" and len(sys.argv) > 2 and sys.argv[2] == "collapsed":
    t = threading.Thread(target=lambda: collapsed(sys.argv[1], int(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else None)); t.start(); t.join()
