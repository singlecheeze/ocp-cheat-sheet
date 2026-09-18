### Llama LLM Quick Start
My GPU layout:
```text
ocp113.localdomain   NVIDIA-A40
ocp114.localdomain   Tesla-P4
ocp115.localdomain   NVIDIA-A40
```
Operators / Operands Required:
- OpenShift AI Operator
  - DataScienceCluster
- Node Feature Discovery (Deployed when the Nvidia GPU & Network Operators were deployed)
- Nvidia GPU Operator
  - ClusterPolicy
- Some CSI with `default` storage class set (This makes certain items easier)
- cert-manager
- Job Set Operator
  - JobSetOperator
  
For Distributed Inference with llm-d, Red Hat additionally requires:
- Red Hat Connectivity Link Operator
- Red Hat Leader Worker Set Operator
- Optionally Cluster Observability Operator for the supplied dashboards
  
For your first LLM, I recommend KServe RawDeployment rather than the more complicated serverless stack.
 - `RawDeployment` uses ordinary Kubernetes Deployment, Service, and HPA resources and has a much smaller dependency footprint. 
 - Serverless adds additional routing/autoscaling infrastructure.
  
Red Hat explicitly supports setting individual DSC components to either Managed or Removed; Removed means the OpenShift AI Operator will not install that component.
```bash
[dave@rhel9dummy2 ~]$ oc get datasciencecluster default-dsc -o yaml
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  creationTimestamp: "2026-09-13T16:19:19Z"
  generation: 3
  labels:
    app.kubernetes.io/name: datasciencecluster
  name: default-dsc
  resourceVersion: "9583269"
  uid: 730dccab-aa71-4e2c-ac76-3256ad922e32
spec:
  components:
    aipipelines:
      managementState: Managed
    dashboard:
      managementState: Managed
    feastoperator:
      managementState: Managed
    kserve:
      managementState: Managed
      modelsAsService:
        managementState: Removed
      nim:
        airGapped: false
        managementState: Managed
      rawDeploymentServiceConfig: Headed
      wva:
        managementState: Removed
    kueue:
      autoCreateQueues: false
      defaultClusterQueueName: default
      defaultLocalQueueName: default
      managementState: Removed
    llamastackoperator:
      managementState: Removed
    mlflowoperator:
      managementState: Managed
    modelregistry:
      managementState: Managed
      registriesNamespace: rhoai-model-registries
    ogx:
      managementState: Managed
    ray:
      managementState: Managed
    sparkoperator:
      managementState: Removed
    trainer:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      managementState: Managed
      mcpGuardrailsMode: false
    workbenches:
      managementState: Managed
      workbenchNamespace: rhods-notebooks 
```
I would initially make sure you have at least:
```yaml
spec:
  components:
    dashboard:
      managementState: Managed

    kserve:
      managementState: Managed
      rawDeploymentServiceConfig: Headed
```
`Headed` means normal Kubernetes service load balancing rather than expecting the client to load-balance across individual inference pods.  
  
For an inference-only first installation, you do not need to enable every DSC component. Current OpenShift AI exposes components such as pipelines, Kueue, Ray, Trainer, model registry, TrustyAI, OGX, etc.; setting components to `Managed` causes the operator to install and manage them.
  
Then verify KServe itself:
```bash
oc get pods -n redhat-ods-applications | grep -E 'kserve-controller-manager|odh-model-controller'
kserve-controller-manager-8c6f848dd-6t8mn                         1/1     Running   0             13h
odh-model-controller-57f8dbf89f-5sj8p                             1/1     Running   0             23h
```
### Enable model serving and the NVIDIA vLLM runtime
OpenShift AI 3.5's regular model-serving platform is KServe-based and is explicitly intended for LLM/generative-AI workloads.  
  
Enable model serving
- Open the OpenShift AI Dashboard, not the regular OpenShift console.
  - Go to: Settings → Cluster settings → General settings
  - Find Model serving platforms and enable:
    - Model serving platform
  - Then click Save changes.
- Then go to:
  - Settings → Model resources and operations → Serving runtimes
  - Find: vLLM NVIDIA GPU ServingRuntime for KServe and set it to Enabled.
- OpenShift AI includes preinstalled serving runtimes, and NVIDIA GPUs are served with the NVIDIA vLLM runtime.  
- Don't enable one of the fast-* vLLM builds for our first test. Those are the limited-support builds with a one-month support window. Use the normal preinstalled GA NVIDIA vLLM runtime.

### Create an NVIDIA hardware profile
OpenShift AI uses a HardwareProfile to associate things like CPU/memory/GPU resources with workloads. It can also use the accelerator in the profile to automatically pick the correct serving runtime. For example, an NVIDIA hardware profile lets it match the deployment to the NVIDIA vLLM runtime.
  
