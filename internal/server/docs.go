package server

import (
	_ "embed"
	"net/http"
)

//go:generate swag init -g docs.go -d ../../cmd/corvo,.,../store,../search -o ./openapi --outputTypes json

//go:embed openapi/swagger.json
var openapiSpec []byte

func (s *Server) handleOpenAPISpec(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=300")
	w.Write(openapiSpec)
}

func (s *Server) handleDocs(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.Write([]byte(scalarHTML))
}

const scalarHTML = `<!doctype html>
<html lang="en">
<head>
  <title>Corvo API Reference</title>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <style>body { margin: 0; }</style>
</head>
<body>
  <script id="api-reference" data-url="/openapi.json"></script>
  <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
</body>
</html>`
