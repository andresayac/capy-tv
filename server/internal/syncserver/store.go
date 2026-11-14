// Package syncserver is the sync server of Capy TV accounts: end-to-end encrypted items,
// revisions per account and live notifications between an account's devices.
package syncserver

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	_ "modernc.org/sqlite" // pure Go SQLite: no C toolchain, static binaries
)

// Item is one encrypted record of an account. Payload is ciphertext made on the user's devices:
// the server can neither read it nor tell what it is.
type Item struct {
	ID      string  `json:"id"` // opaque, chosen by the devices
	Rev     int64   `json:"rev"`
	Deleted bool    `json:"deleted"`
	Payload *string `json:"payload,omitempty"`
}

// ItemWrite is an item as a device sends it.
type ItemWrite struct {
	ID      string
	Payload *string // nil when deleted
}

// Account is what the server knows of an account: hashes of what proves the password and the
// recovery key, and the account's keys wrapped (encrypted) with each of them, opaque here.
type Account struct {
	ID           int64
	AuthHash     []byte
	AuthSalt     []byte
	RecoveryHash []byte // with the same salt
	PasswordKeys string
	RecoveryKeys string
}

type Session struct {
	AccountID int64
	TokenHash []byte
	Device    string
	Created   time.Time
	Seen      time.Time
}

// Store is everything the server keeps, in one SQLite file.
type Store struct {
	db    *sql.DB
	clock func() time.Time // when sessions are made and used: the API's, so tests turn both forward
}

const schema = `
CREATE TABLE IF NOT EXISTS accounts (
	id INTEGER PRIMARY KEY,
	email TEXT NOT NULL UNIQUE,
	auth_hash BLOB NOT NULL,
	auth_salt BLOB NOT NULL,
	recovery_hash BLOB NOT NULL DEFAULT x'',
	password_keys TEXT NOT NULL DEFAULT '',
	recovery_keys TEXT NOT NULL DEFAULT '',
	rev INTEGER NOT NULL DEFAULT 0,
	created INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
	token_hash BLOB PRIMARY KEY,
	account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
	device TEXT NOT NULL,
	created INTEGER NOT NULL,
	seen INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_by_account ON sessions(account_id);
CREATE TABLE IF NOT EXISTS items (
	account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
	id TEXT NOT NULL,
	rev INTEGER NOT NULL,
	deleted INTEGER NOT NULL DEFAULT 0,
	payload TEXT,
	PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS items_by_rev ON items(account_id, rev);
`

// OpenStore opens (or creates) the database at path; ":memory:" keeps it in memory (tests).
func OpenStore(path string) (*Store, error) {
	pragmas := "_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_pragma=temp_store(memory)"
	dsn := "file:" + path + "?_pragma=journal_mode(wal)&" + pragmas
	if path == ":memory:" {
		dsn = "file::memory:?" + pragmas
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// One connection: writes are one at a time anyway, revisions stay strictly ordered and an
	// in-memory database is not lost to a pool
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	if err := addColumns(db); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db, clock: time.Now}, nil
}

// addColumns brings a database made by an earlier version up to date.
func addColumns(db *sql.DB) error {
	for _, column := range []string{
		"recovery_hash BLOB NOT NULL DEFAULT x''",
		"password_keys TEXT NOT NULL DEFAULT ''",
		"recovery_keys TEXT NOT NULL DEFAULT ''",
	} {
		var found int
		name, _, _ := strings.Cut(column, " ")
		err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('accounts') WHERE name = ?`, name).Scan(&found)
		if err != nil {
			return err
		}
		if found == 0 {
			if _, err := db.Exec(`ALTER TABLE accounts ADD COLUMN ` + column); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *Store) Close() error { return s.db.Close() }

// Backup writes a consistent copy of the database at path to target, which must not exist yet.
// The server may keep running meanwhile. A path with no database is an error: opened as the server
// opens it, a wrong one would make an empty database, and an empty copy of it, and say nothing.
// Says how many accounts the copy has.
func Backup(path, target string) (accounts int, err error) {
	if _, err := os.Stat(path); err != nil {
		return 0, fmt.Errorf("no database at %s: %w", path, err)
	}
	db, err := sql.Open("sqlite", "file:"+path+"?mode=rw&_pragma=busy_timeout(5000)")
	if err != nil {
		return 0, err
	}
	defer db.Close()
	// Nothing changed in it either (no schema made or columns added): it is only read
	if err := db.QueryRow(`SELECT COUNT(*) FROM accounts`).Scan(&accounts); err != nil {
		return 0, fmt.Errorf("%s is no sync database: %w", path, err)
	}
	_, err = db.Exec(`VACUUM INTO ?`, target)
	return accounts, err
}

func (s *Store) now() int64 { return s.clock().UnixMilli() }

// AccountCount is how many accounts there are.
// Size is what the database takes, without the pages it keeps free for reuse.
func (s *Store) Size(ctx context.Context) (int64, error) {
	var pages, free, size int64
	err := s.db.QueryRowContext(ctx, `SELECT page_count, freelist_count, page_size FROM pragma_page_count(), pragma_freelist_count(), pragma_page_size()`).
		Scan(&pages, &free, &size)
	return (pages - free) * size, err
}

func (s *Store) AccountCount(ctx context.Context) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts`).Scan(&n)
	return n, err
}

