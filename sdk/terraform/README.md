# Terraform Provider (Scaffold)

This scaffold defines the Jobbie Terraform provider shape and starter resources.

Current scope:
- Provider configuration (`server_url`, `api_key`)
- Planned resources:
  - `jobbie_queue`
  - `jobbie_budget`
  - `jobbie_api_key`

This is a starter slice intended for incremental expansion.

## Example

```hcl
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
  api_key    = var.jobbie_api_key
}

resource "jobbie_queue" "emails" {
  name = "emails.send"
}
```
