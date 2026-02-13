export class JobbieClient {
    constructor(baseURL, fetchImpl = fetch) {
        this.baseURL = baseURL.replace(/\/$/, "");
        this.fetchImpl = fetchImpl;
    }
    async enqueue(queue, payload, extra = {}) {
        return this.request("/api/v1/enqueue", {
            method: "POST",
            body: JSON.stringify({ queue, payload, ...extra }),
        });
    }
    async getJob(id) {
        return this.request(`/api/v1/jobs/${encodeURIComponent(id)}`, { method: "GET" });
    }
    async search(filter) {
        return this.request("/api/v1/jobs/search", {
            method: "POST",
            body: JSON.stringify(filter),
        });
    }
    async bulk(req) {
        return this.request("/api/v1/jobs/bulk", {
            method: "POST",
            body: JSON.stringify(req),
        });
    }
    async bulkStatus(id) {
        return this.request(`/api/v1/bulk/${encodeURIComponent(id)}`, { method: "GET" });
    }
    async ack(jobID, body = {}) {
        return this.request(`/api/v1/ack/${encodeURIComponent(jobID)}`, {
            method: "POST",
            body: JSON.stringify(body),
        });
    }
    async request(path, init) {
        const res = await this.fetchImpl(this.baseURL + path, {
            ...init,
            headers: {
                "content-type": "application/json",
                ...(init.headers || {}),
            },
        });
        if (!res.ok) {
            let details = `HTTP ${res.status}`;
            try {
                const body = (await res.json());
                if (body.error)
                    details = body.error;
            }
            catch {
                // ignore decode errors for non-JSON responses
            }
            throw new Error(details);
        }
        if (res.status === 204) {
            return {};
        }
        return (await res.json());
    }
}
