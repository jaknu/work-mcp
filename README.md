VERY, VERY, VERY WORK IN PROGRESS
---

install vim plugin

    mkdir -p ~/.vim/plugin
    ln -s "$PWD/viminfo.vim" ~/.vim/plugin/

run server

    go run .

run claude using it

    claude --mcp-config '{"mcpServers":{"work":{"type":"http","url":"http://127.0.0.1:7865/mcp"}}}'

or at it to claude config

    "mcpServers": {
      "work": {
        "type": "http",
        "url": "http://127.0.0.1:7865/mcp"
      }
    }
