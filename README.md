VERY, VERY, VERY WORK IN PROGRESS
---

run server

    go run .

run vim using the plugin

    vim -S "$PWD/viminfo.vim"

or install it

    mkdir -p ~/.vim/plugin
    ln -s "$PWD/viminfo.vim" ~/.vim/plugin/

run claude using the mcp

    claude --mcp-config '{"mcpServers":{"work":{"type":"http","url":"http://127.0.0.1:7865/mcp"}}}'

or add it to claude config

    "mcpServers": {
      "work": {
        "type": "http",
        "url": "http://127.0.0.1:7865/mcp"
      }
    }

issues
---
- buffers that arent files confuse claude
- netrw (dir list) buffers "read" like files with line number, but claude needs the entry to understand it.
