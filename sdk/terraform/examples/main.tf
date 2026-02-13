terraform {
  required_providers {
    jobbie = {
      source  = "local/jobbie"
      version = "0.1.0"
    }
  }
}

provider "jobbie" {
  server_url = "http://localhost:8080"
  api_key    = "change-me"
}

resource "jobbie_queue" "emails" {
  name = "emails.send"
}

resource "jobbie_budget" "emails_budget" {
  scope       = "queue"
  target      = "emails.send"
  daily_usd   = 50
  per_job_usd = 0.1
  on_exceed   = "hold"
}
