#!/usr/bin/env python3
"""Print useful Xcode diagnostics without flooding CI with build settings."""
from pathlib import Path
import re
import subprocess
import sys

source = Path(sys.argv[1]).read_text(errors='replace')
lines = source.splitlines()
selected = set()
for index, line in enumerate(lines):
    if re.search(r'error:|error •|compiler error|fatal error|swift.*error|could not|exception|\*\* BUILD FAILED', line, re.I):
        selected.update(range(max(0, index - 2), min(len(lines), index + 5)))
for index in sorted(selected):
    print(lines[index])
for path in set(re.findall(r'/[^\s"\']*temporary_xcresult_bundle', source)):
    if Path(path).exists():
        result = subprocess.run(['xcrun', 'xcresulttool', 'get', '--legacy', '--format', 'json', '--path', path], capture_output=True, text=True)
        if result.returncode == 0:
            import json
            def messages(value):
                if isinstance(value, dict):
                    if 'message' in value:
                        print(json.dumps(value['message']))
                    for child in value.values(): messages(child)
                elif isinstance(value, list):
                    for child in value: messages(child)
            messages(json.loads(result.stdout))
print('\n'.join(lines[-30:]))
