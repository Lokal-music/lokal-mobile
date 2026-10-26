#!/usr/bin/env python3
"""Probe the actual app's Dart VM, screen and native startup state."""
import argparse
import os
from pathlib import Path
from ios_runtime import probe

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', nargs='?', type=Path,
                    default=Path('build/ios/iphonesimulator/Runner.app'))
parser.add_argument('--prefix', default='lokal-iphone')
args = parser.parse_args()
probe(args.app, Path(os.environ['RUNNER_TEMP']), args.prefix)
