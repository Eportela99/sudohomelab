"""files group: fs_* tools, locked to ONE folder (/data/files in the container,
/opt/sudohomelab/mcp/files on the host). Nothing outside it can be reached:
every path is resolved (symlinks included) and checked before use."""
import fnmatch
import functools
import os
import shutil

from common import DATA_DIR, as_bool, as_int, env

GROUP = "files"
TOOLS = ["fs_list", "fs_tree", "fs_stat", "fs_read_file", "fs_find", "fs_search",
         "fs_write_file", "fs_mkdir", "fs_copy", "fs_move", "fs_delete"]

ROOT = os.path.realpath(env("FILES_ROOT", os.path.join(DATA_DIR, "files")))
MAX_READ = 200_000


class PathError(ValueError):
    pass


def _p(path):
    """Absolute path inside ROOT, or PathError."""
    rel = (path or ".").replace("\\", "/").lstrip("/")
    full = os.path.realpath(os.path.join(ROOT, rel))
    if full != ROOT and not full.startswith(ROOT + os.sep):
        raise PathError("path %r is outside the files folder" % path)
    return full


def _rel(full):
    r = os.path.relpath(full, ROOT)
    return "/" if r == "." else "/" + r.replace(os.sep, "/")


def _size(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return "%d %s" % (n, unit) if unit == "B" else "%.1f %s" % (n, unit)
        n /= 1024
    return "%.1f TB" % n


def _guard(fn):
    @functools.wraps(fn)          # keeps the signature FastMCP builds the schema from
    def wrapped(*a, **kw):
        try:
            return fn(*a, **kw)
        except PathError as e:
            return "%s: %s" % (fn.__name__, e)
        except FileNotFoundError as e:
            return "%s: not found: %s" % (fn.__name__, _rel(e.filename) if e.filename else e)
        except Exception as e:
            return "%s error: %s: %s" % (fn.__name__, type(e).__name__, e)
    return wrapped


def register(mcp):
    os.makedirs(ROOT, exist_ok=True)

    @mcp.tool()
    @_guard
    def fs_list(path: str = "/", include_hidden: bool | str | None = False) -> str:
        """List a folder in the shared files area ("/" is its top)."""
        full = _p(path)
        hidden = as_bool(include_hidden)
        rows = []
        for e in sorted(os.scandir(full), key=lambda e: (not e.is_dir(), e.name.lower())):
            if e.name.startswith(".") and not hidden:
                continue
            st = e.stat(follow_symlinks=False)
            rows.append("%s %-40s %10s" % ("d" if e.is_dir() else "-", e.name + ("/" if e.is_dir() else ""),
                                           "" if e.is_dir() else _size(st.st_size)))
        return "%s (%d entries)\n%s" % (_rel(full), len(rows), "\n".join(rows) or "(empty)")

    @mcp.tool()
    @_guard
    def fs_tree(path: str = "/", max_depth: int | float | str | None = 3) -> str:
        """Show a folder tree (up to max_depth levels, 500 entries)."""
        full, depth, out = _p(path), max(1, min(8, as_int(max_depth, 3))), []

        def walk(d, level):
            for e in sorted(os.scandir(d), key=lambda e: (not e.is_dir(), e.name.lower())):
                if e.name.startswith(".") or len(out) >= 500:
                    continue
                out.append("  " * level + e.name + ("/" if e.is_dir() else ""))
                if e.is_dir(follow_symlinks=False) and level + 1 < depth:
                    walk(e.path, level + 1)
        walk(full, 0)
        return _rel(full) + "\n" + ("\n".join(out) or "(empty)")

    @mcp.tool()
    @_guard
    def fs_stat(path: str) -> str:
        """Size, type and modification time of one file or folder."""
        import datetime as dt
        full = _p(path)
        st = os.stat(full)
        return "%s\n  type: %s\n  size: %s\n  modified: %s" % (
            _rel(full), "folder" if os.path.isdir(full) else "file", _size(st.st_size),
            dt.datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S"))

    @mcp.tool()
    @_guard
    def fs_read_file(path: str, max_chars: int | float | str | None = 20000,
                     offset: int | float | str | None = 0) -> str:
        """Read a text file (max_chars at a time; use offset to continue)."""
        full = _p(path)
        limit = max(1, min(MAX_READ, as_int(max_chars, 20000)))
        start = max(0, as_int(offset, 0))
        with open(full, "rb") as fh:
            head = fh.read(4096)
        if b"\0" in head:
            return "fs_read_file: %s looks like a binary file." % _rel(full)
        with open(full, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        part = text[start:start + limit]
        more = start + limit < len(text)
        return "%s (chars %d-%d of %d)\n\n%s%s" % (
            _rel(full), start, start + len(part), len(text), part,
            "\n\n…[more: offset=%d]" % (start + limit) if more else "")

    @mcp.tool()
    @_guard
    def fs_find(path: str = "/", name_glob: str = "*", max_results: int | float | str | None = 200) -> str:
        """Find files by name pattern, e.g. name_glob="*.md"."""
        full, limit, hits = _p(path), max(1, min(2000, as_int(max_results, 200))), []
        for root, dirs, files in os.walk(full):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            hits += [_rel(os.path.join(root, f)) for f in files if fnmatch.fnmatch(f, name_glob or "*")]
            if len(hits) >= limit:
                break
        return "%d match(es):\n%s" % (len(hits[:limit]), "\n".join(hits[:limit]) or "(none)")

    @mcp.tool()
    @_guard
    def fs_search(query: str, path: str = "/", max_results: int | float | str | None = 100) -> str:
        """Search inside text files for a phrase (case-insensitive). Returns file:line: text."""
        full, limit, hits, q = _p(path), max(1, min(1000, as_int(max_results, 100))), [], (query or "").lower()
        if not q:
            return "Provide a query."
        for root, dirs, files in os.walk(full):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for f in files:
                fp = os.path.join(root, f)
                try:
                    if os.path.getsize(fp) > 2_000_000:
                        continue
                    with open(fp, encoding="utf-8", errors="strict") as fh:
                        for n, line in enumerate(fh, 1):
                            if q in line.lower():
                                hits.append("%s:%d: %s" % (_rel(fp), n, line.strip()[:200]))
                                if len(hits) >= limit:
                                    break
                except (UnicodeDecodeError, OSError):
                    continue
                if len(hits) >= limit:
                    break
            if len(hits) >= limit:
                break
        return "%d hit(s) for %r:\n%s" % (len(hits), query, "\n".join(hits) or "(none)")

    @mcp.tool()
    @_guard
    def fs_write_file(path: str, content: str, overwrite: bool | str | None = False,
                      append: bool | str | None = False) -> str:
        """Write a text file (folders are created). Set overwrite=true to replace
        an existing file, or append=true to add to its end."""
        full = _p(path)
        if os.path.isdir(full):
            return "fs_write_file: %s is a folder." % _rel(full)
        if os.path.exists(full) and not (as_bool(overwrite) or as_bool(append)):
            return "fs_write_file: %s exists; pass overwrite=true or append=true." % _rel(full)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "a" if as_bool(append) else "w", encoding="utf-8") as fh:
            fh.write(content or "")
        return "Wrote %d chars to %s." % (len(content or ""), _rel(full))

    @mcp.tool()
    @_guard
    def fs_mkdir(path: str) -> str:
        """Create a folder (and its parents)."""
        full = _p(path)
        os.makedirs(full, exist_ok=True)
        return "Folder ready: %s" % _rel(full)

    @mcp.tool()
    @_guard
    def fs_copy(source_path: str, dest_path: str, overwrite: bool | str | None = False) -> str:
        """Copy a file or folder."""
        src, dst = _p(source_path), _p(dest_path)
        if os.path.exists(dst) and not as_bool(overwrite):
            return "fs_copy: %s exists; pass overwrite=true." % _rel(dst)
        if os.path.isdir(src):
            shutil.copytree(src, dst, dirs_exist_ok=as_bool(overwrite), symlinks=True)
        else:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
        return "Copied %s -> %s" % (_rel(src), _rel(dst))

    @mcp.tool()
    @_guard
    def fs_move(source_path: str, dest_path: str, overwrite: bool | str | None = False) -> str:
        """Move or rename a file or folder."""
        src, dst = _p(source_path), _p(dest_path)
        if src == ROOT:
            return "fs_move: can't move the files folder itself."
        if os.path.exists(dst) and not as_bool(overwrite):
            return "fs_move: %s exists; pass overwrite=true." % _rel(dst)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.move(src, dst)
        return "Moved %s -> %s" % (_rel(src), _rel(dst))

    @mcp.tool()
    @_guard
    def fs_delete(path: str, recursive: bool | str | None = False) -> str:
        """Delete a file, or a folder (non-empty folders need recursive=true)."""
        full = _p(path)
        if full == ROOT:
            return "fs_delete: can't delete the files folder itself."
        if os.path.isdir(full) and not os.path.islink(full):
            if as_bool(recursive):
                shutil.rmtree(full)
            else:
                os.rmdir(full)
        else:
            os.remove(full)
        return "Deleted %s" % _rel(full)
