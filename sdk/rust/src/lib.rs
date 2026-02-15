use reqwest::header::{HeaderMap, HeaderName, HeaderValue, AUTHORIZATION};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::str::FromStr;

#[derive(thiserror::Error, Debug)]
pub enum CorvoError {
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("api error: {0}")]
    Api(String),
}

#[derive(Clone, Debug, Default)]
pub struct AuthOptions {
    pub headers: Vec<(String, String)>,
    pub bearer_token: Option<String>,
    pub api_key: Option<String>,
    pub api_key_header: Option<String>,
}

#[derive(Clone)]
pub struct CorvoClient {
    base_url: String,
    http: reqwest::Client,
    auth: AuthOptions,
}

// --- Request / Response types ---

#[derive(Debug, Default, Serialize)]
pub struct EnqueueOptions {
    pub queue: String,
    pub payload: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unique_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unique_period: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_retries: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scheduled_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expire_after: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chain: Option<ChainConfig>,
}

#[derive(Debug, Serialize, Clone)]
pub struct ChainConfig {
    pub steps: Vec<ChainStep>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_failure: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_exit: Option<ChainStep>,
}

#[derive(Debug, Serialize, Clone)]
pub struct ChainStep {
    pub queue: String,
    pub payload: Value,
}

#[derive(Debug, Deserialize)]
pub struct EnqueueResult {
    pub job_id: String,
    pub status: String,
    pub unique_existing: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct BatchJob {
    pub queue: String,
    pub payload: Value,
}

#[derive(Debug, Serialize)]
pub struct BatchConfig {
    pub callback_queue: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub callback_payload: Option<Value>,
}

#[derive(Debug, Serialize)]
struct BatchRequest {
    jobs: Vec<BatchJob>,
    #[serde(skip_serializing_if = "Option::is_none")]
    batch: Option<BatchConfig>,
}

#[derive(Debug, Deserialize)]
pub struct BatchResult {
    pub job_ids: Vec<String>,
    pub batch_id: String,
}

#[derive(Debug, Serialize)]
struct FetchRequest {
    queues: Vec<String>,
    worker_id: String,
    hostname: String,
    timeout: u64,
}

#[derive(Debug, Deserialize)]
pub struct FetchedJob {
    pub job_id: String,
    pub queue: String,
    pub payload: Value,
    pub attempt: u32,
}

#[derive(Debug, Serialize)]
struct FetchBatchRequest {
    queues: Vec<String>,
    worker_id: String,
    hostname: String,
    timeout: u64,
    count: u32,
}

#[derive(Debug, Deserialize)]
pub struct FetchBatchResult {
    pub jobs: Vec<FetchedJob>,
}

#[derive(Debug, Serialize)]
pub struct AckBatchItem {
    pub job_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
}

#[derive(Debug, Deserialize)]
pub struct AckBatchResult {
    pub acked: u64,
}

#[derive(Debug, Default, Serialize)]
pub struct AckBody {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub step_status: Option<String>,
}

#[derive(Debug, Serialize)]
struct FailRequest {
    error: String,
    backtrace: String,
}

#[derive(Debug, Deserialize)]
pub struct FailResult {
    pub status: String,
    pub attempt: Option<u32>,
}

#[derive(Debug, Default, Serialize)]
pub struct HeartbeatEntry {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checkpoint: Option<Value>,
}

#[derive(Debug, Deserialize)]
pub struct HeartbeatResult {
    pub acked: Vec<String>,
    pub unknown: Vec<String>,
    pub canceled: Vec<String>,
}

#[derive(Debug, Default, Serialize)]
pub struct SearchFilter {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub queue: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payload_contains: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SearchResult {
    pub jobs: Vec<Value>,
    pub total: u64,
    pub cursor: Option<String>,
    pub has_more: bool,
}

#[derive(Debug, Serialize)]
pub struct BulkRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filter: Option<SearchFilter>,
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub move_to_queue: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
    #[serde(rename = "async", skip_serializing_if = "Option::is_none")]
    pub async_op: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct BulkResult {
    pub affected: Option<u64>,
    pub errors: Option<u64>,
    pub duration_ms: Option<f64>,
    pub bulk_operation_id: Option<String>,
    pub status: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct BulkTask {
    pub id: String,
    pub status: String,
    pub action: String,
    pub total: u64,
    pub processed: u64,
    pub affected: u64,
    pub errors: u64,
    pub error: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub finished_at: Option<String>,
}

// --- Client implementation ---

impl CorvoClient {
    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            http: reqwest::Client::new(),
            auth: AuthOptions::default(),
        }
    }

