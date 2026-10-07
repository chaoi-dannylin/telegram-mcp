"""Safeguards that must survive tools returning image content, not just text."""

import asyncio

import pytest
from mcp.server.fastmcp import Image
from mcp.types import CallToolResult, ImageContent, ServerResult, TextContent

from telegram_mcp import runtime


@pytest.fixture
def two_accounts(monkeypatch):
    monkeypatch.setattr(runtime, "clients", {"personal": object(), "work": object()})


@pytest.mark.asyncio
async def test_text_only_fan_out_keeps_the_joined_string(two_accounts):
    @runtime.with_account(readonly=True)
    async def describe(account=None):
        return f"described by {account}"

    result = await describe()

    assert result == "[personal]\ndescribed by personal\n\n[work]\ndescribed by work"


@pytest.mark.asyncio
async def test_image_fan_out_returns_content_blocks_instead_of_stringifying(two_accounts):
    @runtime.with_account(readonly=True)
    async def render(account=None):
        return Image(data=b"jpeg-bytes-" + account.encode(), format="jpeg")

    result = await render()

    assert isinstance(result, list)
    assert result[0] == "[personal]"
    assert isinstance(result[1], Image)
    assert result[2] == "[work]"
    assert isinstance(result[3], Image)


@pytest.mark.asyncio
async def test_mixed_text_and_image_fan_out_is_flattened(two_accounts):
    @runtime.with_account(readonly=True)
    async def overview(account=None):
        return [f"index for {account}", Image(data=b"sheet", format="jpeg")]

    result = await overview()

    assert result[0] == "[personal]"
    assert result[1] == "index for personal"
    assert isinstance(result[2], Image)
    assert result[3] == "[work]"


@pytest.mark.asyncio
async def test_image_results_are_annotated_as_user_audience():
    async def original_handler(req):
        return ServerResult(
            CallToolResult(
                content=[
                    TextContent(type="text", text="caption"),
                    ImageContent(type="image", data="Zm9v", mimeType="image/jpeg"),
                ]
            )
        )

    from mcp.types import CallToolRequest

    handlers = runtime.mcp._mcp_server.request_handlers
    installed_handler = handlers[CallToolRequest]
    handlers[CallToolRequest] = original_handler
    try:
        runtime._install_annotation_hook()
        response = await handlers[CallToolRequest](None)
    finally:
        handlers[CallToolRequest] = installed_handler

    text_block, image_block = response.root.content
    assert text_block.annotations.audience == ["user"]
    assert image_block.annotations.audience == ["user"]


@pytest.mark.asyncio
async def test_call_tool_timeout_returns_an_explicit_annotated_error(monkeypatch):
    async def original_handler(req):
        await asyncio.Event().wait()

    from mcp.types import CallToolRequest

    handlers = runtime.mcp._mcp_server.request_handlers
    installed_handler = handlers[CallToolRequest]
    handlers[CallToolRequest] = original_handler
    monkeypatch.setenv("TELEGRAM_TOOL_TIMEOUT_SECONDS", "0.01")
    try:
        runtime._install_annotation_hook()
        response = await handlers[CallToolRequest](None)
    finally:
        handlers[CallToolRequest] = installed_handler

    assert response.root.isError is True
    assert response.root.content[0].text == (
        "Telegram MCP tool timed out after 0.01s without progress (code: GEN-TIMEOUT). "
        "Completion is unknown; a write may already have succeeded. "
        "Check destination state before retrying non-idempotent operations."
    )
    assert response.root.content[0].annotations.audience == ["user"]


@pytest.mark.asyncio
async def test_timeout_after_accepted_write_reports_unknown_completion_once(monkeypatch):
    marker = "synthetic-write-marker-4f1c"
    accepted_writes = []

    async def original_handler(req):
        accepted_writes.append(marker)  # the write landed, then the call stalled
        await asyncio.Event().wait()

    from mcp.types import CallToolRequest

    handlers = runtime.mcp._mcp_server.request_handlers
    installed_handler = handlers[CallToolRequest]
    handlers[CallToolRequest] = original_handler
    monkeypatch.setenv("TELEGRAM_TOOL_TIMEOUT_SECONDS", "0.01")
    try:
        runtime._install_annotation_hook()
        response = await handlers[CallToolRequest](None)
    finally:
        handlers[CallToolRequest] = installed_handler

    assert accepted_writes == [marker]  # dispatched exactly once, never retried
    assert response.root.isError is True
    assert len(response.root.content) == 1
    text = response.root.content[0].text
    assert "code: GEN-TIMEOUT" in text
    assert "Completion is unknown" in text
    assert "a write may already have succeeded" in text
    assert "before retrying" in text
    assert marker not in text
    assert response.root.content[0].annotations.audience == ["user"]


