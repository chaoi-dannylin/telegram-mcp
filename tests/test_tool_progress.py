"""Transfer progress is forwarded as MCP progress notifications to clients that ask for it."""

import asyncio

import pytest
from mcp.server.lowlevel.server import request_ctx
from mcp.shared.context import RequestContext
from mcp.types import CallToolRequest, CallToolResult, RequestParams, ServerResult, TextContent

from telegram_mcp import runtime

MB = 1024 * 1024


class _RecordingSession:
    def __init__(self, fail: bool = False):
        self.sent = []
        self.fail = fail

    async def send_progress_notification(self, **kwargs):
        # A real send waits on the response stream; yielding here is what lets a missing
        # "wait for pending notifications" deliver the result first.
        for _ in range(5):
            await asyncio.sleep(0)
        if self.fail:
            raise RuntimeError("client went away")
        self.sent.append(kwargs)


@pytest.mark.asyncio
async def test_file_progress_is_forwarded_before_the_result():
    session = _RecordingSession()

    async def upload():
        runtime.note_tool_progress(5 * MB, 20 * MB)
        return "sent"

    result = await runtime._await_with_idle_timeout(upload(), 5, (session, "tok", 7))

    assert result == "sent"
    assert session.sent == [
        {
            "progress_token": "tok",
            "progress": 5.0 * MB,
            "total": 20.0 * MB,
            "message": "5.0 / 20.0 MB",
            "related_request_id": 7,
        }
    ]


@pytest.mark.asyncio
async def test_progress_notifications_are_throttled():
    session = _RecordingSession()

    async def upload():
        for transferred in (1, 2, 3):
            runtime.note_tool_progress(transferred * MB, 3 * MB)
        return "sent"

    await runtime._await_with_idle_timeout(upload(), 5, (session, "tok", 7))

    assert [notification["progress"] for notification in session.sent] == [1.0 * MB]


@pytest.mark.asyncio
async def test_progress_that_goes_down_is_not_forwarded(monkeypatch):
    monkeypatch.setattr(runtime, "PROGRESS_NOTIFY_INTERVAL_SECONDS", 0)
    session = _RecordingSession()

    async def two_downloads():
        runtime.note_tool_progress(5 * MB, 20 * MB)
        await asyncio.sleep(0.01)
        runtime.note_tool_progress(2 * MB, 10 * MB)  # the next file starts from zero
        await asyncio.sleep(0.01)
        runtime.note_tool_progress(8 * MB, 10 * MB)
        return "done"

    await runtime._await_with_idle_timeout(two_downloads(), 5, (session, "tok", 7))

    assert [notification["progress"] for notification in session.sent] == [5.0 * MB, 8.0 * MB]


@pytest.mark.asyncio
async def test_annotation_hook_forwards_progress_for_the_current_request(monkeypatch):
    session = _RecordingSession()

    async def original_handler(req):
        runtime.note_tool_progress(1 * MB, 2 * MB)
        return ServerResult(CallToolResult(content=[TextContent(type="text", text="sent")]))

    handlers = runtime.mcp._mcp_server.request_handlers
    installed_handler = handlers[CallToolRequest]
    handlers[CallToolRequest] = original_handler
    monkeypatch.setenv("TELEGRAM_TOOL_TIMEOUT_SECONDS", "5")
    context = RequestContext(
        request_id=3,
        meta=RequestParams.Meta(progressToken="tok"),
        session=session,
        lifespan_context=None,
    )
    token = request_ctx.set(context)
    try:
        runtime._install_annotation_hook()
        response = await handlers[CallToolRequest](None)
    finally:
        request_ctx.reset(token)
        handlers[CallToolRequest] = installed_handler

    assert response.root.content[0].text == "sent"
    assert [(n["progress_token"], n["related_request_id"]) for n in session.sent] == [("tok", 3)]


@pytest.mark.asyncio
async def test_album_progress_counts_files():
    session = _RecordingSession()

    async def upload():
        runtime.note_album_progress(1.5, 4)
        return "sent"

    await runtime._await_with_idle_timeout(upload(), 5, (session, "tok", 7))

    assert session.sent[0]["message"] == "file 2 of 4"
    assert session.sent[0]["total"] == 4.0


@pytest.mark.asyncio
async def test_progress_is_forwarded_with_the_timeout_disabled():
    session = _RecordingSession()

    async def upload():
        runtime.note_tool_progress(1 * MB, 2 * MB)
        return "sent"

    assert await runtime._await_with_idle_timeout(upload(), None, (session, "tok", 7)) == "sent"
    assert len(session.sent) == 1


