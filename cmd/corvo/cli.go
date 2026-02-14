package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"

	"github.com/spf13/cobra"
)

var (
	serverURL  string
	outputJSON bool
)

func addClientFlags(cmds ...*cobra.Command) {
	for _, cmd := range cmds {
		cmd.Flags().StringVar(&serverURL, "server", "http://localhost:8080", "Corvo server URL")
		cmd.Flags().BoolVar(&outputJSON, "output-json", false, "Output as JSON")
	}
}

func apiRequest(method, path string, body interface{}) ([]byte, int, error) {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, 0, err
		}
		reader = bytes.NewReader(b)
	}

	req, err := http.NewRequest(method, serverURL+path, reader)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, resp.StatusCode, err
	}
	return data, resp.StatusCode, nil
}

func printJSON(data []byte) {
	var buf bytes.Buffer
	json.Indent(&buf, data, "", "  ")
	fmt.Fprintln(os.Stdout, buf.String())
}

func exitOnError(data []byte, status int) {
	if status >= 400 {
		var errResp map[string]string
		json.Unmarshal(data, &errResp)
		if msg, ok := errResp["error"]; ok {
			fmt.Fprintf(os.Stderr, "Error: %s\n", msg)
		} else {
			fmt.Fprintf(os.Stderr, "Error: %s\n", string(data))
		}
		os.Exit(1)
	}
}
