terraform {
  required_providers {
    corvo = {
      source  = "local/corvo"
      version = "0.1.0"
    }
  }
}

provider "corvo" {
  server_url = "http://localhost:8080"
  api_key    = "change-me"
}

resource "corvo_queue" "emails" {
  name = "emails.send"
}

resource "corvo_budget" "emails_budget" {
  scope       = "queue"
  target      = "emails.send"
  daily_usd   = 50
  per_job_usd = 0.1
  on_exceed   = "hold"
}
