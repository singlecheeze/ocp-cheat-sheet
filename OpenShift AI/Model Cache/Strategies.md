# OpenShift AI 3.5: Model Caching Strategies
## Faster on-premises startup and inference

**Recommendation:** Prioritize node-local model caching for faster startup, and vLLM prefix caching for faster responses. Use the model registry to manage versions and artifact locations; registration alone does not accelerate inference.

This reference summarizes the OpenShift AI 3.5 documentation reviewed on October 12, 2026. Architecture recommendations are distinguished from documented product behavior.

## 1. Separate the two performance goals

| Goal | What to measure | Relevant strategies |
|---|---|---|
| Faster startup | Time from pod creation to a ready inference endpoint | Node-local Model Cache, prepopulated PVCs, ModelCar images, local artifact sources |
| Faster running inference | Time to first token, output tokens/second, request throughput | vLLM prefix caching and llm-d cache-aware routing |

Caching model files removes transfer work. It does not eliminate loading weights into GPU memory or runtime initialization.

## 2. Strategy comparison

| Strategy | What it stores or reuses | Main benefit | Main trade-off |
|---|---|---|---|
| **Node-local Model Cache** | Model files on selected serving nodes, ideally NVMe | Faster deployments, restarts, and scale-out | Each selected node needs enough disk capacity |
| **Prepopulated PVC** | Model files on persistent storage | Avoids repeated model downloads | Startup depends on backing-storage throughput and access modes |
| **OCI ModelCar images** | Model files packaged as container images | Reuses image distribution and node image caching | First pull is expensive; image cache can be reclaimed |
| **On-premises S3-compatible storage** | An authoritative local copy of model artifacts | Removes internet transfers from deployment | Pods may still download a copy at startup |
| **vLLM prefix caching** | Computed attention key/value state for repeated prompt prefixes | Reduces repeated prompt processing and time to first token | Depends on prefix reuse and cache capacity |
| **llm-d cache-aware routing** | Selects replicas likely to hold useful KV state | Improves prefix-cache reuse across replicas | Needs multiple replicas to offer routing choices |

References: [Model storage][storage], [node-local caching][cache-admin], [ModelCar implementation][oci], [vLLM arguments][vllm], and [llm-d routing][routing].

## 3. Node-local Model Cache

**Best fit:** Large models that are frequently deployed, restarted, or scaled across a known set of serving nodes.

OpenShift AI 3.5 can pre-download models to selected nodes and mount cached files into serving pods.

| Resource | Purpose |
|---|---|
| `LocalModelCache` | Shares a cached model across namespaces |
| `LocalModelNamespaceCache` | Limits cached-model use to one namespace |
| `LocalModelNodeGroup` | Defines target nodes and cache storage |
| `LocalModelNode` | Tracks download status for an individual node |

A cluster administrator enables the feature through `spec.components.kserve.modelCache` in the `DataScienceCluster`. It is disabled by default. Use actual local NVMe where possible: a local filesystem path alone does not guarantee fast storage.

**Serving integration:**

- `InferenceService` matches its `storageUri` to the cached source URI.
- `LLMInferenceService` matches `spec.model.uri` to the cached source URI.
- The URI must match the cached URI exactly or refer to a subdirectory.
- Precache before creating the serving resource and confirm all intended node copies are downloaded.

**Operational recommendation:** Cache on every node eligible to run the workload, budget for multiple model versions, and verify the mounted cache is used.

Documentation: [Configure local caching][cache-admin] · [Precache and deploy models][precache]

## 4. Prepopulated PVC

**Best fit:** A straightforward persistent model directory, especially where shared storage is already available.

Download the model once to a PVC, then serve from that storage. OpenShift AI supports existing PVCs; distributed inference documents the form `pvc://<claim-name>/<path>`.

| Storage choice | Practical consideration |
|---|---|
| Shared filesystem / RWX | Multiple nodes can access the files, but concurrent model loads compete for storage and network throughput |
| RWO volume | Check node attachment constraints before using it across replicas |
| Local persistent storage | Provides locality but ties the data to particular nodes |

**Recommendation:** Choose a PVC for simple persistent access; favor managed node-local caching when repeated large-model startups are the bottleneck. Benchmark the actual storage—“PVC” is not a performance tier.

Documentation: [Store models on existing PVCs][storage] · [Distributed inference storage and deployment][distributed]

## 5. OCI ModelCar images

**Best fit:** Organizations using an internal OCI registry, such as Quay, to distribute versioned artifacts.

ModelCar packages model files into an OCI image. KServe exposes the files through a modelcar container, allowing reuse of images already cached on the node.

**Operational recommendations:**

- Store ModelCar images in an on-premises OCI registry to avoid external transfers.
- Plan for large first pulls and sufficient node image-storage capacity.
- Use immutable versions or image digests for reproducibility.
- Treat image caching as reclaimable; it is not a guarantee that an image remains on every node.

This is an alternative artifact-distribution path to HF/S3-based node-local caching. Do not assume the two mechanisms automatically compose.

Documentation: [OpenShift AI model storage][storage] · [Upstream KServe OCI/ModelCar behavior][oci]

## 6. On-premises S3-compatible storage

**Best fit:** A central source for model directories that multiple deployments can consume.

An internal S3-compatible endpoint removes the internet from the model-transfer path. It is an artifact source, not automatically a node cache: without persistent reuse, serving pods can still download model files at startup.

