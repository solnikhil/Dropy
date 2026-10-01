#!/usr/bin/env python3
"""Fail-closed filesystem observations used by disposable-app checks."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import sys


def walk(root):
    """Include empty directories and symlinks, and never suppress read errors."""
    def visit(entry, relative):
        info = entry.lstat()
        yield entry, relative, info
        if stat.S_ISDIR(info.st_mode):
            for name in sorted(os.listdir(entry)):
                yield from visit(entry / name, relative + '/' + name)
    yield from visit(root, '.')


def digest(root):
    try:
        root.lstat()
    except FileNotFoundError:
        # A missing child of an unreadable ancestor is not evidence of absence.
        ancestor = root.parent
        while not ancestor.exists():
            ancestor = ancestor.parent
        os.listdir(ancestor)
        return 'absent'
    result = hashlib.sha256()
    for entry, relative, info in walk(root):
        result.update(json.dumps([relative, info.st_mode, info.st_size if not stat.S_ISDIR(info.st_mode) else 0],
                                 ensure_ascii=True).encode())
        if stat.S_ISLNK(info.st_mode):
            result.update(os.readlink(entry).encode())
        elif stat.S_ISREG(info.st_mode):
            with entry.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    result.update(block)
        elif not stat.S_ISDIR(info.st_mode):
            raise ValueError(f'unsupported filesystem object: {entry}')
    return result.hexdigest()


def identifiers(root, visited=None):
    try:
        root.lstat()
    except FileNotFoundError:
        return []
    visited = set() if visited is None else visited
    canonical = root.resolve(strict=True)
    if canonical in visited:
        return []
    visited.add(canonical)
    root = canonical
    result = []
    for entry, _, info in walk(root):
        if stat.S_ISLNK(info.st_mode) and entry.suffix in ('.app', '.framework', '.appex', '.bundle'):
            result.extend(identifiers(entry, visited))
        if entry.name == 'Info.plist' and stat.S_ISREG(info.st_mode):
            with entry.open('rb') as stream:
                values = plistlib.load(stream)
            identifier = values.get('CFBundleIdentifier')
            if identifier:
                result.append((identifier, str(entry)))
    return result


try:
    mode, *arguments = sys.argv[1:]
    if mode == 'digest':
        print(digest(Path(arguments[0])))
    elif mode == 'metadata':
        root = Path(arguments[0])
        try:
            root.lstat()
        except FileNotFoundError:
            print(digest(root))
        else:
            result = hashlib.sha256()
            for entry, relative, info in walk(root):
                # Unrelated container contents are not read. File changes still
                # change size/mtime/ctime, while new/deleted paths change the tree.
                values = [relative, info.st_mode]
                if not stat.S_ISDIR(info.st_mode):
                    values += [info.st_size, info.st_mtime_ns, info.st_ctime_ns]
                result.update(json.dumps(values).encode())
            print(result.hexdigest())
    elif mode == 'listing':
        root = Path(arguments[0])
        try:
            print(hashlib.sha256(json.dumps(sorted(os.listdir(root))).encode()).hexdigest())
        except FileNotFoundError:
            print(digest(root))
    elif mode == 'identifiers':
        for argument in arguments:
            for identifier, source in identifiers(Path(argument)):
                print(identifier + '\t' + source)
    else:
        raise ValueError('unknown observation mode')
except (OSError, ValueError, plistlib.InvalidFileException) as error:
    print(f'isolation observation failed: {error}', file=sys.stderr)
    sys.exit(1)
