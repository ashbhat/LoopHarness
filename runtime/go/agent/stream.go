package agent

import (
	"bufio"
	"io"
)

// NewStreamReaderFromReader creates a StreamReader from an io.ReadCloser.
// Exported for testing.
func NewStreamReaderFromReader(r io.ReadCloser) *StreamReader {
	return &StreamReader{
		body:   r,
		reader: bufio.NewReader(r),
	}
}
