# Migrating from Community Consul to ENT Consul Namespaces and Partitions
These are Notes only.  The steps have been tested but not with this repo.

## Install Consul Enterprise
Obtain a license and place it into ./files.
```
secret=$(cat ./files/license.hclic)
kubectl create secret generic consul-ent-license --from-literal="key=${secret}"
```

Upgrade the community edition to enterprise.  
```
consul-k8s upgrade ./quickstart/infrastructure/consul_helm_values/yaml/enterprise-values.yaml
```

## Migrate services to a new Partition/Namespace
If migrating from OSS, services may not be using namespaces or partitions.  If supporting a multi-tenant environment there may be requirements for services or organizations to eventually have their own namespace or partition.  This requires a service to be moved to the new location (peer/partition/namespace).  To do this without impacting existing downstream services a **Service Resolver** can be used to redirect requests from the old location to a new. The example below shows how to migrate a service from the default namespace to a new ENT namespace.

### Enable a new Partition on a new K8s cluster
To incrementally migrate applications to ENT partitions/namespaces without impacting downstreams bootstrap a 2nd K8s cluster to Consul (operating as a dataplane only) that supports Partitions and Namespaces.  
* Uncomment the new EKS cluster in `./quickstart/infrastructure/dc-usw2.tf`.
* Rerun Terraform to provision the new EKS cluster
* Edit `./quickstart/infrastructure/consul_helm_values/auto-presto-mig-new-usw2.tf`
Here are commands to pull the required information above for bootstrapping this new EKS cluster into Consul.
```
# Update `hcp_consul_ca_file` in ./quickstart/2vpc-2eks-multiregion/consul_helm_values/${cluster}.tf 
# use base64 data
kubectl -n consul get secret consul-ca-cert --context usw2 -o json | jq -r '.data."tls.crt"'

# Update `hcp_consul_root_token_secret_id` in ./quickstart/2vpc-2eks-multiregion/consul_helm_values/${cluster}.tf 
kubectl -n consul get secret consul-bootstrap-acl-token --context usw2 --template "{{.data.token | base64decode}}"

# Update `consul_external_servers` in ./quickstart/2vpc-2eks-multiregion/consul_helm_values/${cluster}.tf 
kubectl -n consul get svc consul-expose-servers --context usw2 -o json | jq -r '.status.loadBalancer.ingress[].hostname'
```

Bootstrap the second K8s cluster to a new Consul partition by running TF.
```
cd ./quickstart/infrastructure/consul_helm_values/
terraform apply -auto-approve -target module.consul_presto-mig-shared-usw2new
```

### Deploy `api` to the new K8s cluster
This will deploy the same services to the new cluster with additional intentions.  
```
usw2new #alias to new K8s context
./Community_migration_to_namespaces/shared/api/deploy.sh
./Community_migration_to_namespaces/shared/web/deploy.sh
```
Sameness groups are designed to work in this failover use case.  They need further investigation...  Until then, we are manually defining a resolver.

### Create a service-resolver in default/default to route traffic to shared/api
The `api` service was just deployed to shared/api.  Now traffic from all downstreams that are unaware of this change needs to be redirected to it. build a service resolver failover target in the default partition and namespace. 
```
usw2
kubectl apply -f ./Community_migration_to_namespaces/default/api_serviceResolver_failover.yaml
```

Now all downstream requests to the default namespace for `api` (**api.virtual.consul**) can failover to **api.virtual.shared.ap.api.ns.consul** requiring no downstream changes.  Test this by undeploying the `api` svc in default/default to use the new one deployed in shared/api.
```
kubectl delete -f ./fake-service-OSS/api/permissive_mTLS_mode/api-v1-connect-inject.yaml
```
web should now automatically be routed to shared/api.


**Note**: In Consul 1.17.1 redirects don't appear to be supported across partitions: `./Community_migration_to_namespaces/default/api_serviceResolver_redirect.yaml`
```
Unexpected response code: 500 (peer exported service "default/default/api" contains cross-partition resolver redirect
```

### Migrate a service with API Gateway routes to a new partition/namespace

...

## Clean up
```
usw2
kubectl delete -f ./Community_migration_to_namespaces/default/api_serviceResolver_failover.yaml
kubectl delete -f ./fake-service-OSS/api/permissive_mTLS_mode/web-virtualaddress.yaml.enable
kubectl delete -f ./fake-service-OSS/api/permissive_mTLS_mode/api-v1-connect-inject.yaml
kubectl delete -f ./fake-service-OSS/api/permissive_mTLS_mode/servicedefaults-strict-dialDirect.yaml.enable
kubectl delete -f ./fake-service-OSS/api/permissive_mTLS_mode
kubectl delete -f ./fake-service-OSS/api/
kubectl delete -f ./fake-service-OSS/api/init-consul-config/
kubectl delete -f ./fake-service-OSS/web/
kubectl delete -f ./fake-service-OSS/web/init-consul-config/
kubectl delete -f ./fake-service-OSS/web/init-consul-config/mesh.yaml.disable

usw2new
kubectl delete -f ./Community_migration_to_namespaces/shared/api/
kubectl delete -f ./Community_migration_to_namespaces/shared/api/init-consul-config/
kubectl delete -f ./Community_migration_to_namespaces/shared/web/
kubectl delete -f ./Community_migration_to_namespaces/shared/web/init-consul-config/
usw2
```