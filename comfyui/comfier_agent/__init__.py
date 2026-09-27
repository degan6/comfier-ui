"""Comfier agent — ComfyUI custom node entry (no graph nodes)."""

import atexit
import logging
import threading

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
WEB_DIRECTORY = "./web"

LOG = logging.getLogger("comfier_agent")
_runtime_ref = []


def _register_routes() -> None:
    # Registered even when the agent is idle, so the panel can be used to configure it.
    try:
        from comfier_agent.routes import register_routes

        register_routes()
    except Exception:
        LOG.exception("Comfier agent settings routes unavailable")


def _start_agent_thread() -> None:
    from comfier_agent.config import load_config
    from comfier_agent.runtime import AgentRuntime
    import asyncio

    config = load_config()
    if not config.ok:
        LOG.warning(config.idle_reason)
        return

    def runner() -> None:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        runtime = AgentRuntime(config)
        _runtime_ref.append(runtime)
        from comfier_agent.routes import set_runtime

        set_runtime(runtime)
        try:
            loop.run_until_complete(runtime.run(sidecar=False))
        except Exception:
            LOG.exception("Comfier agent thread exited")

    thread = threading.Thread(target=runner, name="comfier-agent", daemon=True)
    thread.start()


def _shutdown() -> None:
    if not _runtime_ref:
        return
    runtime = _runtime_ref[0]
    import asyncio

    try:
        loop = asyncio.get_event_loop()
        if loop.is_running():
            asyncio.create_task(runtime.connection.close())
        else:
            loop.run_until_complete(runtime.connection.close())
    except Exception:
        pass


atexit.register(_shutdown)
_register_routes()
_start_agent_thread()