In the dashboard go to: Settings → Hardware profiles  
  
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ If you have certain nodes with different GPUs and you want to target specific nodes for work, use the pre-populated Nvidia Node Labels:
<img width="1508" height="277" alt="image" src="https://gist.github.com/user-attachments/assets/91be985b-b4b2-416d-8a5a-292ff06b34a5" />

Create something like:
```text
Name: nvidia-1gpu

CPU
Request: 2-4
Limit:   4-8

Memory
Request: 16Gi
Limit:   32Gi

Accelerator:
nvidia.com/gpu

GPU count:
1
```
The exact CPU and RAM numbers aren't particularly important for the first test; VRAM is usually the constraining resource for the LLM.  
  
If your GPU worker nodes are tainted, put the corresponding toleration/node-placement configuration into the hardware profile as appropriate.  

I would verify the GPU nodes at this point too:  
```bash
[dave@rhel9dummy2 ~]$ oc describe node ocp113.localdomain | grep -A10 -E 'Capacity:|Allocatable:'
Capacity:
  cpu:                              128
  devices.kubevirt.io/kvm:          1k
  devices.kubevirt.io/tun:          1k
  devices.kubevirt.io/vhost-net:    1k
  ephemeral-storage:                468260676Ki
  hugepages-1Gi:                    0
  hugepages-2Mi:                    0
  memory:                           131545740Ki
  nvidia.com/gpu:                   1
  nvidia.com/gpu.shared:            0
--
Allocatable:
  cpu:                              127500m
  devices.kubevirt.io/kvm:          1k
  devices.kubevirt.io/tun:          1k
  devices.kubevirt.io/vhost-net:    1k
  ephemeral-storage:                430475296464
  hugepages-1Gi:                    0
  hugepages-2Mi:                    0
  memory:                           130394764Ki
  nvidia.com/gpu:                   1
  nvidia.com/gpu.shared:            0
```
### Decide where the LLM will come from
There are several ways to provide models to KServe. For a first deployment, I like an OCI ModelCar because you don't have to stand up MinIO/Ceph just to prove that GPU inference works. OpenShift AI can also use S3-compatible object storage. Red Hat recommends S3-compatible storage such as S3, MinIO, or Ceph as part of the model-serving architecture.  
  
For a simple test, Red Hat's OpenShift AI 3.5 documentation actually uses this ModelCar URI:
```text
oci://quay.io/redhat-ai-services/modelcar-catalog:llama-3.2-3b-instruct
```
That's a nice small model for validating that everything works before worrying about a larger production LLM.  
  
Create a new OpenShift AI project, for example: `llm-demo`  
Then inside that project create a connection using:  
```text
Connection type:
URI - v1

URI:
oci://quay.io/redhat-ai-services/modelcar-catalog:llama-3.2-3b-instruct
```
For production, I'd probably move the organization's approved models into an internal OCI registry or S3/Ceph bucket instead.  
### Deploy the first model
  
In OpenShift AI:
- Projects → llm-demo → Deployments → Deploy model
  
