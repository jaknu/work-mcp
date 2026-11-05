package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func main() {
	// read flags
	addr := flag.String("addr", "127.0.0.1:7865", "address to listen on; keep it on loopback, as there is no auth")
	flag.Parse()

	// setup coupled http mux and mcp
	mux := http.NewServeMux()
	mcps := mcp.NewServer(&mcp.Implementation{Name: "work", Version: "v0.0.0"}, nil)
	mux.Handle("/mcp", mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return mcps }, &mcp.StreamableHTTPOptions{Stateless: true}))

	// plug in vimInfo
	vi := &vimInfo{}
	vi.AddToMux(mux)
	vi.AddToMCP(mcps)

	// serve it up
	srv := &http.Server{Addr: *addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutdownCtx)
	}()
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
