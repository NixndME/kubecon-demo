# KubeCon demo: HKS with a GPU, run by Morpheus

Everything needed to build the demo lab on AWS: an HPE Morpheus appliance, an HKS Kubernetes cluster with one
NVIDIA GPU node, and Traefik and Argo CD on top. Argo CD keeps the cluster in line with the `gitops` folder.

Developers order a private AI chat from the Morpheus catalog. After an admin approves, Argo CD runs it on its own
slice of the GPU at `https://<first name>.<domain>`, and a Grafana dashboard shows its CPU, memory, GPU, questions
and logs.

No passwords, keys or Terraform state are in this repo. They stay on the machine you build from.

## Folders

| Folder | What it holds |
|---|---|
| `terraform/dns` | Public DNS zone for the demo domain |
| `terraform/network` | VPC, subnets, internet gateway, security group, SSH key, Morpheus IP and name |
| `terraform/morpheus` | The Morpheus VM |
| `terraform/hks` | The HKS nodes: one master and one GPU worker |
| `scripts` | Install Morpheus, NVIDIA driver and API name steps for the cluster layout, Argo CD bootstrap, Morpheus catalog setup |
| `gitops` | What Argo CD runs: cert-manager, Traefik, Argo CD, GPU Operator, storage, Loki, Grafana, the AI chat chart |
| `morpheus` | Files the catalog setup loads into Morpheus: the blueprint spec and the remove task |

## How it fits together

1. Terraform builds the network, the Morpheus VM and the two HKS nodes. Every AWS resource gets the tag
   `Project=kubecon-demo`.
2. `scripts/install-morpheus.sh` installs Morpheus on its VM.
3. A Morpheus cluster layout builds HKS on the two nodes. Its steps come from `scripts`:
   - `public-admin-conf.sh` keeps the public API name in the kubeconfig Morpheus shows
   - `install-nvidia-driver.sh` installs the NVIDIA driver on nodes that have a GPU
   - `add-api-names.sh` adds the public name to the Kubernetes API certificate
4. `scripts/bootstrap-gitops.sh` installs cert-manager, Traefik and Argo CD once, with the logins from a local file.
5. Argo CD then follows `gitops/root-app.yaml`: every file in `gitops/apps` is an app it keeps in sync with Git.
6. `scripts/setup-morpheus-catalog.sh` sets up the Morpheus side: the "Private AI chat" blueprint and catalog
   item, the "Remove AI chat" item, the developer role and user, and the approvals. It is safe to run again.

## The AI chat, step by step

- A developer opens the Service Catalog, picks "Private AI chat" and fills in first name, email, password,
  team (optional) and model.
- An admin approves it in Morpheus.
- Morpheus creates the app `ai-<first name>`. It holds one Argo CD app, and Argo CD deploys
  `gitops/charts/ai-chat` into the namespace `ai-<first name>`: Ollama with the model on one GPU slice, and
  Open WebUI at `https://<first name>.<domain>`. The login is the email and password from the order.
- The same name `ai-<first name>` is used in Morpheus, Argo CD, the namespace, Grafana and the remove list.
- "Remove AI chat" lists the chats running now. Type the app name to confirm, an admin approves, and the chat,
  its namespace, its GPU slice and the Morpheus app are removed.
- Grafana, dashboard "AI chats": pick a chat to see its pods, GPU slice, CPU and memory (with thresholds), the
  shared GPU, the questions asked (who, model, question) and its logs. Logs come from Loki.

## Build it

```bash
scripts/tf.sh network init && scripts/tf.sh network plan && scripts/tf.sh network apply
scripts/tf.sh morpheus init && scripts/tf.sh morpheus plan && scripts/tf.sh morpheus apply
scripts/tf.sh hks init && scripts/tf.sh hks plan && scripts/tf.sh hks apply
```

`scripts/tf.sh` keeps state and variables in `~/.local/share/kubecon-demo/`. Put the domain in `common.tfvars`,
your IP in `network.tfvars` and `hks.tfvars`, and the node password hash in `hks.tfvars`.

Then create the cluster in Morpheus from the layout (Master Host is the public API name), download its kubeconfig,
and run:

```bash
KUBECONFIG=<kubeconfig> scripts/bootstrap-gitops.sh <file with APPS_USER and APPS_PASSWORD>
kubectl apply -f gitops/root-app.yaml
```

When all Argo CD apps are healthy, set up the Morpheus catalog:

```bash
scripts/setup-morpheus-catalog.sh <file with MORPHEUS_URL and MORPHEUS_TOKEN> <file with APPS_USER and APPS_PASSWORD>
```

## Notes

- Calico sends pod traffic between nodes without a tunnel when they share a subnet, so the HKS nodes have the AWS
  source and destination check turned off.
- The NVIDIA step blocks the kernel's own nouveau driver and loads the NVIDIA driver without a reboot.
- Instances have termination protection. To delete one on purpose, apply with `-var protect=false` first.
- The chat password passes through two Morpheus templates, which put a backslash before `$`. The password rule
  allows no backslashes, so the chart removes them and the login is exactly what was typed.
- The chat password is kept in the Argo CD app, so Argo CD admins can read it. Use a demo password.
- Deleting an app in Morpheus does not remove what it made in the cluster. Use "Remove AI chat".