@pytest.mark.parametrize(
    "value, expected",
    [(None, 55.0), ("", 55.0), ("garbage", 55.0), ("3.5", 3.5), ("0", None)],
)
def test_tool_timeout_parsing(monkeypatch, value, expected):
    monkeypatch.delenv("TELEGRAM_TOOL_TIMEOUT_SECONDS", raising=False)
    assert runtime._tool_timeout_seconds(value) == expected


@pytest.mark.asyncio
async def test_disabled_tool_timeout_does_not_relabel_handler_timeout(monkeypatch):
    async def original_handler(req):
        raise asyncio.TimeoutError("tool-specific timeout")

    from mcp.types import CallToolRequest

    handlers = runtime.mcp._mcp_server.request_handlers
    installed_handler = handlers[CallToolRequest]
    handlers[CallToolRequest] = original_handler
    monkeypatch.setenv("TELEGRAM_TOOL_TIMEOUT_SECONDS", "0")
    try:
        runtime._install_annotation_hook()
        with pytest.raises(asyncio.TimeoutError, match="tool-specific timeout"):
            await handlers[CallToolRequest](None)
    finally:
        handlers[CallToolRequest] = installed_handler


async def _call_hooked(monkeypatch, original_handler, timeout: str):
    from mcp.types import CallToolRequest

    handlers = runtime.mcp._mcp_server.request_handlers
    installed_handler = handlers[CallToolRequest]
    handlers[CallToolRequest] = original_handler
    monkeypatch.setenv("TELEGRAM_TOOL_TIMEOUT_SECONDS", timeout)
    try:
        runtime._install_annotation_hook()
        return await handlers[CallToolRequest](None)
    finally:
        handlers[CallToolRequest] = installed_handler


@pytest.mark.asyncio
async def test_progress_keeps_a_call_longer_than_the_ceiling_alive(monkeypatch):
    # A large upload: total time exceeds the ceiling, but no gap between chunks does.
    async def original_handler(req):
        for _ in range(6):
            await asyncio.sleep(0.05)
            runtime.note_tool_progress(1, 1)
        return ServerResult(CallToolResult(content=[TextContent(type="text", text="sent")]))

    response = await _call_hooked(monkeypatch, original_handler, "0.2")

    assert response.root.isError is False
    assert response.root.content[0].text == "sent"


@pytest.mark.asyncio
async def test_progress_that_stops_still_times_out_and_cancels_the_call(monkeypatch):
    cancelled = []

    async def original_handler(req):
        runtime.note_tool_progress(1, 2)
        try:
            await asyncio.Event().wait()  # the upload wedged after its first chunk
        except asyncio.CancelledError:
            cancelled.append(True)
            raise

    response = await _call_hooked(monkeypatch, original_handler, "0.05")

    assert response.root.isError is True
    assert "code: GEN-TIMEOUT" in response.root.content[0].text
    assert cancelled == [True]


@pytest.mark.asyncio
async def test_cancelling_the_caller_cancels_the_tool_call(monkeypatch):
    started = asyncio.Event()
    cancelled = []

    async def original_handler(req):
        started.set()
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            cancelled.append(True)
            raise

    caller = asyncio.ensure_future(_call_hooked(monkeypatch, original_handler, "30"))
    await started.wait()
    caller.cancel()
    with pytest.raises(asyncio.CancelledError):
        await caller
    await asyncio.sleep(0)

    assert cancelled == [True]


def test_note_tool_progress_outside_a_tool_call_is_a_no_op():
    runtime.note_tool_progress(10, 100)


@pytest.mark.asyncio
async def test_caller_cancelled_during_timeout_cleanup_stays_cancelled():
    cleaning_up = asyncio.Event()

    async def tool():
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            cleaning_up.set()
            await asyncio.sleep(0.05)
            raise

    caller = asyncio.ensure_future(runtime._await_with_idle_timeout(tool(), 0.01))
    await cleaning_up.wait()
    caller.cancel()

    # Reporting a timeout here would swallow the host's own cancellation.
    with pytest.raises(asyncio.CancelledError):
        await caller
