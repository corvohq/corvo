package search

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var (
	rePathCmp    = regexp.MustCompile(`^\.(\w+(?:\.\w+)*)\s*(==|!=|>=|<=|>|<)\s*(.+)$`)
	reStartsWith = regexp.MustCompile(`^\.(\w+(?:\.\w+)*)\s*\|\s*startswith\(\s*"([^"]*)"\s*\)$`)
	reContains   = regexp.MustCompile(`^\.(\w+(?:\.\w+)*)\s*\|\s*contains\(\s*"([^"]*)"\s*\)$`)
	reLengthCmp  = regexp.MustCompile(`^\.(\w+(?:\.\w+)*)\s*\|\s*length\s*(==|!=|>=|<=|>|<)\s*([0-9]+)$`)
)

func translatePayloadJQ(expr string) (string, []any, error) {
	expr = strings.TrimSpace(expr)
	if expr == "" {
		return "", nil, fmt.Errorf("payload_jq is empty")
	}

	if m := reStartsWith.FindStringSubmatch(expr); len(m) == 3 {
		path := "$." + m[1]
		prefix := m[2]
		return "CAST(json_extract(j.payload, ?) AS TEXT) LIKE ? || '%'", []any{path, prefix}, nil
	}
	if m := reContains.FindStringSubmatch(expr); len(m) == 3 {
		path := "$." + m[1]
		val := m[2]
		return "EXISTS (SELECT 1 FROM json_each(json_extract(j.payload, ?)) WHERE CAST(value AS TEXT) = ?)", []any{path, val}, nil
	}
	if m := reLengthCmp.FindStringSubmatch(expr); len(m) == 4 {
		path := "$." + m[1]
		op := m[2]
		n, _ := strconv.Atoi(m[3])
		return fmt.Sprintf("COALESCE(json_array_length(json_extract(j.payload, ?)), 0) %s ?", op), []any{path, n}, nil
	}
	if m := rePathCmp.FindStringSubmatch(expr); len(m) == 4 {
		path := "$." + m[1]
		op := m[2]
		raw := strings.TrimSpace(m[3])
		value, valueType, err := parsePayloadJQLiteral(raw)
		if err != nil {
			return "", nil, err
		}
		switch valueType {
		case "number":
			return fmt.Sprintf("CAST(json_extract(j.payload, ?) AS REAL) %s ?", op), []any{path, value}, nil
		case "string":
			return fmt.Sprintf("CAST(json_extract(j.payload, ?) AS TEXT) %s ?", op), []any{path, value}, nil
		case "bool":
			// SQLite JSON booleans materialize as 0/1.
			return fmt.Sprintf("CAST(json_extract(j.payload, ?) AS INTEGER) %s ?", op), []any{path, value}, nil
		case "null":
			if op == "==" {
				return "json_extract(j.payload, ?) IS NULL", []any{path}, nil
			}
			if op == "!=" {
				return "json_extract(j.payload, ?) IS NOT NULL", []any{path}, nil
			}
			return "", nil, fmt.Errorf("payload_jq null only supports == and !=")
		default:
			return "", nil, fmt.Errorf("unsupported payload_jq literal type")
		}
	}

	return "", nil, fmt.Errorf("unsupported payload_jq expression")
}

func parsePayloadJQLiteral(raw string) (any, string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "null" {
		return nil, "null", nil
	}
	if raw == "true" {
		return 1, "bool", nil
	}
	if raw == "false" {
		return 0, "bool", nil
	}
	if strings.HasPrefix(raw, "\"") && strings.HasSuffix(raw, "\"") {
		var out string
		if err := json.Unmarshal([]byte(raw), &out); err != nil {
			return nil, "", fmt.Errorf("invalid payload_jq string literal: %w", err)
		}
		return out, "string", nil
	}
	if n, err := strconv.ParseFloat(raw, 64); err == nil {
		return n, "number", nil
	}
	return nil, "", fmt.Errorf("invalid payload_jq literal: %q", raw)
}
