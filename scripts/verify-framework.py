#!/usr/bin/env python3
"""Verify a per-build receipt inside the generated XCFramework; see docs/BUILD.md."""
from bridge_integrity import main

if __name__ == '__main__':
    raise SystemExit(main())