**Recommended architecture:** Use internal S3 as the authoritative source and node-local Model Cache for frequently served models.

Documentation: [Supported model storage options][storage] · [Precache models from S3][precache]

## 7. Where the model registry helps

### Distinguish the components

| Component | Responsibility |
|---|---|
| **OpenShift AI model registry** | Model metadata, versions, artifact locations, and lifecycle tracking |
| **OCI registry, such as Quay** | Stores actual ModelCar image content |
| **Node cache or persistent storage** | Provides model files to serving workloads |
| **Serving runtime** | Loads weights and executes inference |

The model registry is a metadata service. Registering an external artifact alone does not copy its weights on-premises, warm serving nodes, or increase token-generation speed.

### “Register” versus “Register and store”

OpenShift AI 3.5 documents two workflows:

| Workflow | Behavior | Performance implication |
|---|---|---|
| **Register** | Records metadata pointing to an artifact stored elsewhere | No direct caching benefit |
| **Register and store** | Runs a background Kubernetes Job to copy/transform the model into an OCI ModelCar image and register its metadata | Can establish a local artifact source; subsequent image reuse can reduce startup transfers |

**Recommendation:** Use the registry to govern approved versions and track their locations. Use internal artifact storage and node caching to improve startup.

> **Dashboard limitation:** The 3.5 guide states that deployment of URI-registered models through that workflow currently supports public OCI repositories only. Verify the authenticated deployment path before assuming the dashboard can deploy directly from a private Quay repository. This is a workflow limitation, not a statement that private OCI serving is universally unavailable.

Documentation: [Model registry overview][registry-overview] · [Register models and store OCI images][registry-workflow]

## 8. vLLM prefix caching

**Best fit:** Requests sharing the same initial tokens, such as a system prompt, few-shot examples, or repeated document context.

Prefix caching reuses previously computed attention KV state. OpenShift AI’s vLLM reference documents:

```text
--enable-prefix-caching
```

The main benefit is reduced prefill work and faster time to first token. This is not a model-file cache or a completed-answer cache. Confirm the setting for the deployed runtime rather than assuming a default.

Documentation: [vLLM arguments reference][vllm]

## 9. llm-d cache-aware routing

**Best fit:** Multiple serving replicas processing workloads with shared prompt prefixes.

The documented 3.5 default scheduler combines:

| Scorer | Purpose |
|---|---|
| `queue-scorer` | Balances queue depth |
| `kv-cache-utilization-scorer` | Considers available KV-cache capacity |
| `prefix-cache-scorer` | Favors replicas likely to reuse prompt prefixes |
| `no-hit-lru-scorer` | Breaks ties when no cache hit is identified |

The default hash-based prefix scorer works in disconnected environments. The optional precise scorer requires tokenizer downloads during initialization and is documented as unsuitable for air-gapped deployments.

Documentation: [Configure llm-d request routing][routing]

## 10. Recommended on-premises design

1. **Keep an internal artifact source:** S3-compatible storage for model directories, or Quay for ModelCar images.
2. **Choose the startup-reuse mechanism:** Node-local NVMe Model Cache for frequently deployed HF/S3 models, or node image caching for ModelCar distribution.
3. **Use the model registry for governance:** Track approved versions and artifact locations; use “Register and store” where appropriate.
4. **Enable prompt reuse:** Configure vLLM prefix caching.
5. **Route for reuse across replicas:** Use llm-d cache-aware routing when multiple replicas serve the model.

### Validate the benefit

| Measurement | What it tells you |
|---|---|
| Pod creation to ready endpoint | Whether artifact transfer and initialization are improving |
| Model download and weight-loading durations | Whether the bottleneck is transfer, storage reads, or runtime loading |
| Time to first token | Whether prompt processing and cache reuse are improving |
| Output tokens/second | How effectively the running model generates tokens |
| Request throughput under concurrency | Whether scheduling and cache reuse improve overall capacity |

Compare cold and warm starts separately. For prefix-cache testing, compare repeated-prefix traffic with unrelated prompts while keeping model, hardware, and concurrency consistent.

## Documentation links

- [OpenShift AI 3.5: Cache models on local storage][cache-admin]
- [OpenShift AI 3.5: Precache models for faster deployment][precache]
- [OpenShift AI 3.5: Storing models][storage]
- [OpenShift AI 3.5: Deploy models using distributed inference][distributed]
- [OpenShift AI 3.5: Model catalog and model registries][registry-overview]
- [OpenShift AI 3.5: Work with model registries][registry-workflow]
- [OpenShift AI 3.5: vLLM arguments reference][vllm]
- [OpenShift AI 3.5: Configure llm-d request routing][routing]
- [KServe: OCI/ModelCar storage implementation][oci] — upstream implementation reference, not a Red Hat support statement.

[cache-admin]: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/configuring_your_model-serving_platform/caching-models-on-local-storage_rhoai-admin
[precache]: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploying_models/precache_models_for_faster_deployment
[storage]: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploying_models/deploying-models_rhoai-user
[distributed]: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/deploying-models-using-distributed-inference_distributed-inference
[registry-overview]: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_model_registries/overview-of-model-registries_working-model-registry
[registry-workflow]: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_model_registries/working-with-model-registries_model-registry
[vllm]: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/ref-vllm-arguments_distributed-inference
[routing]: https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/configuring-llm-scheduler
[oci]: https://kserve.github.io/website/docs/0.16/model-serving/storage/providers/oci

