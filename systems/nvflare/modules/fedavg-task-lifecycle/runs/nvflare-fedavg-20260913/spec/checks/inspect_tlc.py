#!/usr/bin/env python3
"""CLI adapter for installed TLC summary/state/compare handlers."""
import asyncio
import json
from pathlib import Path
import sys

ROOT = Path('/home/ubuntu/nvflare-runs-20260913/specula')
sys.path.insert(0, str(ROOT / 'tools/inv_checking_tool'))
from src.mcp.handlers.summary import SummaryHandler
from src.mcp.handlers.state import StateHandler
from src.mcp.handlers.compare import CompareHandler

async def main():
    mode, path = sys.argv[1:3]
    args = {'file_path': str(Path(path).resolve())}
    if len(sys.argv) > 3:
        args.update(json.loads(sys.argv[3]))
    handler = {'summary': SummaryHandler, 'state': StateHandler, 'compare': CompareHandler}[mode]()
    result = await handler.execute(args)
    print(json.dumps(result, indent=2, default=str))

if __name__ == '__main__':
    asyncio.run(main())
