# corvo-client (Rust)

Minimal Rust client for Corvo.

```rust
use corvo_client::CorvoClient;
use serde_json::json;

#[tokio::main]
async fn main() {
    let client = CorvoClient::new("http://localhost:8080");
    let enq = client.enqueue("emails.send", json!({"to": "user@example.com"})).await.unwrap();
    println!("job_id={}", enq.job_id);
}
```
