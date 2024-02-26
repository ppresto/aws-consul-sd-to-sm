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
If EKS infrastructure already exists, skip the Provisioning steps and jump to `Installing Consul`. Otherwise, clone this repo and use Terraform to build the required AWS Infrastructure.
```
git clone https://github.com/ppresto/aws-consul-sd-to-sm.git
cd aws-consul-sd-to-sm/quickstart/infrastructure
```
Update the `my.auto.tfvars` for your environment.  
* Configure an existing AWS Key Pair that is present in the target region (**us-west-2**).
* Review the prefix being used for resource names, the EKS version, and Consul version.

Run Terraform
```
terraform init
terraform apply -auto-approve
```

### Connect to EKS
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

### Install the AWS LB controller
The AWS LB controller is required to map internal NLB or ALBs to kubernetes services.  The helm templates used to install consul will attempt to leverage this controller.  This repo is adding the required tags to public and private subnets in order for the LB to properly discover them.  If not using this repo ensure the proper subnet tags are in place or the Consul Helm installation will fail.

To install the AWS LB Controller create a service account tied to the AWS account_id used to create EKS.
```
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

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
## Install Consul

### Install the Consul Kubernetes CLI Tool
The Consul K8s CLI tool enables you to quickly install Consul using the Helm chart. Discover more here about this tool’s capabilities including reading Envoy configs, adjusting logging levels, and diagnosing Consul service mesh connectivity problems.
[Install consul-k8s](https://developer.hashicorp.com/consul/docs/k8s/installation/install-cli)for your platform. For example, on MacOS use Brew.  
```
brew tap hashicorp/tap
brew install hashicorp/tap/consul-k8s
```

### Install Consul Helm chart
Using consul-k8s, install Consul with the Helm [community-values.yaml]((https://github.com/ppresto/aws-consul-sd-to-sm/blob/main/quickstart/infrastructure/consul_helm_values/yaml/community-values.yaml)). This file will enable a recommended Consul configuration (including tls, acls, connect-inject, apiGateway, cni, metrics)

```
consul-k8s install -auto-approve -f consul_helm_values/yaml/community-values.yaml
```

### Login to the Consul UI
Setup the local terminal to connect to Consul to verify its alive. Consul may take a couple minutes to fully start so be patient.
```
export CONSUL_HTTP_ADDR="https://$(kubectl -n consul get svc consul-ui -o json | jq -r '.status.loadBalancer.ingress[].hostname')"
export CONSUL_HTTP_TOKEN=$(kubectl -n consul get secrets consul-bootstrap-acl-token --template "{{ .data.token | base64decode }}")
export CONSUL_HTTP_SSL_VERIFY=false
consul members
```
If Consul isn't installed locally, simply use the browser to login to the Consul UI with the CONSUL_HTTP_ADDR and CONSUL_HTTP_TOKEN to verify its alive.

### Setup DNS Forwarding in EKS
[DNS forwarding](https://developer.hashicorp.com/consul/tutorials/networking/dns-forwarding) is only required for service discovery. There are many ways to forward DNS requests to Consul. Within EKS the simplest way is to have coredns forward the default stub domain (.consul) to Consul. 
To do this manually, get the Consul DNS service IP.
```
CONSUL_DNS_CLUSTER_IP=$(kubectl -n consul get svc ${CONSUL_DNS_SVC} -o json | jq -r '.spec.clusterIP')
```
Append the stub domain (ex: **.consul**) to the coredns config map so coredns can properly forward those DNS requests to Consul. Update the DNS cluster IP below with the value from $CONSUL_DNS_CLUSTER_IP above and save the config map.
```
consul:53 {
        errors
        cache 30
        forward . ${CONSUL_DNS_CLUSTER_IP}
        reload
    }
```

Restart the coredns pods to quickly apply the changes.
```
kubectl -n kube-system delete po -l k8s-app=kube-dns
```

To quickly backup and patch coredns to forward requests to Consul run the EKS 1.28 patch script below.
```
../../scripts/patch_coredns_to_fwd_to_consul.sh  #Restarts coredns pods!
```
An EKS 1.27 template is also available by updating the script's $CORE_DNS_TMPL_DIR.


### Verify Consul DNS is working
Lookup the consul service using consul DNS.  If coredns is forwarding .consul requests this should return the Consul server pod IP.
```
kubectl -n consul exec -it consul-server-0 -- nslookup consul.service.consul
```

## Deploy services
This repo uses [fake-service](https://github.com/nicholasjackson/fake-service) for testing service discovery and mesh communication. By setting environment variables this service can support different protocols (HTTP, gRPC) and a variety of service mesh use cases.

### Deploy service using Consul service discovery
When Consul is utilized for service discovery, it's common to see services deployed on VMs and other platforms. This guide uses a single EKS cluster to simplify all operations. Nonetheless, the migration path for services to the mesh is similar on VMs or other platforms.

Deploy `api` to EKS and Consul will automatically register it for **service discovery** like existing services on K8s using catalog-sync or VMs using Consul agents.
```
cd ../../examples
kubectl create ns api
kubectl apply -f fake-service-community/api/api-v1.yaml
```

Verify DNS forwarding is setup properly and service discovery is working.
```
kubectl -n api exec -it deploy/api-v1 -- nslookup api.service.consul

Server:  172.20.0.10
Address: 172.20.0.10:53

