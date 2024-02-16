# aws-consul-sd-to-sm
This repo can build the required AWS Networking and EKS resources to run self hosted Consul clusters on EKS.  It contains example configurations to test the processes of migrating services from using service discovery to using service mesh.

## Pre Reqs
- Setup shell with AWS credentials
- AWS Key Pair (EKS Terraform module uses this)
- Terraform 1.3.7+
- AWS cli
- Kubectl
- Helm
- curl
- jq


## Provision Infrastructure
If EKS infrastructure already exists, skip the Provisioning steps and jump to `Installing Consul`. Otherwise, use Terraform to build the required AWS Infrastructure.
```
cd quickstart/infrastructure
```
Update the `my.auto.tfvars` for your environment.  
* Configure an existing AWS Key Pair that is present in the target region (**us-west-2**).
* Review the prefix being used for resource names, the EKS version, and Consul version.

Run Terraform
```
terraform init
terraform apply -auto-approve
```

## Connect to EKS
To connect to EKS provide the cluster name and region. These can be easily retrieved from the Terraform output. Set these variables in your terminal environment because they will be used again during the installation process.
```
output=$(terraform output -json)
region=$(echo $output | jq -r '.usw2_region.value')
cluster=$(echo $output | jq -r '.usw2_eks_cluster_name.value')

aws sts get-caller-identity
aws eks --region $region update-kubeconfig --name $cluster --alias "usw2" 

# kubectl aliases
alias usw2="kubectl config use-context usw2"
alias 'kc=kubectl -n consul'
alias 'kk=kubectl -n kube-system'
```

## Install Consul

### Install the AWS Loadbalancer controller on EKS
The AWS LB controller is required to map internal NLB or ALBs to kubernetes services.  The helm templates used to install consul will attempt to leverage this controller.  This repo is adding the required tags to public and private subnets in order for the LB to properly discover them.  If not using this repo ensure the proper subnet tags are in nplace.  

To install the AWS LB Controller create a service account tied to the AWS account_id used to create EKS.
```
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat  << EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: aws-load-balancer-controller
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/${cluster}-load-balancer-controller
EOF
```

Next install the helm chart
```
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="${cluster}" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller
```

Verify the installation.  Wait a minute for it to complete.
```
kubectl get deployment -n kube-system aws-load-balancer-controller
```

### Install the Consul Kubernetes CLI Tool
The Consul K8s CLI tool enables you to quickly install and interact with Consul on Kubernetes.  [Install consul-k8s](https://developer.hashicorp.com/consul/docs/k8s/installation/install-cli).  

### Install Consul helm chart
The example consul helm values can be found [here]((https://github.com/ppresto/aws-consul-sd-to-sm/blob/main/quickstart/infrastructure/consul_helm_values/yaml/example-values.yaml)).
```
consul-k8s install -auto-approve -f consul_helm_values/yaml/example-values.yaml
```

### Login to the Consul UI
Setup the local terminal to connect to Consul to verify its alive. Consul may take a couple minutes to fully start so be patient.
```
export CONSUL_HTTP_ADDR="https://$(kubectl -n consul get svc consul-ui -o json | jq -r '.status.loadBalancer.ingress[].hostname')"
export CONSUL_HTTP_TOKEN=$(kubectl -n consul get secrets consul-bootstrap-acl-token --template "{{ .data.token | base64decode }}")
export CONSUL_HTTP_SSL_VERIFY=false
consul members
```
If Consul isn't installed locally, simply login to the Consul UI using the CONSUL_HTTP_ADDR and CONSUL_HTTP_TOKEN to verify its alive.

### Setup DNS Forwarding in EKS 1.28
There are many ways to forward requests to Consul.  Within EKS the simplest way is to update coredns to forward the default stub domain (.consul) to Consul.  To backup the existing config and patch coredns to forward requests to Consul run the patch script below.
```
../../scripts/patch_coredns_to_fwd_to_consul.sh
```

To do this manually get the Consul DNS service IP.
```
CONSUL_DNS_CLUSTER_IP=$(kubectl -n consul get svc ${CONSUL_DNS_SVC} -o json | jq -r '.spec.clusterIP')
```

Append the coredns config map with the stub domain (**.consul**) you want to forward to Consul.
```

consul:53 {
        errors
        cache 30
        forward . ${CONSUL_DNS_CLUSTER_IP}
        reload
    }
```

Finally, restart the coredns pods to quickly take the new configuration.
```
kubectl -n kube-system delete po -l k8s-app=kube-dns
```

#### Verify Consul DNS is working
Lookup the consul service using consul DNS.  If coredns is forwarding .consul requests this should return the Consul server pod IP.
```
kubectl -n consul exec -it consul-server-0 -- nslookup consul.service.consul
```

## Deploy services
### Services using Service Discovery
Deploy `api` to EKS and Consul will automatically register it for **Service Discovery** like existing services on K8s using catalog-sync or VMs using Consul agents.
```
cd ../../examples/fake-service-community
kubectl create ns api
kubectl apply -f api/api-v1.yaml
```
This service represents any other service using Consul Service Discovery. It should be discoverable via Consul DNS.
```
kubectl -n api exec -it deploy/api-v1 -- nslookup api.service.consul
```
### Services using Service Mesh
An Ingress or API Gateway is required to see services in the service mesh.  Deploy the `web` service into the service mesh, and the Consul API Gateway with a route to `web` so its accessible from the browser. Use the API Gateway URL below to access web from the browser. DNS may need a few minutes to propagate before the URL is resolvable.
```
kubectl apply -f ../consul-apigw/
kubectl create ns web
kubectl apply -f web/init-consul-config/
kubectl apply -f web/web.yaml
echo "http://$(kubectl get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
```
Before deploying `web`,`init-consul-config/mesh.yaml` defaults were applied allowing mesh services to access external destinations.  This enables mesh services to use existing service discovery lookups like `api.service.consul` that are outside of the service mesh.  Notice, `web` is inside the service mesh and accessing `api.service.consul` which is outside the mesh.  Traffic between `web` and `api` is unencrypted.

### Migrate Service into the service mesh
web and other downstream services may be accessing `api` so the current service discovery lookup `api.service.consul` needs to be accessible to both mesh and non-mesh services during the migration.  To do this, create a new deployment for `api` enabling Consul service mesh and permissive mode.
| Filename                                          | Description                                                                    |
| ------------------------------------------------- | ------------------------------------------------------------------------------ |
| api/permissive_mTLS_mode/init-consul-config/servicedefaults-permissive.yaml     | permissive mode allows HTTP and mTLS connections |
| api/permissive_mTLS_mode/api-v2-mesh-enabled.yaml     | Enable service mesh with annotation: connect-inject: true |

```
kubectl apply -f api/permissive_mTLS_mode/init-consul-config
kubectl apply -f api/permissive_mTLS_mode/api-v2-mesh-enabled.yaml
```
Refresh the browser a few times and watch how requests from web are balanced across both non-mesh and mesh enabled api deployments. After verifying the api mesh enabled deployment is still working for all downstreams using api.service.consul go ahead and remove api-v1.
```
kubectl -n api delete deployment api-v1
```



## Uninstall
```
# Remove Consul
consul-k8s uninstall -auto-approve -wipe-data

# Remove the AWS LB Controller
helm uninstall -n kube-system --kube-context=usw2 aws-load-balancer-controller
```