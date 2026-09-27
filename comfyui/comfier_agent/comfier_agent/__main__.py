"""Sidecar entry: python -m comfier_agent"""

import argparse
import asyncio
import logging
import sys

from comfier_agent.config import load_config
from comfier_agent.runtime import run_agent


def main(argv=None):
    parser = argparse.ArgumentParser(description="Comfier agent sidecar")
    parser.add_argument("--comfyui-url", dest="comfyui_url", help="Override local ComfyUI base URL")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="[Comfier] %(levelname)s %(message)s")
    config = load_config(sidecar=True, overrides={"comfyui_url": args.comfyui_url} if args.comfyui_url else None)
    if not config.ok:
        logging.getLogger("comfier_agent").warning(config.idle_reason)
        return 1
    try:
        asyncio.run(run_agent(config, sidecar=True))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
