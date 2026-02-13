export type EnqueueResult = {
    job_id: string;
    status: string;
    unique_existing?: boolean;
};
export type SearchFilter = {
    queue?: string;
    state?: string[];
    priority?: string;
    tags?: Record<string, string>;
    payload_contains?: string;
    payload_jq?: string;
    sort?: string;
    order?: "asc" | "desc";
    limit?: number;
    cursor?: string;
};
export type SearchResult<T = Record<string, unknown>> = {
    jobs: T[];
    total: number;
    cursor?: string;
    has_more: boolean;
};
export type BulkRequest = {
    job_ids?: string[];
    filter?: SearchFilter;
    action: "retry" | "delete" | "cancel" | "move" | "requeue" | "change_priority" | "hold" | "approve" | "reject";
    move_to_queue?: string;
    priority?: string;
    async?: boolean;
};
export type BulkResult = {
    affected: number;
    errors: number;
    duration_ms: number;
};
export type BulkAsyncStart = {
    bulk_operation_id: string;
    status: string;
    estimated_total: number;
    progress_url: string;
};
export type BulkTask = {
    id: string;
    status: "queued" | "running" | "completed" | "failed";
    action: string;
    total: number;
    processed: number;
    affected: number;
    errors: number;
    error?: string;
    created_at: string;
    updated_at: string;
    finished_at?: string;
};
export declare class JobbieClient {
    readonly baseURL: string;
    readonly fetchImpl: typeof fetch;
    constructor(baseURL: string, fetchImpl?: typeof fetch);
    enqueue(queue: string, payload: unknown, extra?: Record<string, unknown>): Promise<EnqueueResult>;
    getJob<T = Record<string, unknown>>(id: string): Promise<T>;
    search<T = Record<string, unknown>>(filter: SearchFilter): Promise<SearchResult<T>>;
    bulk(req: BulkRequest): Promise<BulkResult | BulkAsyncStart>;
    bulkStatus(id: string): Promise<BulkTask>;
    ack(jobID: string, body?: Record<string, unknown>): Promise<{
        status: string;
    }>;
    private request;
}
