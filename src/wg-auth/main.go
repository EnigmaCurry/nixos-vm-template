// wg-auth: tiny forward-auth service that maps a request's source IP to a
// wireguard-peer user identity, for use behind Traefik's forwardAuth
// middleware. Sibling of profiles/wg-auth.nix.
//
//	/lookup   200 + X-Remote-User: <user>   when source IP is mapped
//	          200 (no header)                otherwise (fall through to downstream auth)
//	/require  200 + X-Remote-User: <user>   when source IP is mapped
//	          403                            otherwise
//	/healthz  200                            when the map file is loadable
//	          500                            otherwise
//
// Any I/O or parse error on the map file → 500 on both /lookup and /require.
// Traefik surfaces that as a 502 to the client, which is the fail-closed
// posture we want.
//
// Source IP determination: forwardAuth requests always arrive from Traefik on
// loopback, so we can't trust the TCP RemoteAddr. Traefik forwards the request
// with X-Forwarded-For carrying the full chain (incoming XFF, if any, plus
// Traefik's own TCP source appended last). The last entry is what Traefik
// itself observed and is the only entry an on-path client cannot forge.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// mapState is the parsed wg-users.map plus its last-known mtime. reload() is
// cheap when the mtime hasn't changed; requests call it on every hit so the
// service picks up generator-driven changes without a restart.
type mapState struct {
	path  string
	mu    sync.RWMutex
	ips   map[string]string
	err   error
	mtime time.Time
}

func (m *mapState) reload() {
	info, statErr := os.Stat(m.path)
	if statErr != nil {
		m.mu.Lock()
		defer m.mu.Unlock()
		m.err = fmt.Errorf("stat %s: %w", m.path, statErr)
		m.ips = nil
		m.mtime = time.Time{}
		return
	}
	m.mu.RLock()
	fresh := m.err == nil && info.ModTime().Equal(m.mtime)
	m.mu.RUnlock()
	if fresh {
		return
	}

	data, readErr := os.ReadFile(m.path)
	var ips map[string]string
	var parseErr error
	if readErr != nil {
		parseErr = fmt.Errorf("read %s: %w", m.path, readErr)
	} else {
		ips = make(map[string]string)
		for i, raw := range strings.Split(string(data), "\n") {
			line := strings.TrimSpace(raw)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) != 2 {
				parseErr = fmt.Errorf("%s:%d: expected `<ip> <user>`, got %q", m.path, i+1, line)
				break
			}
			if net.ParseIP(fields[0]) == nil {
				parseErr = fmt.Errorf("%s:%d: %q is not a valid IP", m.path, i+1, fields[0])
				break
			}
			ips[fields[0]] = fields[1]
		}
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.err = parseErr
	if parseErr != nil {
		m.ips = nil
	} else {
		m.ips = ips
	}
	m.mtime = info.ModTime()
}

func (m *mapState) lookup(ip string) (string, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.err != nil {
		return "", m.err
	}
	return m.ips[ip], nil
}

// clientIP returns the last entry of X-Forwarded-For. See the file header for
// why the last entry (and not the first) is the authoritative one.
func clientIP(r *http.Request) string {
	xff := r.Header.Get("X-Forwarded-For")
	if xff == "" {
		return ""
	}
	parts := strings.Split(xff, ",")
	return strings.TrimSpace(parts[len(parts)-1])
}

func main() {
	addr := flag.String("addr", "127.0.0.1:9099", "listen address")
	mapPath := flag.String("map", "/run/wg-auth/users.map", "peer→user map file")
	flag.Parse()

	m := &mapState{path: *mapPath}
	m.reload()

	handle := func(require bool) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			m.reload()
			ip := clientIP(r)
			user, err := m.lookup(ip)
			if err != nil {
				log.Printf("map error: %v (client=%q)", err, ip)
				http.Error(w, "wg-auth map unavailable", http.StatusInternalServerError)
				return
			}
			if user == "" {
				if require {
					http.Error(w, "wg peer not mapped", http.StatusForbidden)
					return
				}
				w.WriteHeader(http.StatusOK)
				return
			}
			w.Header().Set("X-Remote-User", user)
			w.WriteHeader(http.StatusOK)
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/lookup", handle(false))
	mux.HandleFunc("/require", handle(true))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		m.reload()
		m.mu.RLock()
		err := m.err
		m.mu.RUnlock()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		fmt.Fprintln(w, "ok")
	})

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Printf("wg-auth listening on %s, map=%s", *addr, *mapPath)
	srv := &http.Server{
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
	}
	if err := srv.Serve(ln); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
