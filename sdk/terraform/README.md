# Terraform Provider (Scaffold)

This scaffold defines the Corvo Terraform provider shape and starter resources.

Current scope:
- Provider configuration (`server_url`, `api_key`)
- Planned resources:
  - `corvo_queue`
  - `corvo_budget`
  - `corvo_api_key`

This is a starter slice intended for incremental expansion.

## Example

```hcl
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
  api_key    = var.corvo_api_key
}

resource "corvo_queue" "emails" {
  name = "emails.send"
}
```
