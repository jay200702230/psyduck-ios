#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# CI 用: 修 payload 里安卓硬编码路径 (iOS 无 /data/data, cwd= payload 根)
import glob
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else 'payload_dir'
n_files = 0
n_subs = 0
for f in glob.glob(root + '/parse/jd/*.js') + glob.glob(root + '/template.js') + glob.glob(root + '/util/*.js'):
    with open(f, encoding='utf-8', errors='replace') as fh:
        d = fh.read()
    orig = d
    # '/data/data/.../rt/psyduck/cookie/jd.ini' -> process.cwd() + '/cookie/jd.ini'
    d = re.sub(r"'/data/data/com\.psyduck\.jdtask/files/rt/psyduck/cookie/jd\.ini'",
               "process.cwd() + '/cookie/jd.ini'", d)
    # '/data/data/.../rt' (HOME fallback) -> process.cwd()
    d = re.sub(r"'/data/data/com\.psyduck\.jdtask/files/rt'", "process.cwd()", d)
    # 其余 /data/data/.../rt/psyduck 前缀 -> process.cwd()
    d = re.sub(r"'/data/data/com\.psyduck\.jdtask/files/rt/psyduck", "process.cwd()", d)
    if d != orig:
        with open(f, 'w', encoding='utf-8') as fh:
            fh.write(d)
        n_files += 1
        n_subs += 1
print(f'[patch_paths] patched {n_files} files')
