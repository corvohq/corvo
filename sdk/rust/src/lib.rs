use reqwest::header::{HeaderMap, HeaderName, HeaderValue, AUTHORIZATION};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::str::FromStr;

#[derive(thiserror::Error, Debug)]
pub enum JobbieError {
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
pub struct JobbieClient {
    base_url: String,
    http: reqwest::Client,
    auth: AuthOptions,
}

#[derive(Serialize)]
struct EnqueueReq {
    queue: String,
    payload: Value,
}

#[derive(Debug, Deserialize)]
pub struct EnqueueResult {
    pub job_id: String,
    pub status: String,
    pub unique_existing: Option<bool>,
}

impl JobbieClient {
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

    pub async fn enqueue(&self, queue: &str, payload: Value) -> Result<EnqueueResult, JobbieError> {
        let req = EnqueueReq {
            queue: queue.to_string(),
            payload,
        };
        self.request::<EnqueueResult>(reqwest::Method::POST, "/api/v1/enqueue", Some(req)).await
    }

    pub async fn get_job(&self, job_id: &str) -> Result<Value, JobbieError> {
        self.request::<Value>(reqwest::Method::GET, &format!("/api/v1/jobs/{job_id}"), Option::<Value>::None)
            .await
    }

    async fn request<T: for<'de> Deserialize<'de>, B: Serialize>(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<B>,
    ) -> Result<T, JobbieError> {
        let mut headers = HeaderMap::new();
        for (k, v) in &self.auth.headers {
            headers.insert(
                HeaderName::from_str(k).map_err(|e| JobbieError::Api(e.to_string()))?,
                HeaderValue::from_str(v).map_err(|e| JobbieError::Api(e.to_string()))?,
            );
        }
        if let Some(key) = &self.auth.api_key {
            let h = self
                .auth
                .api_key_header
                .clone()
                .unwrap_or_else(|| "X-API-Key".to_string());
            headers.insert(
                HeaderName::from_str(&h).map_err(|e| JobbieError::Api(e.to_string()))?,
                HeaderValue::from_str(key).map_err(|e| JobbieError::Api(e.to_string()))?,
            );
        }
        if let Some(token) = &self.auth.bearer_token {
            headers.insert(
                AUTHORIZATION,
                HeaderValue::from_str(&format!("Bearer {token}"))
                    .map_err(|e| JobbieError::Api(e.to_string()))?,
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
            return Err(JobbieError::Api(msg));
        }
        Ok(resp.json().await?)
    }
}
