"""SketchUp MCP Server - Bridge Claude/Cursor to SketchUp via MCP protocol."""

import asyncio

__version__ = "2.0.0"


def main():
    """Entry point for the CLI command."""
    from .server import main as async_main
    asyncio.run(async_main())


__all__ = ["main"]