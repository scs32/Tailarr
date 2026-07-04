package lunasea

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"tailscale.com/tsnet"
)

// Tailscale wraps tsnet.Server and provides an HTTP proxy for routing traffic.
type Tailscale struct {
	server    *tsnet.Server
	proxy     *http.Server
	listener  net.Listener
	proxyPort int
	mu        sync.Mutex
	running   bool
	stateDir  string
}

// NewTailscale creates a new Tailscale instance with the given state directory and auth key.
func NewTailscale(stateDir, authKey string) *Tailscale {
	// Set environment variables that tsnet needs on iOS where os.Executable() fails
	os.Setenv("HOME", stateDir)
	os.Setenv("TS_LOGS_DIR", stateDir)

	return &Tailscale{
		stateDir: stateDir,
		server: &tsnet.Server{
			Dir:       stateDir,
			Hostname:  "tailarr",
			AuthKey:   authKey,
			Ephemeral: false,
			Logf: func(format string, args ...any) {
				log.Printf("[tsnet] "+format, args...)
			},
		},
	}
}

// StartProxy starts the tsnet server and HTTP proxy, returning the proxy port.
func (t *Tailscale) StartProxy() (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.running {
		return t.proxyPort, nil
	}

	// Start tsnet and block until the node is authenticated and running,
	// so auth-key failures surface to the caller instead of silently
	// leaving the node in NeedsLogin.
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	status, err := t.server.Up(ctx)
	if err != nil {
		t.server.Close()
		return 0, fmt.Errorf("failed to start tsnet: %w", err)
	}
	log.Printf("[tsnet] up: %s (%v)", status.Self.HostName, status.TailscaleIPs)

	// Create listener on random port
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.server.Close()
		return 0, fmt.Errorf("failed to create listener: %w", err)
	}
	t.listener = listener
	t.proxyPort = listener.Addr().(*net.TCPAddr).Port

	// Create HTTP proxy server
	t.proxy = &http.Server{
		Handler:      http.HandlerFunc(t.handleProxy),
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
	}

	// Start proxy in background
	go func() {
		err := t.proxy.Serve(listener)
		log.Printf("[proxy] server exited: %v", err)
	}()
	log.Printf("[proxy] listening on 127.0.0.1:%d", t.proxyPort)

	t.running = true
	return t.proxyPort, nil
}

// EnsureProxy verifies the local proxy listener is still accepting
// connections (iOS reclaims sockets during app suspension) and rebinds it on
// a fresh port if it died. Returns the current (possibly new) proxy port.
func (t *Tailscale) EnsureProxy() (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if !t.running {
		return 0, fmt.Errorf("tailscale is not running")
	}

	// Health check: can we reach our own listener?
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", t.proxyPort), 2*time.Second)
	if err == nil {
		conn.Close()
		return t.proxyPort, nil
	}
	log.Printf("[proxy] listener on port %d is dead (%v), rebinding", t.proxyPort, err)

	if t.listener != nil {
		t.listener.Close()
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, fmt.Errorf("failed to rebind listener: %w", err)
	}
	t.listener = listener
	t.proxyPort = listener.Addr().(*net.TCPAddr).Port

	go func() {
		err := t.proxy.Serve(listener)
		log.Printf("[proxy] server exited: %v", err)
	}()
	log.Printf("[proxy] rebound on 127.0.0.1:%d", t.proxyPort)
	return t.proxyPort, nil
}

// StopProxy stops the HTTP proxy and tsnet server.
func (t *Tailscale) StopProxy() {
	t.mu.Lock()
	defer t.mu.Unlock()

	if !t.running {
		return
	}

	if t.proxy != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		t.proxy.Shutdown(ctx)
	}

	if t.listener != nil {
		t.listener.Close()
	}

	if t.server != nil {
		t.server.Close()
	}

	t.running = false
	t.proxyPort = 0
}

// IsRunning returns whether the proxy is currently running.
func (t *Tailscale) IsRunning() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.running
}

// GetPort returns the current proxy port, or 0 if not running.
func (t *Tailscale) GetPort() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.proxyPort
}

// handleProxy handles HTTP CONNECT requests for proxying through Tailscale.
func (t *Tailscale) handleProxy(w http.ResponseWriter, r *http.Request) {
	log.Printf("[proxy] %s %s (host=%s)", r.Method, r.URL, r.Host)
	if r.Method == http.MethodConnect {
		t.handleConnect(w, r)
	} else {
		t.handleHTTP(w, r)
	}
}

// handleConnect handles HTTPS CONNECT tunneling.
func (t *Tailscale) handleConnect(w http.ResponseWriter, r *http.Request) {
	// Dial the destination through Tailscale
	destConn, err := t.server.Dial(r.Context(), "tcp", r.Host)
	if err != nil {
		log.Printf("[proxy] CONNECT dial %s failed: %v", r.Host, err)
		http.Error(w, fmt.Sprintf("failed to dial: %v", err), http.StatusBadGateway)
		return
	}
	log.Printf("[proxy] CONNECT dial %s ok", r.Host)
	defer destConn.Close()

	// Hijack the client connection
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijacking not supported", http.StatusInternalServerError)
		return
	}

	clientConn, _, err := hijacker.Hijack()
	if err != nil {
		http.Error(w, fmt.Sprintf("hijack failed: %v", err), http.StatusInternalServerError)
		return
	}
	defer clientConn.Close()

	// Send 200 Connection Established
	clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))

	// Bidirectional copy
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		io.Copy(destConn, clientConn)
	}()

	go func() {
		defer wg.Done()
		io.Copy(clientConn, destConn)
	}()

	wg.Wait()
}

// handleHTTP handles regular HTTP requests (non-CONNECT).
func (t *Tailscale) handleHTTP(w http.ResponseWriter, r *http.Request) {
	// Create a new request to the destination
	outReq := r.Clone(r.Context())
	outReq.RequestURI = ""

	// Use tsnet's HTTP client
	httpClient := t.server.HTTPClient()
	resp, err := httpClient.Do(outReq)
	if err != nil {
		log.Printf("[proxy] HTTP %s %s failed: %v", outReq.Method, outReq.URL, err)
		http.Error(w, fmt.Sprintf("request failed: %v", err), http.StatusBadGateway)
		return
	}
	log.Printf("[proxy] HTTP %s %s -> %d", outReq.Method, outReq.URL, resp.StatusCode)
	defer resp.Body.Close()

	// Copy response headers
	for key, values := range resp.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(resp.StatusCode)

	// Copy response body
	io.Copy(w, resp.Body)
}

// main is empty as this is a library for gomobile.
func main() {}
