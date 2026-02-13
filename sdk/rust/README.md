# jobbie-client (Rust)

Minimal Rust client for Jobbie.

```rust
use jobbie_client::JobbieClient;
use serde_json::json;

#[tokio::main]
async fn main() {
    let client = JobbieClient::new("http://localhost:8080");
    let enq = client.enqueue("emails.send", json!({"to": "user@example.com"})).await.unwrap();
    println!("job_id={}", enq.job_id);
}
```