// CreateAccount returns created=false when the email is taken.
func (s *Store) CreateAccount(ctx context.Context, email string, a Account) (id int64, created bool, err error) {
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO accounts (email, auth_hash, auth_salt, recovery_hash, password_keys, recovery_keys, created)
		VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (email) DO NOTHING`,
		email, a.AuthHash, a.AuthSalt, a.RecoveryHash, a.PasswordKeys, a.RecoveryKeys, s.now())
	if err != nil {
		return 0, false, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return 0, false, nil
	}
	id, err = res.LastInsertId()
	return id, err == nil, err
}

// AccountByEmail returns nil when there is none.
func (s *Store) AccountByEmail(ctx context.Context, email string) (*Account, error) {
	return s.account(ctx, `email = ?`, email)
}

// Account returns nil when there is none.
func (s *Store) Account(ctx context.Context, id int64) (*Account, error) {
	return s.account(ctx, `id = ?`, id)
}

func (s *Store) account(ctx context.Context, where string, arg any) (*Account, error) {
	a := Account{}
	err := s.db.QueryRowContext(ctx,
		`SELECT id, auth_hash, auth_salt, recovery_hash, password_keys, recovery_keys FROM accounts WHERE `+where, arg).
		Scan(&a.ID, &a.AuthHash, &a.AuthSalt, &a.RecoveryHash, &a.PasswordKeys, &a.RecoveryKeys)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return &a, err
}

// SetPassword replaces what proves the password and the keys wrapped with it, and ends every
// session of the account but keep.
func (s *Store) SetPassword(ctx context.Context, accountID int64, authHash []byte, keys string, keep []byte) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, `UPDATE accounts SET auth_hash = ?, password_keys = ? WHERE id = ?`, authHash, keys, accountID)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `DELETE FROM sessions WHERE account_id = ? AND token_hash != ?`, accountID, keep)
	if err != nil {
		return err
	}
	return tx.Commit()
}

// SetRecovery replaces what proves the recovery key and the keys wrapped with it.
func (s *Store) SetRecovery(ctx context.Context, accountID int64, recoveryHash []byte, keys string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE accounts SET recovery_hash = ?, recovery_keys = ? WHERE id = ?`,
		recoveryHash, keys, accountID)
	return err
}

// DeleteAccount removes the account with its sessions and items.
func (s *Store) DeleteAccount(ctx context.Context, accountID int64) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM accounts WHERE id = ?`, accountID)
	return err
}

func (s *Store) CreateSession(ctx context.Context, tokenHash []byte, accountID int64, device string) error {
	t := s.now()
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO sessions (token_hash, account_id, device, created, seen) VALUES (?, ?, ?, ?, ?)`,
		tokenHash, accountID, device, t, t)
	return err
}

// SessionByToken returns the session for a token (nil if none, or if unused since before
// seenAfter), marking it as just seen.
func (s *Store) SessionByToken(ctx context.Context, tokenHash []byte, seenAfter time.Time) (*Session, error) {
	t := s.now()
	var accountID, created int64
	var device string
	err := s.db.QueryRowContext(ctx,
		`UPDATE sessions SET seen = ? WHERE token_hash = ? AND seen >= ? RETURNING account_id, device, created`,
		t, tokenHash, seenAfter.UnixMilli()).
		Scan(&accountID, &device, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &Session{AccountID: accountID, TokenHash: tokenHash, Device: device, Created: time.UnixMilli(created), Seen: time.UnixMilli(t)}, nil
}

// DeleteSession ends a session of the account; false when it has no such session.
func (s *Store) DeleteSession(ctx context.Context, accountID int64, tokenHash []byte) (bool, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE token_hash = ? AND account_id = ?`, tokenHash, accountID)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// ExpireSessions deletes every session unused since before seenAfter.
func (s *Store) ExpireSessions(ctx context.Context, seenAfter time.Time) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE seen < ?`, seenAfter.UnixMilli())
	return err
}

