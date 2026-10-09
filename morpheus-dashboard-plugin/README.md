# AI on HKS: Morpheus dashboard plugin

Adds "AI on HKS" to Operations > Dashboard in Morpheus. One page for the private AI chats of this demo:

- chats running, waiting for GPU, GPU memory booked, approvals waiting, questions and cost of the last 24 hours
- waiting orders with Approve and Reject buttons
- every chat: owner, model, size, GPU share, questions, cost. Click a row to see its questions
- cost per chat: questions, idle, cost by part (GPU, CPU, memory) and advice
- who has which part of the GPU, the activity of the last day and the health of Argo CD, nodes, HAMi and Loki

It reads Prometheus, Loki and Argo CD through the Kubernetes API with a read-only token
(`gitops/platform/morpheus-dashboard`). Approvals use the logged-in user's own Morpheus rights.
Tested on Morpheus 9.1.0.

## Install

Download the jar from the releases page, then:

```bash
KUBECONFIG=<kubeconfig> scripts/setup-morpheus-dashboard.sh <file with MORPHEUS_URL and MORPHEUS_TOKEN> <jar>
```

The script uploads the jar, fills in the plugin settings, gives System Admins the "AI on HKS" permission and
puts the dashboard on Operations > Dashboard. Other roles that should see it need that permission too.

## Build

```bash
./build.sh
```

Needs JDK 17 and Gradle 8.5. The jar lands in `dist/`.