    pub fn with_auth(mut self, auth: AuthOptions) -> Self {
        self.auth = auth;
        self
    }

    // -- Producer --

    pub async fn enqueue(&self, queue: &str, payload: Value) -> Result<EnqueueResult, CorvoError> {
        let opts = EnqueueOptions {
            queue: queue.to_string(),
            payload,
            ..Default::default()
        };
        self.enqueue_with(opts).await
    }

    pub async fn enqueue_with(&self, opts: EnqueueOptions) -> Result<EnqueueResult, CorvoError> {
        self.post("/api/v1/enqueue", &opts).await
    }

    pub async fn enqueue_batch(
        &self,
        jobs: Vec<BatchJob>,
        batch: Option<BatchConfig>,
    ) -> Result<BatchResult, CorvoError> {
        self.post("/api/v1/enqueue/batch", &BatchRequest { jobs, batch }).await
    }

    // -- Batch fetch / ack --

    pub async fn fetch_batch(
        &self,
        queues: Vec<String>,
        worker_id: &str,
        hostname: &str,
        timeout: u64,
        count: u32,
    ) -> Result<FetchBatchResult, CorvoError> {
        self.post(
            "/api/v1/fetch/batch",
            &FetchBatchRequest {
                queues,
                worker_id: worker_id.to_string(),
                hostname: hostname.to_string(),
                timeout,
                count,
            },
        )
        .await
    }

    pub async fn ack_batch(
        &self,
        acks: Vec<AckBatchItem>,
    ) -> Result<AckBatchResult, CorvoError> {
        #[derive(Serialize)]
        struct Req {
            acks: Vec<AckBatchItem>,
        }
        self.post("/api/v1/ack/batch", &Req { acks }).await
    }

    // -- Worker lifecycle --

    pub async fn fetch(
        &self,
        queues: Vec<String>,
        worker_id: &str,
        hostname: &str,
        timeout: u64,
    ) -> Result<Option<FetchedJob>, CorvoError> {
        let req = FetchRequest {
            queues,
            worker_id: worker_id.to_string(),
            hostname: hostname.to_string(),
            timeout,
        };
        let result: FetchedJob = self.post("/api/v1/fetch", &req).await?;
        if result.job_id.is_empty() {
            return Ok(None);
        }
        Ok(Some(result))
    }

    pub async fn ack(&self, job_id: &str, body: AckBody) -> Result<Value, CorvoError> {
        self.post(&format!("/api/v1/ack/{job_id}"), &body).await
    }

    pub async fn fail(
        &self,
        job_id: &str,
        error: &str,
        backtrace: &str,
    ) -> Result<FailResult, CorvoError> {
        self.post(
            &format!("/api/v1/fail/{job_id}"),
            &FailRequest {
                error: error.to_string(),
                backtrace: backtrace.to_string(),
            },
        )
        .await
    }

    pub async fn heartbeat(
        &self,
        jobs: HashMap<String, HeartbeatEntry>,
    ) -> Result<HeartbeatResult, CorvoError> {
        #[derive(Serialize)]
        struct Req {
            jobs: HashMap<String, HeartbeatEntry>,
        }
        self.post("/api/v1/heartbeat", &Req { jobs }).await
    }

    // -- Job management --

