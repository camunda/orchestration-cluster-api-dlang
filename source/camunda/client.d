/// The primary entry point of the SDK.
module camunda.client;

@safe:

import camunda.auth;
import camunda.backpressure;
import camunda.clock;
import camunda.config;
import camunda.errors;
import camunda.eventual;
import camunda.generated;
import camunda.jsonx;
import camunda.http : HttpResponse;
import camunda.multipart;
import camunda.safeio : readBytes;
import camunda.transport;
import camunda.version_ : sdkUserAgent, sdkVersion;
import camunda.worker;
import std.json;
import std.path : baseName;

public import camunda.transport : CamundaOptions;

/// The Camunda 8 Orchestration Cluster SDK — synchronous client.
///
/// Mixes in the generated flat facade (`GeneratedOperations`) so every REST
/// operation is a method on this type. Curated helpers (`topology`,
/// `deployResources`, `createJobWorker`, `eventual`) sit on top.
final class CamundaClient
{
    mixin GeneratedOperations;

    private Transport _t;

    this(CamundaOptions options)
    {
        _t = new Transport(options);
    }

    static CamundaClient fromEnv()
    {
        return new CamundaClient(CamundaOptions.create);
    }

    static CamundaClient fromEnv(string[string] overrides)
    {
        CamundaOptions o;
        o.config = overrides;
        return new CamundaClient(o);
    }

    static CamundaClient create(CamundaOptions options)
    {
        return new CamundaClient(options);
    }

    /// The shared transport (also usable on its own via `camunda.runtime`).
    Transport transport() { return _t; }
    const(CamundaConfig) config() const { return _t.config; }
    Clock clock() { return _t.clock; }
    Authentication auth() { return _t.auth; }
    BackpressureState backpressureState() const { return _t.backpressureState; }

    /// Fetch the cluster topology.
    TopologyResponse topology()
    {
        return getTopologyOp();
    }

    /// Deploy one or more resources (BPMN, DMN, forms) from local file paths.
    DeploymentResult deployResources(string[] paths, string tenantId = null)
    {
        if (!paths.length)
            throw new ConfigException("deployResources() requires at least one file path.");
        auto tenant = tenantId.length ? tenantId
            : (config.defaultTenantId.length ? config.defaultTenantId : null);
        return createDeploymentMultipart(paths, tenant);
    }

    /// `body_` with the configured default tenant (`CAMUNDA_DEFAULT_TENANT_ID`)
    /// as `tenantId`, unless it is already set. Applied by the generated
    /// operations whose request has an optional `tenantId`.
    JSONValue withDefaultTenant(JSONValue body_)
    {
        const tenant = config.defaultTenantId;
        if (!tenant.length || body_.type != JSONType.object) return body_;
        if (auto t = "tenantId" in body_.objectNoRef)
            if (t.type != JSONType.null_) return body_;
        JSONValue copy = emptyObject();
        foreach (k, v; body_.objectNoRef) copy[k] = v;
        copy["tenantId"] = tenant;
        return copy;
    }

    /// A file to upload with `createDocuments` (bytes already in memory).
    static struct DocumentUpload
    {
        string fileName;
        const(ubyte)[] bytes;
        /// MIME type; guessed from `fileName` when empty.
        string contentType;
        /// Optional per-document metadata (`metadataList[i]`).
        DocumentMetadata metadata;
    }

    /// Upload a document from a local file (`POST /documents`, multipart `file`).
    /// `contentType` is guessed from the extension when empty.
    DocumentReference createDocument(string path, string contentType = null, string storeId = null,
        string documentId = null, DocumentMetadata metadata = DocumentMetadata.init)
    {
        return createDocument(readBytes(path), baseName(path), contentType, storeId, documentId, metadata);
    }

    /// Upload a document from memory (`POST /documents`, multipart `file`).
    DocumentReference createDocument(const(ubyte)[] bytes, string fileName, string contentType = null,
        string storeId = null, string documentId = null, DocumentMetadata metadata = DocumentMetadata.init)
    {
        auto m = Multipart.create();
        m.addFile("file", fileName, contentType.length ? contentType : mimeTypeFor(fileName), bytes);
        if (metadata.raw.type != JSONType.null_) m.addField("metadata", metadata.toJson().toString, "application/json");
        string[string] query;
        if (storeId.length) query["storeId"] = storeId;
        if (documentId.length) query["documentId"] = documentId;
        auto res = _t.requestRaw("POST", "/documents", m.contentType, m.body_, ServerBase.api, query);
        return parseMultipartResult!DocumentReference(res, "document");
    }

    /// Upload several local files in one request (`POST /documents/batch`, multipart `files`).
    DocumentCreationBatchResponse createDocuments(string[] paths, string storeId = null)
    {
        DocumentUpload[] uploads;
        foreach (p; paths) uploads ~= DocumentUpload(baseName(p), readBytes(p));
        return createDocuments(uploads, storeId);
    }

    /// Upload several documents in one request. A partial failure is a 207 with
    /// `failedDocuments` set in the response, not an exception.
    DocumentCreationBatchResponse createDocuments(DocumentUpload[] uploads, string storeId = null)
    {
        if (!uploads.length)
            throw new ConfigException("createDocuments() requires at least one document.");
        auto m = Multipart.create();
        bool anyMetadata;
        foreach (u; uploads)
        {
            m.addFile("files", u.fileName, u.contentType.length ? u.contentType : mimeTypeFor(u.fileName), u.bytes);
            anyMetadata = anyMetadata || u.metadata.raw.type != JSONType.null_;
        }
        if (anyMetadata)
        {
            JSONValue[] list;
            foreach (u; uploads) list ~= u.metadata.raw.type != JSONType.null_ ? u.metadata.toJson() : emptyObject();
            m.addField("metadataList", JSONValue(list).toString, "application/json");
        }
        string[string] query;
        if (storeId.length) query["storeId"] = storeId;
        auto res = _t.requestRaw("POST", "/documents/batch", m.contentType, m.body_, ServerBase.api, query);
        return parseMultipartResult!DocumentCreationBatchResponse(res, "document batch");
    }

