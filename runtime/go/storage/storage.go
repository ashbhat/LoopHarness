package storage

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

type Turn struct {
	ID            string          `json:"id"`
	CreatedAt     time.Time       `json:"created_at"`
	Status        string          `json:"status"`
	MessagesJSON  json.RawMessage `json:"messages_json"`
	FinalResponse string          `json:"final_response"`
	Error         string          `json:"error,omitempty"`
}

type Job struct {
	JobID       string          `json:"job_id"`
	TurnID      string          `json:"turn_id"`
	Tool        string          `json:"tool"`
	ArgsJSON    json.RawMessage `json:"args_json"`
	Status      string          `json:"status"`
	ResultJSON  json.RawMessage `json:"result_json,omitempty"`
	Error       string          `json:"error,omitempty"`
	CreatedAt   time.Time       `json:"created_at"`
	CompletedAt *time.Time      `json:"completed_at,omitempty"`
}

func New(dbPath string) (*Store, error) {
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("opening db: %w", err)
	}

	// Enable WAL for concurrent reads
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		return nil, fmt.Errorf("setting WAL: %w", err)
	}

	if err := migrate(db); err != nil {
		return nil, fmt.Errorf("migration: %w", err)
	}

	return &Store{db: db}, nil
}

func migrate(db *sql.DB) error {
	schema := `
	CREATE TABLE IF NOT EXISTS turns (
		id TEXT PRIMARY KEY,
		created_at TEXT NOT NULL,
		status TEXT NOT NULL DEFAULT 'running',
		messages_json TEXT NOT NULL,
		final_response TEXT NOT NULL DEFAULT '',
		error TEXT NOT NULL DEFAULT ''
	);
	CREATE TABLE IF NOT EXISTS jobs (
		job_id TEXT PRIMARY KEY,
		turn_id TEXT NOT NULL,
		tool TEXT NOT NULL,
		args_json TEXT NOT NULL,
		status TEXT NOT NULL DEFAULT 'pending',
		result_json TEXT NOT NULL DEFAULT '',
		error TEXT NOT NULL DEFAULT '',
		created_at TEXT NOT NULL,
		completed_at TEXT,
		FOREIGN KEY (turn_id) REFERENCES turns(id)
	);
	`
	_, err := db.Exec(schema)
	return err
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) CreateTurn(id string, messagesJSON json.RawMessage) error {
	_, err := s.db.Exec(
		"INSERT INTO turns (id, created_at, status, messages_json) VALUES (?, ?, 'running', ?)",
		id, time.Now().UTC().Format(time.RFC3339), string(messagesJSON),
	)
	return err
}

func (s *Store) CompleteTurn(id, finalResponse, errMsg string) error {
	status := "completed"
	if errMsg != "" {
		status = "error"
	}
	_, err := s.db.Exec(
		"UPDATE turns SET status = ?, final_response = ?, error = ? WHERE id = ?",
		status, finalResponse, errMsg, id,
	)
	return err
}

func (s *Store) GetTurn(id string) (*Turn, error) {
	row := s.db.QueryRow("SELECT id, created_at, status, messages_json, final_response, error FROM turns WHERE id = ?", id)
	var t Turn
	var createdStr, messagesStr string
	if err := row.Scan(&t.ID, &createdStr, &t.Status, &messagesStr, &t.FinalResponse, &t.Error); err != nil {
		return nil, fmt.Errorf("turn not found: %w", err)
	}
	t.CreatedAt, _ = time.Parse(time.RFC3339, createdStr)
	t.MessagesJSON = json.RawMessage(messagesStr)
	return &t, nil
}

func (s *Store) CreateJob(jobID, turnID, tool string, argsJSON json.RawMessage) error {
	_, err := s.db.Exec(
		"INSERT INTO jobs (job_id, turn_id, tool, args_json, status, created_at) VALUES (?, ?, ?, ?, 'pending', ?)",
		jobID, turnID, tool, string(argsJSON), time.Now().UTC().Format(time.RFC3339),
	)
	return err
}

func (s *Store) CompleteJob(jobID string, resultJSON json.RawMessage, errMsg string) error {
	status := "completed"
	if errMsg != "" {
		status = "error"
	}
	_, err := s.db.Exec(
		"UPDATE jobs SET status = ?, result_json = ?, error = ?, completed_at = ? WHERE job_id = ?",
		status, string(resultJSON), errMsg, time.Now().UTC().Format(time.RFC3339), jobID,
	)
	return err
}

func (s *Store) TimeoutJob(jobID string) error {
	_, err := s.db.Exec(
		"UPDATE jobs SET status = 'timed_out', completed_at = ? WHERE job_id = ?",
		time.Now().UTC().Format(time.RFC3339), jobID,
	)
	return err
}

func (s *Store) GetJob(jobID string) (*Job, error) {
	row := s.db.QueryRow("SELECT job_id, turn_id, tool, args_json, status, result_json, error, created_at, completed_at FROM jobs WHERE job_id = ?", jobID)
	var j Job
	var createdStr, argsStr, resultStr string
	var completedStr sql.NullString
	if err := row.Scan(&j.JobID, &j.TurnID, &j.Tool, &argsStr, &j.Status, &resultStr, &j.Error, &createdStr, &completedStr); err != nil {
		return nil, fmt.Errorf("job not found: %w", err)
	}
	j.CreatedAt, _ = time.Parse(time.RFC3339, createdStr)
	j.ArgsJSON = json.RawMessage(argsStr)
	j.ResultJSON = json.RawMessage(resultStr)
	if completedStr.Valid {
		t, _ := time.Parse(time.RFC3339, completedStr.String)
		j.CompletedAt = &t
	}
	return &j, nil
}
