package bridge

import (
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"os"
	"sync"
	"time"
)

const deviceTimeout = 30 * time.Second

// Result is what the device returns for a job.
type Result struct {
	Data  json.RawMessage `json:"data,omitempty"`
	Error string          `json:"error,omitempty"`
}

// APNsClient is the interface for sending push notifications.
// Allows injection of fakes in tests.
type APNsClient interface {
	SendPush(deviceToken string, payload []byte) error
}

// Bridge manages VM ↔ device communication via APNs push + HTTP callback.
type Bridge struct {
	client      APNsClient
	deviceToken string
	stubbed     bool

	mu       sync.Mutex
	pending  map[string]chan Result
}

func New(keyPath, keyID, teamID, bundleID, deviceToken string) (*Bridge, error) {
	client, err := newHTTP2Client(keyPath, keyID, teamID, bundleID)
	if err != nil {
		return nil, err
	}
	return &Bridge{
		client:      client,
		deviceToken: deviceToken,
		pending:     make(map[string]chan Result),
	}, nil
}

func NewStubbed() *Bridge {
	return &Bridge{
		stubbed: true,
		pending: make(map[string]chan Result),
	}
}

// NewWithClient creates a bridge with a custom APNs client (for testing).
func NewWithClient(client APNsClient, deviceToken string) *Bridge {
	return &Bridge{
		client:      client,
		deviceToken: deviceToken,
		pending:     make(map[string]chan Result),
	}
}

// CallDevice sends a push to the device and waits for the result.
func (b *Bridge) CallDevice(ctx context.Context, jobID, tool string, args json.RawMessage) (json.RawMessage, error) {
	ch := make(chan Result, 1)
	b.mu.Lock()
	b.pending[jobID] = ch
	b.mu.Unlock()

	defer func() {
		b.mu.Lock()
		delete(b.pending, jobID)
		b.mu.Unlock()
	}()

	// Send push notification
	payload, _ := json.Marshal(map[string]interface{}{
		"job_id": jobID,
		"tool":   tool,
		"args":   args,
	})

	if b.stubbed {
		// In stub mode, just wait for an inbound result (or timeout)
	} else {
		if err := b.client.SendPush(b.deviceToken, payload); err != nil {
			return nil, fmt.Errorf("sending push: %w", err)
		}
	}

	// Wait for result or timeout
	timer := time.NewTimer(deviceTimeout)
	defer timer.Stop()

	select {
	case res := <-ch:
		if res.Error != "" {
			return nil, fmt.Errorf("device error: %s", res.Error)
		}
		return res.Data, nil
	case <-timer.C:
		return nil, fmt.Errorf("device call timed out after %s", deviceTimeout)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// ResolveResult delivers a device result to the waiting goroutine.
func (b *Bridge) ResolveResult(jobID string, result Result) {
	b.mu.Lock()
	ch, ok := b.pending[jobID]
	b.mu.Unlock()
	if ok {
		ch <- result
	}
}

// --- HTTP/2 APNs client implementation ---

type http2APNsClient struct {
	httpClient  *http.Client
	keyID       string
	teamID      string
	bundleID    string
	privateKey  *ecdsa.PrivateKey
	deviceToken string
}

func newHTTP2Client(keyPath, keyID, teamID, bundleID string) (*http2APNsClient, error) {
	keyData, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("reading APNs key: %w", err)
	}

	block, _ := pem.Decode(keyData)
	if block == nil {
		return nil, fmt.Errorf("no PEM block found in %s", keyPath)
	}

	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parsing private key: %w", err)
	}

	ecKey, ok := key.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("key is not ECDSA")
	}

	return &http2APNsClient{
		httpClient: &http.Client{Timeout: 10 * time.Second},
		keyID:      keyID,
		teamID:     teamID,
		bundleID:   bundleID,
		privateKey: ecKey,
	}, nil
}

func (c *http2APNsClient) SendPush(deviceToken string, payload []byte) error {
	// Real APNs HTTP/2 push would go here.
	// For v0, we construct the request but the actual JWT signing and sending
	// is left as a placeholder since we don't have a real key.
	_ = deviceToken
	_ = payload
	return fmt.Errorf("APNs push not fully implemented in v0 — configure a real .p8 key")
}