    /// Poll `op` until it succeeds (retrying 404s) or the timeout elapses.
    T eventual(T)(ConsistencyOptions opts, scope T delegate() @safe op)
    {
        return poll!T(opts, config.eventualPollDefaultMs, _t.clock, op, (const T) => true);
    }

    /// Poll `op` until `predicate` is true.
    T eventual(T)(ConsistencyOptions opts, scope T delegate() @safe op,
        scope bool delegate(const T) @safe predicate)
    {
        return poll!T(opts, config.eventualPollDefaultMs, _t.clock, op, predicate);
    }

    JobWorker createJobWorker(JobWorkerConfig cfg)
    {
        cfg.applyDefaults(config.workerDefaults);
        if (!cfg.tenantIds.length && config.tenantIds.length)
            cfg.tenantIds = config.tenantIds.dup;
        return new JobWorker(this, cfg);
    }

    JobWorkerConfig workerConfig(string jobType)
    {
        return JobWorkerConfig.fromDefaults(jobType, config.workerDefaults);
    }

    // --- transport used by the generated facade --------------------------------

    JSONValue requestJson(string method, string path, JSONValue body_, string[string] query,
        ServerBase server = ServerBase.api)
    {
        return _t.requestJson(method, path, body_, query, server);
    }

    void requestVoid(string method, string path, JSONValue body_, string[string] query,
        ServerBase server = ServerBase.api)
    {
        _t.requestVoid(method, path, body_, query, server);
    }

    string requestText(string method, string path, JSONValue body_, string[string] query,
        ServerBase server = ServerBase.api)
    {
        return _t.requestText(method, path, body_, query, server);
    }

    immutable(ubyte)[] requestBytes(string method, string path, JSONValue body_, string[string] query,
        ServerBase server = ServerBase.api)
    {
        return _t.requestBytes(method, path, body_, query, server);
    }

    private DeploymentResult createDeploymentMultipart(string[] paths, string tenantId)
    {
        // Each file is a `resources` part; tenantId is a plain field.
        auto m = Multipart.create();
        foreach (p; paths) m.addFile("resources", baseName(p), "application/octet-stream", readBytes(p));
        if (tenantId.length) m.addField("tenantId", tenantId);
        auto res = _t.requestRaw("POST", "/deployments", m.contentType, m.body_);
        return parseMultipartResult!DeploymentResult(res, "deployment");
    }

    private static T parseMultipartResult(T)(HttpResponse res, string what)
    {
        try return T.fromJson(res.body_.length ? parseJSON(res.body_) : emptyObject());
        catch (Exception e)
            throw new SerializationException("failed to parse " ~ what ~ " response: " ~ e.msg, __FILE__, __LINE__, e);
    }
}

unittest
{
    auto c = CamundaClient.create(CamundaOptions.create
        .withKey("CAMUNDA_REST_ADDRESS", "http://localhost:8080")
        .withKey("CAMUNDA_AUTH_STRATEGY", "NONE"));
    assert(c.config.restAddress == "http://localhost:8080/v2");
    assert(c.config.authStrategy == AuthStrategy.none);
    assert(sdkVersion.length > 0);
    assert(sdkUserAgent.length > "camunda-orchestration-sdk-d/".length);
}

unittest
{
    // The generated facade covers the bundled spec (per-operation coverage is
    // gated by scripts/check-example-coverage.py; the count moves with upstream).
    assert(generatedOperationCount > 200);
    assert(generatedSpecHash.length > 0);
}

unittest
{
    auto key = JobKey.tryNew("2251799813653498");
    assert(key.value == "2251799813653498");
    assert(JobKey.isValid("2251799813653498"));
    assert(!JobKey.isValid("not-a-key"));
    bool threw;
    try JobKey.tryNew("nope");
    catch (CamundaKeyError) threw = true;
    assert(threw);
    auto loose = JobKey.assumeExists("anything");
    assert(loose.value == "anything");
}

unittest
{
    // #8: the default tenant fills an unset tenantId, never overrides one.
    auto c = CamundaClient.create(CamundaOptions.create
        .withKey("CAMUNDA_AUTH_STRATEGY", "NONE")
        .withKey("CAMUNDA_DEFAULT_TENANT_ID", "t1"));
    JSONValue b = parseJSON(`{"name":"m"}`);
    assert(c.withDefaultTenant(b)["tenantId"].str == "t1");
    assert("tenantId" !in b.objectNoRef); // caller's value untouched
    assert(c.withDefaultTenant(parseJSON(`{"tenantId":"mine"}`))["tenantId"].str == "mine");
    assert(c.withDefaultTenant(parseJSON(`{"tenantId":null}`))["tenantId"].str == "t1");
    auto none = CamundaClient.create(CamundaOptions.create.withKey("CAMUNDA_AUTH_STRATEGY", "NONE"));
    assert("tenantId" !in none.withDefaultTenant(parseJSON(`{"a":1}`)).objectNoRef);
}