    pub async fn get_job(&self, job_id: &str) -> Result<Value, CorvoError> {
        self.request::<Value, Value>(reqwest::Method::GET, &format!("/api/v1/jobs/{job_id}"), None)
            .await
    }

    pub async fn retry_job(&self, job_id: &str) -> Result<Value, CorvoError> {
        self.post_empty(&format!("/api/v1/jobs/{job_id}/retry")).await
    }

    pub async fn cancel_job(&self, job_id: &str) -> Result<Value, CorvoError> {
        self.post_empty(&format!("/api/v1/jobs/{job_id}/cancel")).await
    }

    pub async fn move_job(&self, job_id: &str, target_queue: &str) -> Result<Value, CorvoError> {
        #[derive(Serialize)]
        struct Req {
            queue: String,
        }
        self.post(
            &format!("/api/v1/jobs/{job_id}/move"),
            &Req {
                queue: target_queue.to_string(),
            },
        )
        .await
    }

    pub async fn delete_job(&self, job_id: &str) -> Result<Value, CorvoError> {
        self.request::<Value, Value>(
            reqwest::Method::DELETE,
            &format!("/api/v1/jobs/{job_id}"),
            None,
        )
        .await
    }

    // -- Search & bulk --

    pub async fn search(&self, filter: SearchFilter) -> Result<SearchResult, CorvoError> {
        self.post("/api/v1/jobs/search", &filter).await
    }

    pub async fn bulk(&self, req: BulkRequest) -> Result<BulkResult, CorvoError> {
        self.post("/api/v1/jobs/bulk", &req).await
    }

    pub async fn bulk_status(&self, id: &str) -> Result<BulkTask, CorvoError> {
        self.request::<BulkTask, Value>(reqwest::Method::GET, &format!("/api/v1/bulk/{id}"), None)
            .await
    }

    // -- Internal helpers --

    async fn post<T: for<'de> Deserialize<'de>, B: Serialize>(
        &self,
        path: &str,
        body: &B,
    ) -> Result<T, CorvoError> {
        self.request(reqwest::Method::POST, path, Some(body)).await
    }

    async fn post_empty<T: for<'de> Deserialize<'de>>(
        &self,
        path: &str,
    ) -> Result<T, CorvoError> {
        self.request::<T, Value>(reqwest::Method::POST, path, None).await
    }

    async fn request<T: for<'de> Deserialize<'de>, B: Serialize>(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<B>,
    ) -> Result<T, CorvoError> {
        let mut headers = HeaderMap::new();
        for (k, v) in &self.auth.headers {
            headers.insert(
                HeaderName::from_str(k).map_err(|e| CorvoError::Api(e.to_string()))?,
                HeaderValue::from_str(v).map_err(|e| CorvoError::Api(e.to_string()))?,
            );
        }
        if let Some(key) = &self.auth.api_key {
            let h = self
                .auth
                .api_key_header
                .clone()
                .unwrap_or_else(|| "X-API-Key".to_string());
            headers.insert(
                HeaderName::from_str(&h).map_err(|e| CorvoError::Api(e.to_string()))?,
                HeaderValue::from_str(key).map_err(|e| CorvoError::Api(e.to_string()))?,
            );
        }
        if let Some(token) = &self.auth.bearer_token {
            headers.insert(
                AUTHORIZATION,
                HeaderValue::from_str(&format!("Bearer {token}"))
                    .map_err(|e| CorvoError::Api(e.to_string()))?,
            );
        }

        let mut req = self
            .http
            .request(method, format!("{}{}", self.base_url, path))
            .headers(headers);
        if let Some(b) = body {
            req = req.json(&b);
        }
        let resp = req.send().await?;
        if !resp.status().is_success() {
            let body: Value = resp.json().await.unwrap_or(Value::Null);
            let msg = body
                .get("error")
                .and_then(|v| v.as_str())
                .unwrap_or("request failed")
                .to_string();
            return Err(CorvoError::Api(msg));
        }
        Ok(resp.json().await?)
    }
}