Name: api.service.consul
Address: 10.15.3.227
```
### Deploy service using Consul service mesh
The Consul service mesh doesn’t require DNS forwarding because it uses the Envoy proxy to discover and route requests. These proxies intercept and route all traffic in the mesh, not allowing any external requests into the mesh. To externally access services within the mesh, an ingress or API gateway is required. Deploy the service `web` into the mesh, and the `Consul API Gateway` with a route to `web` so it's accessible from the browser. 

#### Deploy the Consul API Gateway
Start with the `Consul API Gateway` first because it will take time for the external DNS address of the new `Consul API Gateway` to propagate.
* Deploy Gateway to listen on port 80
* Set annotations to support AWS LB Controller
* The *ClusterRole* and *ClusterRoleBindings* allow the apigw to interact with Consul resources.
* Configure HTTP routes for services in the mesh (`web`).

| Filename                                   | Description                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------------ |
| consul-apigw.yaml                          | Create Gateway, ClusterRoles, and ClusterRoleBindings|
| apigw-ReferenceGrant.yaml                  | Example, Each K8s namespace needs a ReferenceGrant to allow the API GW access|
| apigw-RouteTimeoutFilter.yaml.enable       | Example, Timeouts are defined per route|

```
kubectl apply -f consul-apigw/
```

#### Deploy web
Using fake-service deploy `web` into the service mesh.

The following files in `./fake-service-community/web/init-consul-config` will be applied into the namespace: web.
| Filename                   | Description                                                                    |
| --------------------------- | ------------------------------------------------------------------------------ |
| ReferenceGrant.yaml        | Allow the API Gateway access to the k8s namespace running `web`|
| apigw-route-web.yaml       | Define HTTPRoute's from the API Gateway to `web`|
| apigw-meshservice-web.yaml | Instead of using K8s svc use Consul svc. Useful for multi-cluster failover (not required).|
| servicedefaults.yaml       | Set service level configurations like the protocol (http)|
| intentions-web.yaml        | AuthZ rule or **intention** allowing the api gateway to talk to `web`.|
| proxydefaults.yaml         | Configure the defaults for all proxies|
| mesh.yaml                  | Configure mesh defaults like allowing mesh services external access or to run in permissive mode|
| web/web-v1.yaml            | Create K8s ServiceAccount, Service, and `web` Deployment.  Using annotation **connect-inject** to enable service mesh|

```
kubectl create ns web
kubectl apply -f fake-service-community/web/init-consul-config
kubectl apply -f fake-service-community/web/web-v1.yaml
```
While deploying `web`, [mesh defaults](https://github.com/ppresto/aws-consul-sd-to-sm/blob/main/examples/fake-service-community/web/init-consul-config/mesh.yaml) were applied which included **meshDestinationsOnly: false**.  This allows mesh services to access external destinations.  This enables mesh services to use existing service discovery lookups like `api.service.consul` that are outside of the service mesh.

#### Get apigw URL
Use the Consul API Gateway URL to access `web`. **WARNING**: Wait enough time for the external DNS name to be resolvable.
```
export APIGW_URL=$(kubectl get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
nslookup ${APIGW_URL}
```

Using the browser, access `web` using the HTTP routes defined in [apigw-route-web.yaml](https://github.com/ppresto/aws-consul-sd-to-sm/blob/main/examples/fake-service-community/web/init-consul-config/apigw-route-web.yaml)
```
echo "http://${APIGW_URL}/ui"
```

Notice, `web` is inside the service mesh and accessing `api.service.consul` which is outside the mesh.  Traffic between `web` and `api` is unencrypted.

## Migrate Service into the service mesh
`web` and other downstream services may be accessing `api` so the current service discovery lookup `api.service.consul` needs to be accessible to both mesh and non-mesh services during the migration.  To do this, create a new deployment for `api` enabling Consul service mesh and permissive mode.
| Filename                                          | Description                                                                    |
| ------------------------------------------------- | ------------------------------------------------------------------------------ |
| api/permissive_mTLS_mode/init-consul-config/servicedefaults-permissive.yaml     | permissive mode allows HTTP and mTLS connections |
| api/permissive_mTLS_mode/api-v2-mesh-enabled.yaml     | Enable service mesh with annotation: connect-inject: true |

```
kubectl apply -f fake-service-community/api/permissive_mTLS_mode/init-consul-config
kubectl apply -f fake-service-community/api/permissive_mTLS_mode/api-v2-mesh-enabled.yaml
```
Refresh the browser a few times and watch how requests from web are balanced across both non-mesh and mesh enabled api deployments. After verifying the api mesh enabled deployment is still working for all downstreams using api.service.consul go ahead and remove api-v1.
```
kubectl -n api delete deployment api-v1
```

## Clean Up
```
# Remove fake-service
kubectl delete -f consul-apigw/
./fake-service-community/web/deploy.sh -d
./fake-service-community/api/deploy.sh -d

# Remove Consul
consul-k8s uninstall -auto-approve -wipe-data
kubectl apply -f ./logs/kube-system-coredns-configmap-orig.yaml

# Remove the AWS LB Controller
helm uninstall -n kube-system --kube-context=usw2 aws-load-balancer-controller
```

## Troubleshooting
Debug the API Gateway Config
```
kubectl debug -it -n consul $(kubectl -n consul get pods -l gateway.consul.hashicorp.com/name=api-gateway --output jsonpath='{.items[0].metadata.name}') --target api-gateway --image nicolaka/netshoot -- curl localhost:19000/config_dump\?include_eds | code -
```
