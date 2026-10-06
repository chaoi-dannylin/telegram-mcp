"""Every file transfer must report progress, or the idle tool timeout cancels it midway."""

import ast
from pathlib import Path

PACKAGE_DIR = Path(__file__).resolve().parents[1] / "telegram_mcp"
TRANSFER_METHODS = {"send_file", "upload_file", "download_media"}
PROGRESS_FUNCTIONS = {"note_tool_progress", "note_album_progress"}
# photo_source.py stays free of runtime imports and only fetches photos and thumbnails,
# which finish well inside the ceiling.
EXEMPT_FILES = {"photo_source.py"}


def _reports_progress(function: ast.AST) -> bool:
    return any(
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id in PROGRESS_FUNCTIONS
        for node in ast.walk(function)
    )


def _transfer_calls():
    for path in sorted(PACKAGE_DIR.rglob("*.py")):
        if path.name in EXEMPT_FILES:
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"))
        # Local wrappers such as download_media's size-limit callback count when they
        # report progress themselves.
        reporting_wrappers = {
            node.name
            for node in ast.walk(tree)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and _reports_progress(node)
        }
        for node in ast.walk(tree):
            if (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr in TRANSFER_METHODS
            ):
                yield f"{path.relative_to(PACKAGE_DIR)}:{node.lineno}", node, reporting_wrappers


def test_scan_finds_transfer_calls():
    # Guards the test below against passing because the scan matched nothing.
    assert list(_transfer_calls())


def test_every_transfer_call_reports_progress():
    missing = []
    for location, node, reporting_wrappers in _transfer_calls():
        callback = next(
            (keyword.value for keyword in node.keywords if keyword.arg == "progress_callback"),
            None,
        )
        if not (
            isinstance(callback, ast.Name)
            and (callback.id in PROGRESS_FUNCTIONS or callback.id in reporting_wrappers)
        ):
            missing.append(location)
    assert missing == []
