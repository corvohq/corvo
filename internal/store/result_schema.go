package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/xeipuuv/gojsonschema"
)

type ValidationErrorItem struct {
	Path    string `json:"path"`
	Message string `json:"message"`
	Value   any    `json:"value,omitempty"`
}

type ResultSchemaValidationError struct {
	JobID   string                `json:"job_id"`
	Errors  []ValidationErrorItem `json:"validation_errors"`
	Message string                `json:"error"`
}

func (e *ResultSchemaValidationError) Error() string {
	if strings.TrimSpace(e.Message) != "" {
		return e.Message
	}
	return "result_schema_validation_failed"
}

func IsResultSchemaValidationError(err error) bool {
	_, ok := err.(*ResultSchemaValidationError)
	return ok
}

func AsResultSchemaValidationError(err error) (*ResultSchemaValidationError, bool) {
	out, ok := err.(*ResultSchemaValidationError)
	return out, ok
}

func (s *Store) validateAckResultSchema(jobID string, result json.RawMessage) error {
	if strings.TrimSpace(jobID) == "" {
		return nil
	}
	var schemaRaw sql.NullString
	err := s.sqliteR.QueryRow("SELECT result_schema FROM jobs WHERE id = ?", jobID).Scan(&schemaRaw)
	if err != nil {
		if err == sql.ErrNoRows {
			return fmt.Errorf("job %s not found", jobID)
		}
		return err
	}
	if !schemaRaw.Valid || strings.TrimSpace(schemaRaw.String) == "" {
		return nil
	}

	resultJSON := strings.TrimSpace(string(result))
	if resultJSON == "" {
		resultJSON = "null"
	}
	schemaLoader := gojsonschema.NewStringLoader(schemaRaw.String)
	docLoader := gojsonschema.NewStringLoader(resultJSON)
	res, err := gojsonschema.Validate(schemaLoader, docLoader)
	if err != nil {
		return fmt.Errorf("validate result schema: %w", err)
	}
	if res.Valid() {
		return nil
	}
	items := make([]ValidationErrorItem, 0, len(res.Errors()))
	for _, item := range res.Errors() {
		items = append(items, ValidationErrorItem{
			Path:    item.Field(),
			Message: item.Description(),
			Value:   item.Value(),
		})
	}
	return &ResultSchemaValidationError{
		JobID:   jobID,
		Errors:  items,
		Message: "result_schema_validation_failed",
	}
}

func validateResultSchemaDoc(schema json.RawMessage) error {
	if strings.TrimSpace(string(schema)) == "" {
		return nil
	}
	loader := gojsonschema.NewStringLoader(strings.TrimSpace(string(schema)))
	if _, err := gojsonschema.NewSchema(loader); err != nil {
		return fmt.Errorf("invalid result_schema: %w", err)
	}
	return nil
}