// Sessions of an account, most recently seen first.
func (s *Store) Sessions(ctx context.Context, accountID int64) ([]Session, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT token_hash, device, created, seen FROM sessions WHERE account_id = ? ORDER BY seen DESC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := []Session{}
	for rows.Next() {
		var device string
		var hash []byte
		var created, seen int64
		if err := rows.Scan(&hash, &device, &created, &seen); err != nil {
			return nil, err
		}
		list = append(list, Session{AccountID: accountID, TokenHash: hash, Device: device, Created: time.UnixMilli(created), Seen: time.UnixMilli(seen)})
	}
	return list, rows.Err()
}

// Revision is where an account stands: its latest revision, and its epoch, which tells this
// account apart from an earlier one with the same email (it is when the account was created).
type Revision struct {
	Rev   int64 `json:"rev"`
	Epoch int64 `json:"epoch"`
}

// Revision of the account; zero when there is none.
func (s *Store) Revision(ctx context.Context, accountID int64) (Revision, error) {
	var r Revision
	err := s.db.QueryRowContext(ctx, `SELECT rev, created FROM accounts WHERE id = ?`, accountID).Scan(&r.Rev, &r.Epoch)
	if errors.Is(err, sql.ErrNoRows) {
		return Revision{}, nil
	}
	return r, err
}

// Changes returns the account's revision and what changed after revision since, oldest first,
// read together so nothing slips in between.
func (s *Store) Changes(ctx context.Context, accountID, since int64) (Revision, []Item, error) {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return Revision{}, nil, err
	}
	defer tx.Rollback()
	var r Revision
	err = tx.QueryRowContext(ctx, `SELECT rev, created FROM accounts WHERE id = ?`, accountID).Scan(&r.Rev, &r.Epoch)
	if err != nil {
		return Revision{}, nil, err
	}
	rows, err := tx.QueryContext(ctx,
		`SELECT id, rev, deleted, payload FROM items WHERE account_id = ? AND rev > ? ORDER BY rev`, accountID, since)
	if err != nil {
		return Revision{}, nil, err
	}
	defer rows.Close()
	items := []Item{}
	for rows.Next() {
		var it Item
		var payload sql.NullString
		if err := rows.Scan(&it.ID, &it.Rev, &it.Deleted, &payload); err != nil {
			return Revision{}, nil, err
		}
		if payload.Valid && !it.Deleted {
			it.Payload = &payload.String
		}
		items = append(items, it)
	}
	return r, items, rows.Err()
}

// ErrStale means the account moved past the revision a write was based on.
var ErrStale = errors.New("stale")

// ErrQuota means the write would take the account over its quota.
var ErrQuota = errors.New("quota")

// Put writes a batch under one new revision of the account, atomically, and returns it. With a
// base of 0 or more, it writes only if the account is still at that revision, and otherwise
// returns ErrStale: the device has not seen what another one wrote meanwhile. With a quota above
// 0, it returns ErrQuota rather than take the account's payloads over that many bytes.
func (s *Store) Put(ctx context.Context, accountID, base, quota int64, items []ItemWrite) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var next int64
	err = tx.QueryRowContext(ctx, `UPDATE accounts SET rev = rev + 1 WHERE id = ? AND (? < 0 OR rev = ?) RETURNING rev`,
		accountID, base, base).Scan(&next)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrStale
	}
	if err != nil {
		return 0, err
	}
	stmt, err := tx.PrepareContext(ctx, `INSERT INTO items (account_id, id, rev, deleted, payload) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (account_id, id) DO UPDATE SET rev = excluded.rev, deleted = excluded.deleted, payload = excluded.payload`)
	if err != nil {
		return 0, err
	}
	defer stmt.Close()
	for _, it := range items {
		if _, err := stmt.ExecContext(ctx, accountID, it.ID, next, it.Payload == nil, it.Payload); err != nil {
			return 0, err
		}
	}
	if quota > 0 {
		var used int64
		err := tx.QueryRowContext(ctx, `SELECT COALESCE(SUM(COALESCE(LENGTH(CAST(payload AS BLOB)), 0) + LENGTH(id) + 100), 0) FROM items WHERE account_id = ?`, accountID).
			Scan(&used)
		if err != nil {
			return 0, err
		}
		if used > quota {
			return 0, ErrQuota
		}
	}
	return next, tx.Commit()
}
