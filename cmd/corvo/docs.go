// Package main is the entry point for the Corvo server.
//
// @title Corvo API
// @version v1
// @description Corvo is a distributed background job queue. All endpoints are under `/api/v1`. Authentication via `X-API-Key` header or `Authorization: Bearer` token.
// @contact.url https://corvohq.com
// @host localhost:8080
// @BasePath /api/v1
// @schemes http https
// @securityDefinitions.apikey ApiKeyAuth
// @in header
// @name X-API-Key
// @securityDefinitions.apikey BearerAuth
// @in header
// @name Authorization
// @description Bearer token: `Authorization: Bearer <token>`
// @security ApiKeyAuth
package main
