# KubeCon demo: HKS with a GPU, run by Morpheus

Everything needed to build the demo lab on AWS: an HPE Morpheus appliance, an HKS Kubernetes cluster with one
NVIDIA GPU node, and Traefik and Argo CD on top. Argo CD keeps the cluster in line with the `gitops` folder.

No passwords, keys or Terraform state are in this repo. They stay on the machine you build from.

## Folders

| Folder | What it holds |
|---|---|
| `terraform/dns` | Public DNS zone for the demo domain |
| `terraform/network` | VPC, subnets, internet gateway, security group, SSH key, Morpheus IP and name |
| `terraform/morpheus` | The Morpheus VM |
| `terraform/hks` | The HKS nodes: one master and one GPU worker |
| `scripts` | Install Morpheus, NVIDIA driver and API name steps for the cluster layout, Argo CD bootstrap |
| `gitops` | What Argo CD runs: cert-manager, Traefik, Argo CD itself, later the demo apps |

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

## Notes

- Calico sends pod traffic between nodes without a tunnel when they share a subnet, so the HKS nodes have the AWS
  source and destination check turned off.
- The NVIDIA step blocks the kernel's own nouveau driver and loads the NVIDIA driver without a reboot.
- Instances have termination protection. To delete one on purpose, apply with `-var protect=false` first.