@pytest.mark.asyncio
async def test_a_failed_progress_notification_does_not_fail_the_call():
    session = _RecordingSession(fail=True)

    async def upload():
        runtime.note_tool_progress(1 * MB, 2 * MB)
        return "sent"

    assert await runtime._await_with_idle_timeout(upload(), 5, (session, "tok", 7)) == "sent"


class _StuckSession:
    """A client that has stopped reading the stream: a notification never goes out."""

    def __init__(self):
        self.started = asyncio.Event()
        self.task = None

    async def send_progress_notification(self, **kwargs):
        self.task = asyncio.current_task()
        self.started.set()
        await asyncio.Event().wait()


@pytest.mark.asyncio
@pytest.mark.parametrize("timeout", [5, None])
async def test_a_stuck_progress_notification_does_not_hold_back_the_result(monkeypatch, timeout):
    monkeypatch.setattr(runtime, "PROGRESS_FLUSH_TIMEOUT_SECONDS", 0.05)
    session = _StuckSession()

    async def upload():
        runtime.note_tool_progress(1 * MB, 2 * MB)
        return "sent"

    # The outer wait_for only keeps a regression from hanging the suite.
    call = runtime._await_with_idle_timeout(upload(), timeout, (session, "tok", 7))
    assert await asyncio.wait_for(call, 2) == "sent"
    assert session.task.cancelled()


@pytest.mark.asyncio
async def test_cancelling_the_call_cancels_its_progress_notification():
    session = _StuckSession()

    async def upload():
        runtime.note_tool_progress(1 * MB, 2 * MB)
        await asyncio.Event().wait()

    call = asyncio.ensure_future(
        runtime._await_with_idle_timeout(upload(), 5, (session, "tok", 7))
    )
    await asyncio.wait_for(session.started.wait(), 2)
    call.cancel()
    with pytest.raises(asyncio.CancelledError):
        await call

    await asyncio.wait({session.task}, timeout=1)
    assert session.task.cancelled()


@pytest.mark.asyncio
async def test_timing_out_cancels_the_progress_notification():
    session = _StuckSession()

    async def upload():
        runtime.note_tool_progress(1 * MB, 2 * MB)
        await asyncio.Event().wait()

    call = asyncio.ensure_future(
        runtime._await_with_idle_timeout(upload(), 0.05, (session, "tok", 7))
    )
    # Not wait_for: its own TimeoutError would look the same as the idle timeout's.
    done, _ = await asyncio.wait({call}, timeout=2)
    assert call in done
    with pytest.raises(asyncio.TimeoutError):
        call.result()
    assert session.task.cancelled()


@pytest.mark.asyncio
async def test_cancelling_the_call_while_a_timed_out_tool_winds_down_cancels_the_notification():
    session = _StuckSession()
    winding_down = asyncio.Event()
    tool = None

    async def upload():
        nonlocal tool
        tool = asyncio.current_task()
        runtime.note_tool_progress(1 * MB, 2 * MB)
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            # Like a Telethon request finishing its round trip before it stops.
            winding_down.set()
            await asyncio.sleep(0.3)
            raise

    call = asyncio.ensure_future(
        runtime._await_with_idle_timeout(upload(), 0.05, (session, "tok", 7))
    )
    await asyncio.wait_for(winding_down.wait(), 2)
    call.cancel()
    with pytest.raises(asyncio.CancelledError):
        await call

    await asyncio.wait({session.task}, timeout=1)
    assert session.task.cancelled()
    await asyncio.wait({tool}, timeout=2)


def _request_context(meta):
    return RequestContext(request_id=9, meta=meta, session=object(), lifespan_context=None)


def test_progress_sink_uses_the_request_progress_token():
    context = _request_context(RequestParams.Meta(progressToken="tok"))
    token = request_ctx.set(context)
    try:
        assert runtime._progress_sink() == (context.session, "tok", 9)
    finally:
        request_ctx.reset(token)


@pytest.mark.parametrize("meta", [None, RequestParams.Meta()])
def test_progress_sink_is_none_when_the_client_did_not_ask(meta):
    token = request_ctx.set(_request_context(meta))
    try:
        assert runtime._progress_sink() is None
    finally:
        request_ctx.reset(token)


def test_progress_sink_is_none_outside_a_request():
    assert runtime._progress_sink() is None