For the first test configure roughly:  
```text
Model deployment name:
llama-3-2-3b

Model type:
Generative AI

Serving runtime:
vLLM NVIDIA GPU ServingRuntime for KServe

Deployment mode:
KServe RawDeployment

Replicas:
1

Hardware profile:
nvidia-1gpu

Model location:
your URI connection

Token authentication:
Disabled
```
For this Llama model, Red Hat currently recommends these vLLM arguments:
```text
--dtype=half
--max-model-len=20000
--gpu-memory-utilization=0.95
--enable-chunked-prefill
--enable-auto-tool-choice
--tool-call-parser=llama3_json
--chat-template=/opt/app-root/template/tool_chat_template_llama3.2_json.jinja
```
Don't immediately add tensor parallelism, speculative decoding, RDMA, multiple replicas, or unusual vLLM flags. First establish:
```text
Model loads
     ↓
GPU is allocated
     ↓
InferenceService becomes Ready
     ↓
/v1/models works
     ↓
/v1/chat/completions works
```
Watch the deployment from the CLI:
```bash
[dave@rhel9dummy2 ~]$ oc get pods -n <Your Namespace> -w
NAME                                    READY   STATUS    RESTARTS   AGE
genai-pgvector-dbd7bf75c-rlb5z          1/1     Running   0          12h
lsd-genai-playground-59584c98c4-cx2fj   1/1     Running   0          11h
```
### Check your KServe status
Run this:  
```bash
[dave@rhel9dummy2 ~]$ oc get datasciencecluster "${DSC}" \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' \
  | column -t -s $'\t'
Ready                                        True
ProvisioningSucceeded                        True
ComponentsReady                              True
ModulesReady                                 True
AIGatewayReady                               False  Removed               Module ManagementState is set to Removed
AIPipelinesReady                             True
BatchGatewayReady                            False  Removed               Submodule ManagementState is set to Removed
DashboardReady                               True   AllDependentsHealthy
FeastOperatorReady                           True
KserveLLMInferenceServiceDependencies        True
KserveLLMInferenceServiceWideEPDependencies  True
KserveReady                                  True
KueueReady                                   False  Removed               Component ManagementState is set to Removed
MCPLifecycleOperatorReady                    False  Removed               Module ManagementState is set to Removed
MLflowOperatorReady                          True   Ready                 MLflowOperator is ready to manage MLflow custom resources
ModelRegistryReady                           True
ModelsAsAServiceReady                        False  Removed               Submodule ManagementState is set to Removed
OGXReady                                     True   AllDependentsHealthy
ProvisioningProgress                         True
RayReady                                     True
SparkOperatorReady                           False  Removed               Component ManagementState is set to Removed
TrainerReady                                 False  Removed               Component ManagementState is set to Removed
TrainingOperatorReady                        False  Removed               Component ManagementState is set to Removed
TrustyAIReady                                True
WorkbenchesReady                             True   ReconcileSuccess      Workbenches component is ready
```
I'd specifically look for:
```text
Ready                              True
ComponentsReady                    True
KserveReady                        True
ModelControllerReady               True
```
### What I would enable in your DSC right now
Since your immediate objective is "get an LLM running on my NVIDIA GPU", keep the cluster simple.
  
Something conceptually like:
```yaml
spec:
  components:
    dashboard:
      managementState: Managed
    kserve:
      managementState: Managed
    workbenches:
      managementState: Managed
    trainer:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    ray:
      managementState: Removed
    kueue:
      managementState: Removed
    modelregistry:
      managementState: Removed
    trustyai:
      managementState: Removed
    aipipelines:
      managementState: Removed
```
You don't have to use that exact whole block yet; I'm showing the intent. We don't want to turn on every OpenShift AI capability just because it's available.  
  
Our initial stack is:  
```text
OpenShift
   |
   +-- Node Feature Discovery Operator
   |
   +-- NVIDIA GPU Operator
   |       |
   |       +-- nvidia.com/gpu
   |
   +-- NVIDIA Network Operator
   |       └── not needed yet for single-GPU inference
   |
   +-- cert-manager
   |
   +-- OpenShift AI 3.5
           |
           +-- Dashboard
           |
           +-- KServe
           |      |
           |      +-- InferenceService
           |      |
           |      +-- vLLM NVIDIA runtime
           |
           +-- HardwareProfile
                  |
                  +-- nvidia.com/gpu: 1
```
Then:
```text
Llama / Granite / Qwen
        ↓
       vLLM
        ↓
      KServe
        ↓
    NVIDIA GPU
        ↓
OpenAI-compatible API
```  
### One important Kueue check
There's one OpenShift AI 3.5 caveat worth checking before creating the profile.
  
If you're using Kueue to manage model workloads, RHOAI doesn't allow node selectors/tolerations directly in the HardwareProfile used with a Kueue local queue. In that architecture, placement is done with Kueue ResourceFlavors instead.
Check:
```bash
[dave@rhel9dummy2 ~]$ oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kueue.managementState}{"\n"}'
Removed
```
If Kueue is `Removed`, or your future model namespace isn't Kueue-managed, we're fine to use the HardwareProfile node selector above.  
  
### We're ready for the first LLM
At this point your stack becomes:
```text
✓ NVIDIA GPU Operator
✓ NVIDIA Network Operator
✓ A40 discovered on ocp113
✓ A40 discovered on ocp115
✓ cert-manager
✓ OpenShift AI 3.5
✓ DSC Ready
✓ KServe Ready

NEXT

[1] NVIDIA A40 HardwareProfile
              ↓
[2] NVIDIA vLLM ServingRuntime
              ↓
[3] Project
              ↓
[4] Small Llama / Granite model
              ↓
[5] KServe RawDeployment
              ↓
[6] ocp113 OR ocp115
              ↓
[7] Test /v1/chat/completions
```
OpenShift AI 3.5 has exactly that built in: Gen AI Studio → Playground  
- It gives you a chat-style web UI where you can select the `llama-test` project, type prompts, maintain chat context, adjust model settings, and later add things like RAG/document upload or MCP tools.
  
