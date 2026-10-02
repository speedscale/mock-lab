// Command tutorial-db runs the tutorial's Postgres without Docker: a real
// Postgres 16 as an ordinary process on macOS, Linux or Windows, with the
// tutorial schema loaded. The Postgres binaries are downloaded once into the
// data directory, so nothing is installed system-wide.
//
//	tutorial-db                 start, and stop on Ctrl-C
//	tutorial-db -reset          delete the data first, then start
//	tutorial-db -exec "SQL"     run SQL against the running database and exit
//	tutorial-db -stop           stop a running database (from another terminal)
package main

import (
	"database/sql"
	_ "embed"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	embeddedpostgres "github.com/fergusstrange/embedded-postgres"
	_ "github.com/lib/pq"
)

// schema is contract/schema.sql; CI checks the two copies match.
//
//go:embed schema.sql
var schema string

const defaultPort = 54329

func main() {
	port := flag.Int("port", defaultPort, "port to listen on")
	dir := flag.String("dir", "", "data directory (default: .tutorial-db in the tutorial directory)")
	reset := flag.Bool("reset", false, "delete the database's data before starting")
	execSQL := flag.String("exec", "", "run this SQL against the running database and exit")
	stopDB := flag.Bool("stop", false, "stop the running database and exit")
	flag.Parse()

	if *dir == "" {
		*dir = defaultDir()
	}
	if *stopDB {
		if err := stopRunning(*dir); err != nil {
			fail(err)
		}
		return
	}
	if *execSQL != "" {
		if err := run(*port, *execSQL); err != nil {
			fail(err)
		}
		return
	}
	if err := serve(*port, *dir, *reset); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "tutorial-db:", err)
	os.Exit(1)
}

// defaultDir keeps the data next to the tutorial's contract/ directory, so
// running from tutorial/ or a language directory finds the same database.
func defaultDir() string {
	for _, base := range []string{".", ".."} {
		if st, err := os.Stat(filepath.Join(base, "contract")); err == nil && st.IsDir() {
			return filepath.Join(base, ".tutorial-db")
		}
	}
	return ".tutorial-db"
}

func connURL(port int) string {
	return fmt.Sprintf("postgres://tutorial:tutorial@localhost:%d/tutorial?sslmode=disable", port)
}

func serve(port int, dir string, reset bool) error {
	dir, err := filepath.Abs(dir)
	if err != nil {
		return err
	}
	if reset {
		if err := os.RemoveAll(filepath.Join(dir, "data")); err != nil {
			return fmt.Errorf("reset: %w", err)
		}
	}
	if !portFree(port) {
		if _, err := os.Stat(filepath.Join(dir, "data", "postmaster.pid")); err == nil {
			return fmt.Errorf("port %d is in use and %s holds a running database: it is already running (stop it with tutorial-db -stop)", port, dir)
		}
		return fmt.Errorf("port %d is in use: stop whatever listens there (another Postgres?), or start with -port and point DATABASE_URL at that port", port)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	logFile, err := os.OpenFile(filepath.Join(dir, "postgres.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer logFile.Close()

	fmt.Printf("tutorial-db: starting Postgres 16 in %s (the first start downloads about 30 MB)\n", dir)
	pg := embeddedpostgres.NewDatabase(embeddedpostgres.DefaultConfig().
		Version(embeddedpostgres.V16).
		Port(uint32(port)).
		Username("tutorial").Password("tutorial").Database("tutorial").
		CachePath(filepath.Join(dir, "cache")).
		RuntimePath(filepath.Join(dir, "runtime")).
		DataPath(filepath.Join(dir, "data")).
		StartTimeout(2 * time.Minute).
		Logger(logFile))
	if err := pg.Start(); err != nil {
		return fmt.Errorf("start Postgres (log: %s): %w", logFile.Name(), err)
	}

	if err := run(port, schema); err != nil {
		_ = pg.Stop()
		return fmt.Errorf("load schema: %w", err)
	}
	fmt.Printf("tutorial-db: ready on localhost:%d\nDATABASE_URL=%s\nPress Ctrl-C to stop.\n", port, connURL(port))

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-stop:
			fmt.Println("tutorial-db: stopping")
			return pg.Stop()
		case <-tick.C:
			// Postgres runs as its own process: stopped with -stop (or killed),
			// this helper has nothing left to do.
			if portFree(port) {
				fmt.Println("tutorial-db: Postgres stopped")
				return nil
			}
		}
	}
}

func portFree(port int) bool {
	l, err := net.Listen("tcp", fmt.Sprintf("localhost:%d", port))
	if err != nil {
		return false
	}
	_ = l.Close()
	return true
}

// stopRunning stops the database in dir with its own pg_ctl. It works on every
// OS, including Windows, where Ctrl-C cannot be sent to another process, and
// it also stops a Postgres left behind when the helper itself was killed.
func stopRunning(dir string) error {
	dir, err := filepath.Abs(dir)
	if err != nil {
		return err
	}
	data := filepath.Join(dir, "data")
	if _, err := os.Stat(filepath.Join(data, "postmaster.pid")); err != nil {
		fmt.Println("tutorial-db: not running")
		return nil
	}
	pgCtl := filepath.Join(dir, "runtime", "bin", "pg_ctl")
	if os.PathSeparator == '\\' {
		pgCtl += ".exe"
	}
	out, err := exec.Command(pgCtl, "stop", "-D", data, "-m", "fast", "-w").CombinedOutput()
	if err != nil {
		return fmt.Errorf("pg_ctl stop: %w\n%s", err, out)
	}
	fmt.Println("tutorial-db: stopped")
	return nil
}

// run executes SQL against the database on port and prints any rows.
func run(port int, query string) error {
	db, err := sql.Open("postgres", connURL(port))
	if err != nil {
		return err
	}
	defer db.Close()
	if err := db.Ping(); err != nil {
		return fmt.Errorf("no database on port %d (is tutorial-db running?): %w", port, err)
	}
	if !strings.HasPrefix(strings.ToUpper(strings.TrimSpace(query)), "SELECT") {
		_, err := db.Exec(query)
		return err
	}
	rows, err := db.Query(query)
	if err != nil {
		return err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return err
	}
	vals := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	fmt.Println(strings.Join(cols, "\t"))
	for rows.Next() {
		if err := rows.Scan(ptrs...); err != nil {
			return err
		}
		out := make([]string, len(vals))
		for i, v := range vals {
			if b, ok := v.([]byte); ok {
				v = string(b)
			}
			out[i] = fmt.Sprint(v)
		}
		fmt.Println(strings.Join(out, "\t"))
	}
	return errors.Join(rows.Err())
}
