"""Use the experiment-local structured TLC readers."""
import asyncio
import json
from pathlib import Path
import sys
sys.path.insert(0, '/home/ubuntu/nvflare-job-lifecycle-20260914/specula')
from tools.inv_checking_tool.src.mcp.handlers.summary import SummaryHandler
from tools.inv_checking_tool.src.mcp.handlers.state import StateHandler
from tools.inv_checking_tool.src.mcp.handlers.compare import CompareHandler
async def main():
    args = json.loads(sys.argv[2])
    result = await {'summary': SummaryHandler, 'state': StateHandler, 'compare': CompareHandler}[sys.argv[1]]().execute(args)
    out = json.dumps(result, indent=2, default=str)
    if len(sys.argv)>3:
        Path(sys.argv[3]).write_text(out)
    else:
        print(out)
asyncio.run(main())