Check whether Gen AI Studio and OGX are already enabled:
```bash
[dave@rhel9dummy2 ~]$ echo "=== GEN AI STUDIO ==="
oc get odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig.genAiStudio}{"\n"}'

echo
echo "=== OGX ==="
oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.ogx.managementState}{"\n"}'
=== GEN AI STUDIO ===
true

=== OGX ===
Managed
```
OpenShift AI 3.5 requires spec.dashboardConfig.genAiStudio=true and the OGX component set to Managed for the Playground.

If Gen AI Studio isn't enabled:
```bash
[dave@rhel9dummy2 ~]$ oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications \
  --type=merge \
  -p '{"spec":{"dashboardConfig":{"genAiStudio":true}}}'
odhdashboardconfig.opendatahub.io/odh-dashboard-config patched (no change)
```
If OGX isn't enabled:
```bash
[dave@rhel9dummy2 ~]$ oc patch datasciencecluster default-dsc \
  --type=merge \
  -p '{"spec":{"components":{"ogx":{"managementState":"Managed"}}}}'
datasciencecluster.datasciencecluster.opendatahub.io/default-dsc patched (no change)
```
### Add llama-test (Or any other model...) to Gen AI Studio
Your model also needs to be registered as an AI asset endpoint. OpenShift AI explicitly requires this before a deployed model can be selected in the Playground.

In the OpenShift AI dashboard, go to your project and edit the llama-test deployment. Under the advanced model settings, enable, "Add as AI Asset Endpoint":
<img width="2072" height="895" alt="image" src="https://gist.github.com/user-attachments/assets/448cc513-ce5b-4e6a-ba6e-f5a5558a81b1" />  
Then you should see:
- Gen AI studio → AI asset endpoints with something like:  
<img width="2603" height="691" alt="image" src="https://gist.github.com/user-attachments/assets/6c245650-fcec-4186-ba4c-1b82e4e80fa6" />  
From there click Add to playground!
<img width="1944" height="1249" alt="image" src="https://gist.github.com/user-attachments/assets/42e2a3f8-c650-47b1-b258-b79f7d094688" />
  
One distinction worth making: If what you ultimately want is a production ChatGPT-style UI for normal users, rather than an AI engineer's testing playground, I'd deploy something like Open WebUI against the same https://llama-test-ge-ai.apps.ocp4.localdomain/v1 API.  
  
But for learning OpenShift AI and interacting with this model right now, Gen AI Studio Playground is the right next step.  
  
How to watch GPU Utilization:
Find your Nvidia GPU driver pods:
```bash
[dave@rhel9dummy2 ~]$ oc get pods -n nvidia-gpu-operator -o wide | grep nvidia-driver-daemonset
nvidia-driver-daemonset-9.8.20260825-0-246mq   2/2     Running     2               2d23h   10.128.0.20    ocp113.localdomain   <none>           <none>
nvidia-driver-daemonset-9.8.20260825-0-7mf9s   2/2     Running     0               2d23h   10.130.0.134   ocp114.localdomain   <none>           <none>
nvidia-driver-daemonset-9.8.20260825-0-zg7g5   2/2     Running     0               2d23h   10.129.0.30    ocp115.localdomain   <none>           <none
```
```bash
[dave@rhel9dummy2 ~]$ oc exec -n nvidia-gpu-operator -it nvidia-driver-daemonset-9.8.20260825-0-246mq -c nvidia-driver-ctr -- nvidia-smi dmon
# gpu    pwr  gtemp  mtemp     sm    mem    enc    dec    jpg    ofa   mclk   pclk
# Idx      W      C      C      %      %      %      %      %      %    MHz    MHz
    0    293     62      -    100    100      0      0      0      0   7251   1740
    0    293     63      -    100    100      0      0      0      0   7251   1740
    0    293     63      -    100    100      0      0      0      0   7251   1740
    0    295     63      -    100    100      0      0      0      0   7251   1740
    0    285     64      -    100    100      0      0      0      0   7251   1740
    0    143     58      -      0      0      0      0      0      0   7251   1740
    0    119     57      -      0      0      0      0      0      0   7251   1740
    0    119     56      -      0      0      0      0      0      0   7251   1740
[dave@rhel9dummy2 ~]$ oc exec -n nvidia-gpu-operator -it nvidia-driver-daemonset-9.8.20260825-0-246mq -c nvidia-driver-ctr -- nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,utilization.memory,power.draw
name, memory.used [MiB], memory.total [MiB], utilization.gpu [%], utilization.memory [%], power.draw [W]
NVIDIA A40, 41638 MiB, 46068 MiB, 0 %, 0 %, 110.76 W
```